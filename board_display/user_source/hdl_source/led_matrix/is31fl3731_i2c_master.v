// is31fl3731_i2c_master（单地址 + 按需坐标求值与共享分频无损优化版）
// Description: IS31FL3731 50kHz I2C 音频位图与转场动画驱动
//              1. 共享 20us/1ms 级联分频链，消除多个 19~25 bit 独立大计数器；
//              2. 上电安全等待 100ms (避开芯片内部 POR 上电复位死区)；
//              3. 固定从机地址 0x74 (AD 接地)，不再做 0x74/0x77 双地址轮询；
//              4. 按需对当前发送通道的 (col, row) 实时求值，消除 105-bit 位图锁存器与 105:1 MUX。

`timescale 1ns / 1ps

module is31fl3731_i2c_master #(
    parameter integer PWM_STEP_CYCLES = 500_000 // 5ms @ 100MHz，每次改变一级 PWM
) (
    input  wire         clk,             // 100MHz 主时钟 (sd_card_clk)
    input  wire         rst,             // 高有效复位 (rst_all)
    input  wire         visualizer_en,   // 上位机使能
    input  wire [3:0]   vol_gain,        // 音量档位
    input  wire [104:0] matrix_bitmap,   // 紧缩状态总线：{8'd0, anim_mode[1:0], anim_frame[4:0], top_row[44:0], body_h[44:0]}
    input  wire         frame_ready,     // 显存就绪

    output reg          i2c_scl,         // I2C SCL 时钟线 (50kHz)
    inout  wire         i2c_sda          // I2C SDA 开漏双向数据线
);

    // -------------------------------------------------------------------------
    // 1. SDA 开漏缓冲（单地址模式下不再回读 ACK，仅做输出）
    // -------------------------------------------------------------------------
    reg sda_out_reg;
    assign i2c_sda = sda_out_reg ? 1'bz : 1'b0;

    // -------------------------------------------------------------------------
    // 2. 共享 I2C 50kHz (20us) 与 1ms 级联分频基准
    // -------------------------------------------------------------------------
    reg [11:0] i2c_div;
    wire tick_ph0  = (i2c_div == 12'd0);    // SCL 低，驱动数据变化
    wire tick_ph1  = (i2c_div == 12'd500);  // SCL 拉高
    wire tick_ph2  = (i2c_div == 12'd1000); // SCL 高电平正中，安全采样 ACK
    wire tick_ph3  = (i2c_div == 12'd1500); // SCL 拉低
    wire tick_20us = (i2c_div == 12'd1999); // 20us 周期结束

    reg [5:0] ms_sub_cnt;
    wire tick_1ms = tick_20us && (ms_sub_cnt == 6'd49); // 50 × 20us = 1ms

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            i2c_div    <= 12'd0;
            ms_sub_cnt <= 6'd0;
        end else if (tick_20us) begin
            i2c_div    <= 12'd0;
            ms_sub_cnt <= (ms_sub_cnt == 6'd49) ? 6'd0 : (ms_sub_cnt + 6'd1);
        end else begin
            i2c_div <= i2c_div + 12'd1;
        end
    end

    // -------------------------------------------------------------------------
    // 3. 上电 100ms 延迟保护 & 250ms 周期重初始化（复用 tick_1ms，仅需 7/8-bit）
    // -------------------------------------------------------------------------
    reg [6:0] por_cnt;
    reg       por_done;
    reg [7:0] refresh_cnt;
    wire      refresh_trigger = por_done && tick_1ms && (refresh_cnt == 8'd249);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            por_cnt     <= 7'd0;
            por_done    <= 1'b0;
            refresh_cnt <= 8'd0;
        end else if (tick_1ms) begin
            if (!por_done) begin
                if (por_cnt == 7'd99)
                    por_done <= 1'b1;
                else
                    por_cnt <= por_cnt + 7'd1;
            end else begin
                if (refresh_cnt == 8'd249)
                    refresh_cnt <= 8'd0;
                else
                    refresh_cnt <= refresh_cnt + 8'd1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 4. 单地址控制与按需单像素求值
    // -------------------------------------------------------------------------
    // 7-bit 从机地址 0x74 (AD 接地) 左移一位拼上写位
    localparam [7:0] SLAVE_ADDR = 8'hE8;

    reg [4:0] cmd_idx;
    reg [7:0] sub_step;
    reg [1:0] anim_mode_latched;
    reg [4:0] anim_frame_latched;
    reg [7:0] active_pwm;
    reg       frame_pending, reinit_pending;
    reg       init_done;             // 0 = 正在下发初始化命令，1 = 进入正常刷帧

    // 100% 逐位等价的转场动画单像素求值函数
    function eval_anim_pixel;
        input [1:0] mode; // 1=fade, 2=left, 3=right
        input [4:0] f;
        input [3:0] col;
        input [2:0] row;
        reg [2:0] r;
        reg [3:0] dx;
        reg [2:0] dy;
        reg [3:0] dist_m;
        reg       same_parity;
        reg [3:0] radius;
        begin
            r           = 3'd6 - row;
            dx          = (col >= 4'd7) ? (col - 4'd7) : (4'd7 - col);
            dy          = (row >= 3'd3) ? (row - 3'd3) : (3'd3 - row);
            dist_m      = dx + {1'b0, dy};
            same_parity = (row[0] == col[0]);

            if (mode == 2'd1) begin
                case (f[3:0])
                    4'd0: radius = 4'd10;
                    4'd1: radius = 4'd6;
                    4'd2: radius = 4'd4;
                    4'd3: radius = 4'd2;
                    4'd4: radius = 4'd0;
                    4'd5: radius = 4'd1;
                    4'd6: radius = 4'd3;
                    4'd7: radius = 4'd5;
                    4'd8: radius = 4'd7;
                    default: radius = 4'd10;
                endcase
                if (f[3:0] <= 4'd4)
                    eval_anim_pixel = same_parity && (dist_m <= radius);
                else if (f[3:0] <= 4'd9)
                    eval_anim_pixel = (!same_parity) && (dist_m <= radius);
                else if (f[3:0] <= 4'd14)
                    eval_anim_pixel = (!same_parity) && ({1'b0, r} >= (f[3:0] - 4'd9));
                else
                    eval_anim_pixel = (row == 3'd0);
            end else begin
                if (f <= 5'd14) begin
                    if (!row[0])
                        eval_anim_pixel = ~col[0];
                    else if (mode == 2'd2)
                        eval_anim_pixel = (({1'b0, col} + f) < 5'd15) && (col[0] ^ f[0]);
                    else
                        eval_anim_pixel = ({1'b0, col} >= f) && (col[0] ^ f[0]);
                end else if (f <= 5'd19) begin
                    if ({2'b00, r} < (f - 5'd14))
                        eval_anim_pixel = 1'b0;
                    else if ({2'b00, r} == (f - 5'd14))
                        eval_anim_pixel = col[0];
                    else if (row == 3'd0)
                        eval_anim_pixel = ~col[0] && !((mode == 2'd2) && (f == 5'd16) && (col == 4'd12));
                    else
                        eval_anim_pixel = ~col[0] && (row[0] != f[0]);
                end else begin
                    eval_anim_pixel = (row == 3'd0);
                end
            end
        end
    endfunction

    // 按当前物理通道实时求取 PWM（无需 105-bit 锁存与 105:1 MUX）
    function [7:0] get_led_pwm;
        input [7:0]   channel;
        input [89:0]  audio_state; // {top_row_flat[44:0], body_h_flat[44:0]}
        input [1:0]   anim_mode;
        input [4:0]   anim_frame;
        input [7:0]   pwm;
        reg [3:0] logical_col;
        reg [2:0] logical_row;
        reg       mapped;
        reg [2:0] col_body;
        reg [2:0] col_top;
        reg       audio_on;
        reg       anim_on;
        reg       pixel_on;
        begin
            logical_col = 4'd0;
            logical_row = 3'd0;
            mapped      = 1'b0;
            if (channel[7:4] < 4'd8) begin
                if (channel[3:0] >= 4'd1 && channel[3:0] <= 4'd7) begin
                    logical_col = channel[7:4];
                    logical_row = channel[2:0] - 3'd1;
                    mapped      = 1'b1;
                end else if (channel[7:4] >= 4'd1 &&
                             channel[3:0] >= 4'd8 && channel[3:0] <= 4'd14) begin
                    logical_col = 4'd15 - channel[7:4];
                    logical_row = 4'd14 - channel[3:0];
                    mapped      = 1'b1;
                end
            end
            col_body = audio_state[logical_col*3 +: 3];
            col_top  = audio_state[45 + logical_col*3 +: 3];
            audio_on = (logical_row == 3'd0) || (col_body >= logical_row) || (col_top == logical_row);
            anim_on  = eval_anim_pixel(anim_mode, anim_frame, logical_col, logical_row);
            pixel_on = (anim_mode != 2'd0) ? anim_on : audio_on;
            get_led_pwm = (mapped && pixel_on) ? pwm : 8'h00;
        end
    endfunction

    wire [7:0] next_sub_step = sub_step + 8'd1;
    reg  [7:0] next_target_byte;
    reg        is_last_byte_in_trans;

    always @(*) begin
        next_target_byte      = 8'h00;
        is_last_byte_in_trans = 1'b0;

        if (!init_done) begin
            is_last_byte_in_trans = (sub_step == 8'd2);

            case (cmd_idx)
                5'd0: begin
                    if (next_sub_step == 8'd1) next_target_byte = 8'hFD;
                    else                       next_target_byte = 8'h0B;
                end
                5'd1: begin
                    if (next_sub_step == 8'd1) next_target_byte = 8'h0A;
                    else                       next_target_byte = 8'h01;
                end
                5'd2: begin
                    if (next_sub_step == 8'd1) next_target_byte = 8'h01;
                    else                       next_target_byte = 8'h00;
                end
                5'd3: begin
                    if (next_sub_step == 8'd1) next_target_byte = 8'hFD;
                    else                       next_target_byte = 8'h00;
                end
                default: begin
                    if (next_sub_step == 8'd1) next_target_byte = cmd_idx - 5'd4;
                    else                       next_target_byte = 8'hFF;
                end
            endcase
        end else begin
            if (next_sub_step == 8'd1) begin
                next_target_byte      = 8'h24;
                is_last_byte_in_trans = 1'b0;
            end else begin
                next_target_byte      = get_led_pwm(next_sub_step - 8'd2,
                                                    matrix_bitmap[89:0],
                                                    anim_mode_latched,
                                                    anim_frame_latched,
                                                    active_pwm);
                is_last_byte_in_trans = (sub_step == 8'd145);
            end
        end
    end

    // -------------------------------------------------------------------------
    // 5. 核心状态机与 PWM 渐变（复用 tick_1ms，仅需 3-bit 计数器）
    // -------------------------------------------------------------------------
    localparam S_IDLE      = 3'd0;
    localparam S_START     = 3'd1;
    localparam S_SEND_BYTE = 3'd2;
    localparam S_ACK       = 3'd3;
    localparam S_STOP      = 3'd4;
    localparam S_GAP       = 3'd5;

    reg [2:0] state;
    reg [7:0] shift_reg;
    reg [3:0] bit_idx;

    wire [7:0] target_pwm = !visualizer_en ? 8'd0 :
                            (vol_gain >= 4'd8) ? 8'd255 : {vol_gain[2:0], 5'b0};
    reg [2:0] pwm_ms_cnt;
    reg [7:0] current_pwm;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pwm_ms_cnt  <= 3'd0;
            current_pwm <= 8'd0;
        end else if (!visualizer_en) begin
            pwm_ms_cnt  <= 3'd0;
            current_pwm <= 8'd0;
        end else if (tick_1ms) begin
            if (pwm_ms_cnt == 3'd4) begin // 5ms 步进一级 PWM
                pwm_ms_cnt <= 3'd0;
                if (current_pwm < target_pwm)
                    current_pwm <= current_pwm + 8'd1;
                else if (current_pwm > target_pwm)
                    current_pwm <= current_pwm - 8'd1;
            end else begin
                pwm_ms_cnt <= pwm_ms_cnt + 3'd1;
            end
        end
    end

    wire [7:0] requested_pwm    = visualizer_en ? current_pwm : 8'd0;
    wire       reinit_requested = reinit_pending | refresh_trigger;
    wire       blank_requested  = (requested_pwm == 8'd0) && (active_pwm != 8'd0);
    wire       frame_requested  = frame_pending | frame_ready | (requested_pwm != active_pwm);
    wire       start_pwm        = por_done && (state == S_IDLE) &&
                                  (!init_done ||
                                   ((!reinit_requested || blank_requested) && frame_requested));

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            anim_mode_latched  <= 2'd0;
            anim_frame_latched <= 5'd0;
            active_pwm         <= 8'd0;
            frame_pending      <= 1'b0;
            reinit_pending     <= 1'b0;
        end else begin
            if (frame_ready)
                frame_pending <= 1'b1;
            if (refresh_trigger)
                reinit_pending <= 1'b1;
            if (start_pwm) begin
                anim_mode_latched  <= matrix_bitmap[96:95];
                anim_frame_latched <= matrix_bitmap[94:90];
                active_pwm         <= requested_pwm;
                frame_pending      <= 1'b0;
            end
            if (por_done && state == S_IDLE && init_done && reinit_requested && !blank_requested)
                reinit_pending <= 1'b0;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state           <= S_IDLE;
            init_done       <= 1'b0;
            cmd_idx         <= 5'd0;
            sub_step        <= 8'd0;
            shift_reg       <= 8'h00;
            bit_idx         <= 4'd0;
            i2c_scl         <= 1'b1;
            sda_out_reg     <= 1'b1;
        end else if (por_done) begin
            case (state)
                S_IDLE: begin
                    i2c_scl     <= 1'b1;
                    sda_out_reg <= 1'b1;
                    if (!init_done) begin
                        state    <= S_START;
                        sub_step <= 8'd0;
                    end else if (reinit_requested && !blank_requested) begin
                        init_done <= 1'b0;
                        cmd_idx   <= 5'd0;
                        state     <= S_START;
                        sub_step  <= 8'd0;
                    end else if (frame_requested) begin
                        state    <= S_START;
                        sub_step <= 8'd0;
                    end
                end

                S_START: begin
                    if (tick_ph1) begin
                        sda_out_reg <= 1'b1;
                        i2c_scl     <= 1'b1;
                    end else if (tick_ph2) begin
                        sda_out_reg <= 1'b0;
                        i2c_scl     <= 1'b1;
                    end else if (tick_ph3) begin
                        i2c_scl   <= 1'b0;
                        shift_reg <= SLAVE_ADDR;
                        bit_idx   <= 4'd7;
                        state     <= S_SEND_BYTE;
                    end
                end

                S_SEND_BYTE: begin
                    if (tick_ph0) begin
                        sda_out_reg <= shift_reg[bit_idx];
                        i2c_scl     <= 1'b0;
                    end else if (tick_ph1) begin
                        i2c_scl     <= 1'b1;
                    end else if (tick_ph3) begin
                        i2c_scl <= 1'b0;
                        if (bit_idx == 4'd0)
                            state <= S_ACK;
                        else
                            bit_idx <= bit_idx - 4'd1;
                    end
                end

                // 单地址固定 0x74，ACK 位不再采样（写不存在的器件只会 NACK，无副作用）
                S_ACK: begin
                    if (tick_ph0) begin
                        sda_out_reg <= 1'b1;
                        i2c_scl     <= 1'b0;
                    end else if (tick_ph1) begin
                        i2c_scl     <= 1'b1;
                    end else if (tick_ph3) begin
                        i2c_scl <= 1'b0;
                        if (is_last_byte_in_trans) begin
                            state <= S_STOP;
                        end else begin
                            shift_reg <= next_target_byte;
                            bit_idx   <= 4'd7;
                            sub_step  <= next_sub_step;
                            state     <= S_SEND_BYTE;
                        end
                    end
                end

                S_STOP: begin
                    if (tick_ph0) begin
                        sda_out_reg <= 1'b0;
                        i2c_scl     <= 1'b0;
                    end else if (tick_ph1) begin
                        i2c_scl     <= 1'b1;
                    end else if (tick_ph2) begin
                        sda_out_reg <= 1'b1;
                    end else if (tick_ph3) begin
                        state <= S_GAP;
                    end
                end

                S_GAP: begin
                    // 复用 tick_ph3 等待整 1 个 I2C 周期 (20us)，省去 12-bit gap_timer
                    i2c_scl     <= 1'b1;
                    sda_out_reg <= 1'b1;
                    if (tick_ph3) begin
                        if (!init_done) begin
                            if (cmd_idx == 5'd21) begin
                                cmd_idx   <= 5'd0;
                                init_done <= 1'b1;
                            end else begin
                                cmd_idx <= cmd_idx + 5'd1;
                            end
                        end
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
