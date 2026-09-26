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
