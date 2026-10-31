// LED音频映射模块（双环形移位寄存器 + 零MUX时分复用优化版）
`timescale 1ns / 1ps

module matrix_core_mapper #(
    parameter integer CLK_FREQ_HZ = 100_000_000
) (
    input  wire         clk,             // 100MHz 主时钟 (sd_card_clk)
    input  wire         rst,             // 高有效复位 (rst_all)
    input  wire [149:0] ch_bus,          // 15 通道能量总线 (15 × 10-bit)
    input  wire         ch_valid,        // 15 通道更新使能脉冲
    input  wire [9:0]   peak_hold_time,  // 外部可调顶灯延时毫秒值 (默认 250ms)

    output wire [104:0] matrix_bitmap,   // 紧缩状态总线：{15'd0, top_row_sr[44:0], body_h_flat[44:0]}
    output reg          frame_ready      // 显存一帧就绪指示脉冲
);

    // -------------------------------------------------------------------------
    // 1. 直接提取 15 路 3-bit 柱高（复用 audio_to_15ch 寄存器，零触发器开销）
    // -------------------------------------------------------------------------
    wire [44:0] body_h_flat;
    genvar gi;
    generate
        for (gi = 0; gi < 15; gi = gi + 1) begin : gen_unpack
            assign body_h_flat[gi*3 +: 3] = ch_bus[gi*10 + 7 +: 3];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // 2. 1ms 与 10ms 全局时间基准发生器
    // -------------------------------------------------------------------------
    localparam integer MS_CYCLES = (CLK_FREQ_HZ >= 1000) ? CLK_FREQ_HZ / 1000 : 1;
    localparam integer MS_BITS   = (MS_CYCLES > 1) ? $clog2(MS_CYCLES) : 1;
    reg [MS_BITS-1:0] ms_div;
    wire tick_1ms = (ms_div == MS_CYCLES - 1);

    reg [3:0] ten_ms_cnt;
    wire tick_10ms = tick_1ms && (ten_ms_cnt == 4'd9);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ms_div     <= 0;
            ten_ms_cnt <= 4'd0;
        end else if (tick_1ms) begin
            ms_div     <= 0;
            ten_ms_cnt <= (ten_ms_cnt == 4'd9) ? 4'd0 : (ten_ms_cnt + 4'd1);
        end else begin
            ms_div <= ms_div + 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // 3. 15 列全环形移位顶灯状态机（top_row 与 delay_sr 同步旋转 15 拍，彻底消除读写 MUX）
    // -------------------------------------------------------------------------
    reg [44:0] top_row_sr;   // 15 列 × 3-bit 顶灯高度环形移位寄存器
    reg [74:0] delay_sr;     // 15 列 × 5-bit 10ms 倒计时环形移位寄存器
    reg        upd_busy;
    reg        upd_decay;
    reg        pending_ch;
    reg        pending_decay;
    reg [3:0]  upd_idx;

    wire [2:0] cur_body_raw = body_h_flat[upd_idx*3 +: 3];
    wire [2:0] cur_body     = (cur_body_raw > 3'd6) ? 3'd6 : cur_body_raw;
    wire [2:0] cur_top      = top_row_sr[2:0];
    wire [4:0] cur_cnt      = delay_sr[4:0];

    wire [4:0] hold_ticks = (peak_hold_time == 10'd250) ? 5'd25 :
                            (peak_hold_time[9:4] + peak_hold_time[9:5]);

    reg [2:0] next_top;
    reg [4:0] next_cnt;
    always @(*) begin
        if (cur_body >= cur_top) begin
            next_top = cur_body;
            next_cnt = hold_ticks;
        end else if (upd_decay) begin
            if (cur_cnt > 5'd1) begin
                next_top = cur_top;
                next_cnt = cur_cnt - 5'd1;
            end else begin
                next_top = cur_top - 3'd1;
                next_cnt = 5'd5;
            end
        end else begin
            next_top = cur_top;
            next_cnt = cur_cnt;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            top_row_sr    <= 45'd0;
            delay_sr      <= 75'd0;
            upd_busy      <= 1'b0;
            upd_decay     <= 1'b0;
            pending_ch    <= 1'b0;
            pending_decay <= 1'b0;
            upd_idx       <= 4'd0;
            frame_ready   <= 1'b0;
        end else begin
            frame_ready <= 1'b0;

            if (upd_busy) begin
                if (ch_valid)
                    pending_ch <= 1'b1;
                if (tick_10ms)
                    pending_decay <= 1'b1;

                top_row_sr <= {next_top, top_row_sr[44:3]};
                delay_sr   <= {next_cnt, delay_sr[74:5]};

                if (upd_idx == 4'd14) begin
                    upd_busy    <= 1'b0;
                    upd_idx     <= 4'd0;
                    frame_ready <= 1'b1;
                end else begin
                    upd_idx <= upd_idx + 4'd1;
                end
            end else if (ch_valid || pending_ch || tick_10ms || pending_decay) begin
                upd_busy      <= 1'b1;
                upd_decay     <= tick_10ms | pending_decay;
                pending_ch    <= 1'b0;
                pending_decay <= 1'b0;
                upd_idx       <= 4'd0;
            end else if (tick_1ms) begin
                frame_ready <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 4. 紧缩状态总线打包
    // -------------------------------------------------------------------------
    assign matrix_bitmap = {15'd0, top_row_sr, body_h_flat};

endmodule
