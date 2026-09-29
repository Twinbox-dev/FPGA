// =============================================================================
// 测试桩 sd_card_top — 板上 SD SPI 层的行为等价替身
// -----------------------------------------------------------------------------
// 板上 sd_card_top 由厂商 SPI 模块实现（CPOL=1/CPHA=1，真卡已验证）。
// 测试桩改用仿真侧已验证的 sd_spi（模式0） + 引脚级卡模型，把
// sd_card_top 的「sd_sec_read 电平请求 → 数据流 → end 一拍」协议
// 翻译成 sd_spi 的「i_lba/i_req/o_ready/o_dval/o_done」协议。
// 只测协议适配，不测 SPI 物理层（那是板上已验证的部分）。
//
// 触发：sd_sec_read 上升沿（一次请求做一扇区；做完后等请求线落下再收下一个）
// =============================================================================
module sd_card_top #(
    parameter SPI_LOW_SPEED_DIV  = 248,
    parameter SPI_HIGH_SPEED_DIV = 0
)(
    input            clk,
    input            rst,
    output           SD_nCS,
    output           SD_DCLK,
    output           SD_MOSI,
    input            SD_MISO,
    output           sd_init_done,
    input            sd_sec_read,
    input  [31:0]    sd_sec_read_addr,
    output reg [7:0] sd_sec_read_data,
    output reg       sd_sec_read_data_valid,
    output reg       sd_sec_read_end,
    input            sd_sec_write,
    input  [31:0]    sd_sec_write_addr,
    input  [7:0]     sd_sec_write_data,
    output           sd_sec_write_data_req,
    output           sd_sec_write_end
);

    wire [31:0] sp_lba;
    wire        sp_req, sp_ready, sp_dval, sp_done, sp_err;
    wire [7:0]  sp_data;

    sd_spi u_sd_spi (
        .clk        (clk),
        .rst_n      (~rst),
        .i_lba      (sp_lba),
        .i_req      (sp_req),
        .o_ready    (sp_ready),
        .o_data     (sp_data),
        .o_dval     (sp_dval),
        .o_done     (sp_done),
        .o_err      (sp_err),
        .spi_cs_n   (SD_nCS),
        .spi_sclk   (SD_DCLK),
        .spi_mosi   (SD_MOSI),
        .spi_miso   (SD_MISO),
        .o_dbg_state()
    );

    // ---- sd_sec_read 上升沿 → 单扇区请求 ----
    reg        busy;
    reg        issued;
    reg        init_latched;
    reg        req_prev;
    reg [31:0] lba_l;
    reg [7:0]  data_r;

    assign sp_lba = lba_l;
    assign sp_req = busy && !issued && sp_ready;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy        <= 1'b0;
            issued      <= 1'b0;
            init_latched<= 1'b0;
            req_prev    <= 1'b0;
            lba_l       <= 32'd0;
            data_r      <= 8'd0;
            sd_sec_read_data_valid <= 1'b0;
            sd_sec_read_end <= 1'b0;
        end
        else begin
            sd_sec_read_data_valid <= 1'b0;
            sd_sec_read_end        <= 1'b0;
            req_prev <= sd_sec_read;

            if (sp_ready) init_latched <= 1'b1;   // sd_spi 就绪 = 卡初始化完成

            if (!busy && init_latched && sd_sec_read && !req_prev) begin
                busy   <= 1'b1;
                issued <= 1'b0;
                lba_l  <= sd_sec_read_addr;
            end
            else if (busy) begin
                if (sp_req) issued <= 1'b1;
                if (issued) begin
                    data_r <= sp_data;
                    sd_sec_read_data_valid <= sp_dval;
                    if (sp_done) begin
                        sd_sec_read_end <= 1'b1;
                        busy <= 1'b0;
                    end
                end
            end
        end
    end

    assign sd_init_done = init_latched;
    assign sd_sec_read_data = data_r;
    assign sd_sec_write_data_req = 1'b0;
    assign sd_sec_write_end = 1'b0;
endmodule

// =============================================================================
// fast_sd_stub — SIM_FAST 直连扇区服务器（fast_en=1 时选中）
// -----------------------------------------------------------------------------
// 把「sd_sec_read 电平请求 → 512 字节数据流 → end 一拍」的从机协议直接实现，
// 字节由 C++ 从卡镜像按 fast_lba/fast_idx 投喂（1 字节/拍，经 SdCardModel::
// sector_bytes 的同一套寻址语义）。绕开 sd_spi 翻译 + 引脚级卡模型，
// 装载类周期大幅下降。SPI 协议栈（含 HCS 协商、CRC、重试）由此退出仿真
// 覆盖——板上已验证；默认回归仍走引脚级，只有 SIM_FAST=1 迭代档才启用。
module fast_sd_stub #(
    // 字节节拍：每 PACE_DIV 拍出一个字节。SPI 档约 32 拍/字节，这里取 4~8
    // 既保 4~8× 提速，又给下游（音频打包器按 ack 节奏取字节等）留节拍余量——
    // 1 拍/字节会超出消费方的节拍假设导致丢字节（扫描项永不关闭）。
    parameter PACE_DIV = 4
)(
    input  wire        clk,
    input  wire        rst,
    output wire        sd_init_done,
    // C++ 投喂口
    input  wire [7:0]  fast_byte,
    input  wire        fast_val,
    output wire [31:0] fast_lba,      // 当前服务的扇区号（C++ 索引用）
    output wire [9:0]  fast_idx,      // 扇区内字节偏移 0..511
    output wire        fast_serving,  // 正在出数
    // 从机侧（协议同 sd_card_top）
    input  wire        sd_sec_read,
    input  wire [31:0] sd_sec_read_addr,
    output reg  [7:0]  sd_sec_read_data,
    output reg         sd_sec_read_data_valid,
    output reg         sd_sec_read_end
);
    reg [1:0]  init_cnt;
    reg        serving;
    reg [31:0] lba;
    reg [9:0]  idx;
    reg [3:0]  pace;                  // 字节节拍计数
    reg        sec_d;                 // 请求线打拍：边沿触发（与 stub_sd_card_top
                                     // 同规则——end 后请求线要一拍才落下，
                                     // 电平触发会把同一请求立刻重锁存重出数）

    assign sd_init_done = (init_cnt == 2'd3);
    assign fast_lba     = lba;
    assign fast_idx     = idx;
    assign fast_serving = serving;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            init_cnt <= 2'd0; serving <= 1'b0; lba <= 32'd0; idx <= 10'd0;
            sd_sec_read_data <= 8'd0; sd_sec_read_data_valid <= 1'b0;
            sd_sec_read_end  <= 1'b0; sec_d <= 1'b1; pace <= 4'd0;
        end else begin
            sd_sec_read_data_valid <= 1'b0;
            sd_sec_read_end        <= 1'b0;
            if (init_cnt != 2'd3)
                init_cnt <= init_cnt + 1'b1;

            if (!serving) begin
                pace <= 4'd0;
                if (!sec_d && sd_sec_read && sd_init_done) begin
                    serving <= 1'b1;
                    lba     <= sd_sec_read_addr;
                    idx     <= 10'd0;
                end
            end else if (pace != 4'd0) begin
                pace <= pace - 1'b1;
            end else if (fast_val) begin
                sd_sec_read_data       <= fast_byte;
                sd_sec_read_data_valid <= 1'b1;
                idx <= idx + 1'b1;
                pace <= PACE_DIV[3:0] - 1'b1;
                if (idx == 10'd511) begin
                    serving         <= 1'b0;
                    sd_sec_read_end <= 1'b1;
                end
            end
            sec_d <= sd_sec_read;
        end
    end
endmodule
