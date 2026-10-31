// 转15路频谱数据模块
`timescale 1ns/1ps

module audio_to_15ch (
    input  wire         clk,
    input  wire         rst,
    input  wire [127:0] levels,      // DFT输出的16路高度，每路8位
    input  wire         done_toggle, // 每完成一组 DFT 数据就翻转一次
    input  wire [3:0]   vol_gain,    // 音量档位，用于判断是否静音
    output reg  [149:0] ch_bus,      // 输出 15 路数据，每路10位，高三位有效
    output reg          ch_valid     // 通知映射器：这一组数据已更新
);

    reg done_seen, was_muted;
    wire [7:0] high_a      = levels[119:112];
    wire [7:0] high_b      = levels[127:120];
    wire [7:0] merged_high = (high_a >= high_b) ? high_a : high_b;

    function [2:0] point_height;
        input [7:0] value;
        begin
            casez (value)
                8'b0000????, 8'b0001000? : point_height = 3'd0; // 0..17
                8'b0001001?, 8'b000101??, 8'b00011???, 8'b0010000?, 8'b00100010 : point_height = 3'd1; // 18..34
                8'b00100011, 8'b001001??, 8'b00101???, 8'b001100?? : point_height = 3'd2; // 35..51
                8'b001101??, 8'b00111???, 8'b010000??, 8'b0100010? : point_height = 3'd3; // 52..69
                8'b0100011?, 8'b01001???, 8'b010100??, 8'b0101010?, 8'b01010110 : point_height = 3'd4; // 70..86
                8'b01010111, 8'b01011???, 8'b01100??? : point_height = 3'd5; // 87..103
                8'b01101???, 8'b0111????, 8'b1??????? : point_height = 3'd6; // 104..255
                default: point_height = 3'd0;
            endcase
        end
    endfunction

    integer col;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            done_seen <= 1'b0;
            was_muted <= 1'b1;
            ch_bus    <= 150'd0;
            ch_valid  <= 1'b0;
        end else begin
            done_seen <= done_toggle;
            was_muted <= (vol_gain == 4'd0);
            ch_valid  <= 1'b0;
            if ((done_toggle != done_seen) || ((vol_gain == 4'd0) && !was_muted)) begin
                ch_valid <= 1'b1;
                if (vol_gain == 4'd0) begin
                    ch_bus <= 150'd0;
                end else begin
                    for (col = 0; col < 14; col = col + 1)
                        ch_bus[col*10 +: 10] <= {point_height(levels[col*8 +: 8]), 7'b0};
                    ch_bus[149:140] <= {point_height(merged_high), 7'b0};
                end
            end
        end
    end
endmodule
