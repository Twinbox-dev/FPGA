`timescale 1ns/1ps
// Two MF168 range links -> media board gestures.
//
// Presence and swipe follow laser_gesture_handoff_20261026 (laser_presence.v
// + laser_swipe.v):
//   presence : 2 of the last 3 usable measurements are inside the window.
//              A narrow window (ENTER) to arm, a wider one (EXIT) to stay
//              armed, so a hand hovering at the edge does not chatter.
//   swipe    : the left beam arming first and the right beam then rising is
//              a left->right swipe; mirror for the other way. The first side
//              is allowed to drop out (or to have been already present) in
//              between -- the trigger is the SECOND side's rising edge, so the
//              hand does not have to finish the motion or leave the beam.
//              Two sides rising closer than MIN_SEPARATION_MS is not a sweep
//              (that is an approach) and parks in AMBIGUOUS instead of
//              guessing a direction.
//
// Brightness is unchanged from the build that already works on hardware:
// both beams in range, both ranges moving the same way relative to one
// shared baseline -> 0x5D / 0x5B.
module gesture_cmd_gen #(
    parameter CLK_FREQ_HZ   = 125000000,
    // ---- presence (laser_presence.v) ----
    parameter [15:0]  ENTER_MIN_MM      = 16'd200,
    parameter [15:0]  ENTER_MAX_MM      = 16'd400,
    parameter [15:0]  EXIT_MIN_MM       = 16'd150,
    parameter [15:0]  EXIT_MAX_MM       = 16'd450,
    parameter integer SAMPLE_TIMEOUT_MS = 200,
    parameter integer HISTORY_SPAN_MS   = 80,
    // ---- swipe (laser_swipe.v) ----
    parameter integer PAIR_TIMEOUT_MS   = 800,
    // The reference default is 20 ms, but its own docs report ~32 Hz frames
    // (~31 ms apart). Two beams arming inside one frame interval is one
    // approach sampled at slightly different times, so the gate has to be
    // above that or approaches turn into image swaps. 60 ms = ~2 frames.
    parameter integer MIN_SEPARATION_MS = 60,
    // ---- brightness (unchanged, proven on hardware) ----
    parameter [15:0] STEP_MM       = 16'd50,
    parameter integer BOTH_DWELL_MS = 100,
    parameter integer COOLDOWN_MS   = 250,
    parameter integer LED_HOLD_MS   = 500,
    parameter [7:0] CMD_NEAR = 8'h5D,
    parameter [7:0] CMD_FAR  = 8'h5B
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] left_mm,  input wire left_val,  input wire left_tgt,
    input  wire [15:0] right_mm, input wire right_val, input wire right_tgt,
    input  wire        control_idle,
    output reg         next_pulse,
    output reg         prev_pulse,
    output reg  [7:0]  cmd,
    output reg         cmd_valid,
    output reg         led_next,   // LED1: left -> right swipe
    output reg         led_prev,   // LED2: right -> left swipe
    output reg         led_level   // LED3: brightness step issued
);
    localparam integer TICKS_PER_MS = CLK_FREQ_HZ/1000;
    localparam [31:0] TIMEOUT_TICKS    = SAMPLE_TIMEOUT_MS  *TICKS_PER_MS;
    localparam [31:0] SPAN_TICKS       = HISTORY_SPAN_MS    *TICKS_PER_MS;
    localparam [31:0] PAIR_TICKS       = PAIR_TIMEOUT_MS    *TICKS_PER_MS;
    localparam [31:0] MINSEP_TICKS     = MIN_SEPARATION_MS  *TICKS_PER_MS;
    localparam [31:0] BOTH_DWELL_TICKS = BOTH_DWELL_MS      *TICKS_PER_MS;
    localparam [31:0] COOLDOWN_TICKS   = COOLDOWN_MS        *TICKS_PER_MS;
    localparam [31:0] LED_TICKS        = LED_HOLD_MS        *TICKS_PER_MS;

    // =====================================================================
    // presence, one per beam: 2-of-3 measurements, enter/exit hysteresis,
    // and a sample timeout that marks the link unusable without pretending
    // the hand left (presence is held, exactly as the reference does).
    // =====================================================================
    reg  [31:0] l_age,r_age;
    reg  [2:0]  l_hist,r_hist;
    reg  [1:0]  l_hcnt,r_hcnt;
    reg         l_pres,r_pres,l_ok,r_ok;

    wire l_keep=l_ok && l_pres;
    wire r_keep=r_ok && r_pres;
    wire [15:0] l_lo=l_keep?EXIT_MIN_MM:ENTER_MIN_MM;
    wire [15:0] l_hi=l_keep?EXIT_MAX_MM:ENTER_MAX_MM;
    wire [15:0] r_lo=r_keep?EXIT_MIN_MM:ENTER_MIN_MM;
    wire [15:0] r_hi=r_keep?EXIT_MAX_MM:ENTER_MAX_MM;
    wire l_hit=left_tgt  && left_mm >=l_lo && left_mm <=l_hi;
    wire r_hit=right_tgt && right_mm>=r_lo && right_mm<=r_hi;
    wire [1:0] l_hit_count={1'b0,l_hist[0]}+{1'b0,l_hist[1]}+{1'b0,l_hist[2]};
    wire [1:0] r_hit_count={1'b0,r_hist[0]}+{1'b0,r_hist[1]}+{1'b0,r_hist[2]};

    always @(posedge clk) begin
        if(!rst_n) begin
            l_age<=0;l_hist<=0;l_hcnt<=0;l_pres<=0;l_ok<=0;
            r_age<=0;r_hist<=0;r_hcnt<=0;r_pres<=0;r_ok<=0;
        end else begin
            if(left_val)  l_age<=0;
            else if(l_age<TIMEOUT_TICKS) l_age<=l_age+1'b1;
            if(right_val) r_age<=0;
            else if(r_age<TIMEOUT_TICKS) r_age<=r_age+1'b1;

            if(left_val) begin
                // A gap longer than the history span means the older samples
                // are stale: restart the vote window from this measurement.
                if(l_age>SPAN_TICKS) l_hcnt<=2'd1;
                else if(l_hcnt<2'd3) l_hcnt<=l_hcnt+1'b1;
                l_hist<={l_hist[1:0],l_hit};
            end
            if(right_val) begin
                if(r_age>SPAN_TICKS) r_hcnt<=2'd1;
                else if(r_hcnt<2'd3) r_hcnt<=r_hcnt+1'b1;
                r_hist<={r_hist[1:0],r_hit};
            end

            if(l_age>=TIMEOUT_TICKS) begin
                l_ok<=0;l_hcnt<=0;              // presence is deliberately held
            end else if(l_hcnt>=2'd3) begin
                l_ok<=1;l_pres<=(l_hit_count>=2'd2);
            end else l_ok<=0;

            if(r_age>=TIMEOUT_TICKS) begin
                r_ok<=0;r_hcnt<=0;
            end else if(r_hcnt>=2'd3) begin
                r_ok<=1;r_pres<=(r_hit_count>=2'd2);
            end else r_ok<=0;
        end
    end

    reg l_pres_d,r_pres_d;
    always @(posedge clk) begin
        if(!rst_n) begin l_pres_d<=0;r_pres_d<=0;end
        else begin l_pres_d<=l_pres;r_pres_d<=r_pres;end
    end
    wire l_rise=l_pres && !l_pres_d;
    wire r_rise=r_pres && !r_pres_d;

    // =====================================================================
    // brightness: both beams in range, both ranges moving the same way
    // =====================================================================
    reg [15:0] base_l,base_r;
    wire [16:0] lmm={1'b0,left_mm}, rmm={1'b0,right_mm};
    wire [16:0] lba={1'b0,base_l},  rba={1'b0,base_r};
    wire [16:0] step_ext={1'b0,STEP_MM};
    wire near_both=(lmm+step_ext<lba)&&(rmm+step_ext<rba);
    wire far_both =(lmm>lba+step_ext)&&(rmm>rba+step_ext);

    // =====================================================================
    // swipe FSM (laser_swipe.v order, without the player handshake -- the
    // request is held at the top level until the scheduler actually starts)
    // =====================================================================
    localparam [2:0] S_BASELINE=3'd0,S_IDLE=3'd1,S_FROM_LEFT=3'd2,
                     S_FROM_RIGHT=3'd3,S_AMBIGUOUS=3'd4;
    localparam       B_IDLE=1'b0,B_BOTH=1'b1;

    reg [2:0]  s_state;
    reg        b_state;
    reg [31:0] pair_cnt,both_tmr,cool_tmr,led_tmr;

    wire both_ok=l_ok && r_ok;
    wire enough_sep=(MINSEP_TICKS==0)||(pair_cnt>=MINSEP_TICKS);

    always @(posedge clk) begin
        next_pulse<=0;prev_pulse<=0;cmd_valid<=0;
        if(!rst_n) begin
            s_state<=S_BASELINE;b_state<=B_IDLE;
            pair_cnt<=0;both_tmr<=0;cool_tmr<=0;led_tmr<=0;
            base_l<=0;base_r<=0;cmd<=0;
            led_next<=0;led_prev<=0;led_level<=0;
        end else begin
            if(cool_tmr!=0) cool_tmr<=cool_tmr-1'b1;
            if(led_tmr!=0) begin
                led_tmr<=led_tmr-1'b1;
                if(led_tmr==32'd1) begin led_next<=0;led_prev<=0;led_level<=0;end
            end

            // ---------- swipe ----------
            if(!both_ok) begin
                s_state<=S_BASELINE;
                pair_cnt<=0;
            end else case(s_state)
                S_BASELINE: begin               // take the current levels as the new start
                    pair_cnt<=0;
                    case({l_pres,r_pres})
                        2'b00: s_state<=S_IDLE;
                        2'b10: s_state<=S_FROM_LEFT;
                        2'b01: s_state<=S_FROM_RIGHT;
                        2'b11: s_state<=S_AMBIGUOUS;
                    endcase
                end
                S_IDLE: begin
                    pair_cnt<=0;
                    if(l_pres&&r_pres)          s_state<=S_AMBIGUOUS;
                    else if(l_rise&&!r_pres)    s_state<=S_FROM_LEFT;
                    else if(r_rise&&!l_pres)    s_state<=S_FROM_RIGHT;
                end
                S_FROM_LEFT: begin              // left seen first; wait for the right
                    if(r_rise) begin
                        if(enough_sep) begin
                            next_pulse<=1;led_next<=1;led_tmr<=LED_TICKS;
                        end
                        pair_cnt<=0;
                        s_state<=S_BASELINE;    // re-baseline from the levels as they are now
                    end else if(pair_cnt>=PAIR_TICKS) begin
                        pair_cnt<=0;
                        s_state<=S_IDLE;        // do not reuse a side that just stayed high
                    end else pair_cnt<=pair_cnt+1'b1;
                end
                S_FROM_RIGHT: begin
                    if(l_rise) begin
                        if(enough_sep) begin
                            prev_pulse<=1;led_prev<=1;led_tmr<=LED_TICKS;
                        end
                        pair_cnt<=0;
                        s_state<=S_BASELINE;
                    end else if(pair_cnt>=PAIR_TICKS) begin
                        pair_cnt<=0;
                        s_state<=S_IDLE;
                    end else pair_cnt<=pair_cnt+1'b1;
                end
                S_AMBIGUOUS: begin              // never guess a direction from both-at-once
                    pair_cnt<=0;
                    case({l_pres,r_pres})
                        2'b00: s_state<=S_IDLE;
                        2'b10: s_state<=S_FROM_LEFT;
                        2'b01: s_state<=S_FROM_RIGHT;
                        2'b11: s_state<=S_AMBIGUOUS;
                    endcase
                end
                default: begin
                    s_state<=S_BASELINE;pair_cnt<=0;
                end
            endcase

            // ---------- brightness ----------
            case(b_state)
                B_IDLE:
                    if(l_pres&&r_pres) begin
                        b_state<=B_BOTH;both_tmr<=0;
                        base_l<=left_mm;base_r<=right_mm;
                    end
                B_BOTH: begin
                    if(!l_pres||!r_pres) b_state<=B_IDLE;
                    else if(both_tmr<BOTH_DWELL_TICKS) both_tmr<=both_tmr+1'b1;
                    else if(cool_tmr==0 && control_idle) begin
                        if(near_both) begin
                            cmd<=CMD_NEAR;cmd_valid<=1;led_level<=1;led_tmr<=LED_TICKS;
                            base_l<=left_mm;base_r<=right_mm;cool_tmr<=COOLDOWN_TICKS;
                        end else if(far_both) begin
                            cmd<=CMD_FAR;cmd_valid<=1;led_level<=1;led_tmr<=LED_TICKS;
                            base_l<=left_mm;base_r<=right_mm;cool_tmr<=COOLDOWN_TICKS;
                        end
                    end
                end
            endcase
        end
    end
endmodule
