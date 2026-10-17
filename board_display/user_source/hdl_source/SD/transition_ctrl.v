// Video-clock transition scheduler. The target row is requested one display
// row ahead; the returned row number is checked before any mixed pixel is used.
module transition_ctrl #(
    parameter [20:0] BUF0_ADDR = 21'd0,
    parameter [20:0] BUF1_ADDR = 21'd460800
)(
    input  wire        video_clk,
    input  wire        rst,
    input  wire        start_toggle_raw,
    input  wire        target_buf_raw,
    input  wire [1:0]  mode_raw,
    input  wire        direction_prev_raw,
    output reg         done_toggle,
    input  wire        de_word,
    input  wire        vs_word,
    output reg         line_req_toggle,
    output reg  [9:0]  line_num,
    output reg  [20:0] line_base,
    input  wire        line_ready_toggle_raw,
    output wire        line_rd_bank,
    output wire [9:0]  line_rd_addr,
    output reg         row_ready,
    output reg         effect_active,
    output reg  [1:0]  active_mode,
    output reg         direction_prev,
    output reg  [8:0]  fade_alpha,
    output reg  [10:0] wipe_progress
);
    localparam [1:0] S_IDLE = 2'd0, S_ARM = 2'd1, S_RUN = 2'd2;
    reg [1:0] state;
    reg start_s1, start_s2, start_s3;
    reg target_s1, target_s2;
    reg [1:0] mode_s1, mode_s2;
    reg dir_s1, dir_s2;
    reg ready_s1, ready_s2, ready_s3;
    wire start_pulse = start_s2 ^ start_s3;
    wire ready_pulse = ready_s2 ^ ready_s3;

    reg de_d, vs_d;
    wire de_rise = de_word && !de_d;
    wire de_fall = !de_word && de_d;
    wire vs_rise = vs_word && !vs_d;
    reg [9:0]  y_cnt;
    reg [10:0] x_cnt;
    assign line_rd_bank = y_cnt[0];
    assign line_rd_addr = x_cnt[10:1];

    reg [6:0] frame_step;
    reg       req_inflight;
    reg [9:0] req_line;
    reg       even_valid, odd_valid;
    reg [9:0] even_row, odd_row;
    wire ready_this_row = ready_pulse && req_inflight && (req_line == y_cnt);
    wire row_tag_matches = y_cnt[0] ? (odd_valid && odd_row == y_cnt) :
                                         (even_valid && even_row == y_cnt);

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            start_s1 <= 1'b0; start_s2 <= 1'b0; start_s3 <= 1'b0;
            target_s1 <= 1'b0; target_s2 <= 1'b0;
            mode_s1 <= 2'd0; mode_s2 <= 2'd0;
            dir_s1 <= 1'b0; dir_s2 <= 1'b0;
            ready_s1 <= 1'b0; ready_s2 <= 1'b0; ready_s3 <= 1'b0;
            de_d <= 1'b0; vs_d <= 1'b0;
            y_cnt <= 10'd0; x_cnt <= 11'd0;
        end else begin
            start_s1 <= start_toggle_raw;
            start_s2 <= start_s1;
            start_s3 <= start_s2;
            target_s1 <= target_buf_raw;
            target_s2 <= target_s1;
            mode_s1 <= mode_raw;
            mode_s2 <= mode_s1;
            dir_s1 <= direction_prev_raw;
            dir_s2 <= dir_s1;
            ready_s1 <= line_ready_toggle_raw;
            ready_s2 <= ready_s1;
            ready_s3 <= ready_s2;
            de_d <= de_word;
            vs_d <= vs_word;
            if (vs_rise) y_cnt <= 10'd0;
            else if (de_fall) y_cnt <= y_cnt + 10'd1;
            if (de_word) x_cnt <= x_cnt + 11'd1;
            else x_cnt <= 11'd0;
        end
    end

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            state <= S_IDLE;
            done_toggle <= 1'b0;
            line_req_toggle <= 1'b0;
            line_num <= 10'd0;
            line_base <= BUF0_ADDR;
            row_ready <= 1'b0;
            effect_active <= 1'b0;
            active_mode <= 2'd0;
            direction_prev <= 1'b0;
            fade_alpha <= 9'd0;
            wipe_progress <= 11'd0;
            frame_step <= 7'd0;
            req_inflight <= 1'b0;
            req_line <= 10'd0;
            even_valid <= 1'b0; odd_valid <= 1'b0;
            even_row <= 10'd0; odd_row <= 10'd0;
        end else begin
            if (vs_rise) begin
                even_valid <= 1'b0;
                odd_valid <= 1'b0;
            end
            if (ready_pulse && req_inflight) begin
                req_inflight <= 1'b0;
                if (req_line[0]) begin
                    odd_valid <= 1'b1;
                    odd_row <= req_line;
                end else begin
                    even_valid <= 1'b1;
                    even_row <= req_line;
                end
            end
            if (de_rise)
                row_ready <= (state == S_RUN) &&
                             (row_tag_matches || ready_this_row);

            case (state)
                S_IDLE: begin
                    effect_active <= 1'b0;
                    if (start_pulse && mode_s2 != 2'd0) begin
                        active_mode <= mode_s2;
                        direction_prev <= dir_s2;
                        line_base <= target_s2 ? BUF1_ADDR : BUF0_ADDR;
                        state <= S_ARM;
                    end
                end
                S_ARM: if (vs_rise) begin
                    frame_step <= 7'd0;
                    fade_alpha <= 9'd0;
                    wipe_progress <= 11'd0;
                    effect_active <= 1'b1;
                    line_num <= 10'd0;
                    req_line <= 10'd0;
                    req_inflight <= 1'b1;
                    line_req_toggle <= ~line_req_toggle;
                    state <= S_RUN;
                end
                S_RUN: begin
                    if (vs_rise) begin
                        if (frame_step == 7'd64) begin
                            effect_active <= 1'b0;
                            row_ready <= 1'b0;
                            done_toggle <= ~done_toggle;
                            state <= S_IDLE;
                        end else begin
                            frame_step <= frame_step + 7'd1;
                            fade_alpha <= fade_alpha + 9'd4;
                            wipe_progress <= wipe_progress + 11'd20;
                            if (!req_inflight || ready_pulse) begin
                                line_num <= 10'd0;
                                req_line <= 10'd0;
                                req_inflight <= 1'b1;
                                line_req_toggle <= ~line_req_toggle;
                            end
                        end
                    end else if (de_rise && y_cnt < 10'd719 &&
                                 (!req_inflight || ready_pulse)) begin
                        line_num <= y_cnt + 10'd1;
                        req_line <= y_cnt + 10'd1;
                        req_inflight <= 1'b1;
                        line_req_toggle <= ~line_req_toggle;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
