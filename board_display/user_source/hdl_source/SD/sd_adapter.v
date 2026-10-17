// =============================================================================
// sd_adapter — fat32_ro 扇区读协议 ↔ sd_card_top sd_sec_read 协议
// -----------------------------------------------------------------------------
// fat32_ro 侧（主机）：o_req+o_lba 一拍、i_ready 采样、i_data/i_dval 数据流、
//                     i_done 一拍（或 i_err）。
// sd_card_top 侧（从机）：sd_sec_read 电平请求 + sd_sec_read_addr 锁存、
//                     sd_sec_read_data_valid 数据流、sd_sec_read_end 一拍。
// -----------------------------------------------------------------------------
// 时序：
//   i_ready = sd_init_done && !busy。fat32_ro 看到 i_ready 后发出 o_req 一拍；
//   本模块锁存 o_lba → 拉高 sd_sec_read（电平）→ sd_card_top 做完一个扇区 →
//   sd_sec_read_end 一拍 → 转发为 i_done 一拍，busy 清零，可接下一个请求。
//   数据字节 sd_sec_read_data_valid 直接转发为 i_dval（注册一拍，序不变）。
// =============================================================================
module sd_adapter (
    input  wire       clk,
    input  wire       rst,             // 高有效
    input  wire       sd_init_done,

    // 主机侧（接 fat32_ro）
    input  wire [31:0] o_lba,
    input  wire        o_req,
    output             i_ready,          // 连续赋值驱动，声明为 net
    output reg  [7:0]  i_data,
    output reg         i_dval,
    output reg         i_done,
    output reg         i_err,

    // 从机侧（接 sd_card_top）
    output reg         sd_sec_read,
    output reg  [31:0] sd_sec_read_addr,
    input  wire [7:0]  sd_sec_read_data,
    input  wire        sd_sec_read_data_valid,
    input  wire        sd_sec_read_end
);

    reg        busy;
    reg [31:0] lba_latch;

    assign i_ready = sd_init_done && !busy;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy              <= 1'b0;
            lba_latch         <= 32'd0;
            sd_sec_read       <= 1'b0;
            sd_sec_read_addr  <= 32'd0;
            i_data            <= 8'd0;
            i_dval            <= 1'b0;
            i_done            <= 1'b0;
            i_err             <= 1'b0;
        end
        else begin
            i_dval <= 1'b0;
            i_done <= 1'b0;
            i_err  <= 1'b0;

            // 锁存请求：o_req 一拍，地址必须在同一拍稳定
            if (o_req && !busy && sd_init_done) begin
                busy             <= 1'b1;
                lba_latch        <= o_lba;
                sd_sec_read_addr <= o_lba;
                sd_sec_read      <= 1'b1;
            end
            else if (sd_sec_read_end) begin
                busy        <= 1'b0;
                sd_sec_read <= 1'b0;
            end

            // 数据直通（注册一拍）
            if (busy) begin
                i_data <= sd_sec_read_data;
                i_dval <= sd_sec_read_data_valid;
            end

            // 扇区完成
            if (sd_sec_read_end)
                i_done <= 1'b1;
        end
    end

endmodule
