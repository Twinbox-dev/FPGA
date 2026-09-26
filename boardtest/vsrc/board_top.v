// 测试顶层：例化板级 sd_card_bmp（新 FAT32 版），暴露写口/按键/状态供 C++ 驱动
module board_top (
    input  wire        clk,
    input  wire        rst,
    input  wire        key_next,
    input  wire        key_auto,
    input  wire        write_req_ack,
    input  wire        write_finish_toggle,
    output wire        write_req,
    output wire        write_en,
    output wire [31:0] write_data,
    output wire        display_valid,
    output wire [1:0]  disp_buf_idx,
    output wire [1:0]  write_buf_idx,
    output wire [3:0]  state_code,
    output wire        SD_nCS,
    output wire        SD_DCLK,
    output wire        SD_MOSI,
    input  wire        SD_MISO
);
    sd_card_bmp u_sd_card_bmp_m0 (
        .clk                 (clk),
        .rst                 (rst),
        .key_next            (key_next),
        .key_auto            (key_auto),
        .bmp_width           (16'd640),
        .bmp_height          (16'd480),
        .display_valid       (display_valid),
        .state_code          (state_code),
        .write_finish_toggle (write_finish_toggle),
        .write_buf_idx       (write_buf_idx),
        .disp_buf_idx        (disp_buf_idx),
        .write_req           (write_req),
        .write_req_ack       (write_req_ack),
        .write_en            (write_en),
        .write_data          (write_data),
        .SD_nCS              (SD_nCS),
        .SD_DCLK             (SD_DCLK),
        .SD_MOSI             (SD_MOSI),
        .SD_MISO             (SD_MISO)
    );
endmodule
