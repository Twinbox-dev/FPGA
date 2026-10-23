// Shared 8x16 glyphs rendered as 16x32 cells without enlarging the font ROM.
// Fetch the next character during the current cell, load at pixel 15, and
// shift only after each repeated pair of horizontal pixels.
module subtitle_text_renderer(
    input  wire               video_clk,
    input  wire               rst,
    input  wire               de,
    input  wire               vs,
    input  wire signed [12:0] ox,
    input  wire [9:0]         oy,
    input  wire [7:0]         text_len,
    output reg  [7:0]         char_index,
    input  wire [7:0]         char_data,
    output wire [6:0]         font_ascii,
    output wire [3:0]         font_row,
    input  wire [7:0]         font_row_data,
    output reg                text_on,
    output reg  [23:0]         text_rgb,
    output reg                in_band
);
    reg de_d, vs_d;
    reg [10:0] x_cnt;
    reg [9:0] y_cnt;
    wire de_fall = !de && de_d;
    wire vs_rise = vs && !vs_d;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            de_d <= 1'b0; vs_d <= 1'b0;
            x_cnt <= 11'd0; y_cnt <= 10'd0;
        end else begin
            de_d <= de; vs_d <= vs;
            if (vs_rise) y_cnt <= 10'd0;
            else if (de_fall) y_cnt <= y_cnt + 10'd1;
            if (de) x_cnt <= x_cnt + 11'd1;
            else x_cnt <= 11'd0;
        end
    end

    // x can be 1279 while ox reaches -2560; retain signed arithmetic.
    wire signed [13:0] rx = $signed({3'b000, x_cnt}) - $signed({ox[12], ox});
    wire signed [10:0] ry = $signed({1'b0, y_cnt}) - $signed({1'b0, oy});
    wire [11:0] text_width = {text_len, 4'b0000};
    wire in_x = (rx >= 14'sd0) &&
                (rx < $signed({2'b00, text_width}));
    wire in_y = (ry >= 11'sd0) && (ry < 11'sd32);
    wire [3:0] bit_x = rx[3:0];
    wire [3:0] glyph_y = ry[4:1];
    wire signed [13:0] column = rx >>> 4;

    function [23:0] caption_color(input [1:0] cell_index);
        case (cell_index)
            0: caption_color = 24'h6EE7F9;
            1: caption_color = 24'hC4B5FD;
            2: caption_color = 24'hFFADD2;
            default: caption_color = 24'hA7F3D0;
        endcase
    endfunction

    reg [7:0] row_shift;
    wire [7:0] glyph_row = font_row_data;
    assign font_ascii = char_data[6:0];
    assign font_row = glyph_y;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            char_index <= 8'd0;
            row_shift <= 8'd0;
        end else if (!de) begin
            // Preload the first visible (possibly clipped) character during
            // blanking, not just after a complete on-screen cell boundary.
            char_index <= column[7:0];
            row_shift <= glyph_row << bit_x[3:1];
        end else begin
            if (bit_x == 4'd8)
                char_index <= column[7:0] + 8'd1;
            if (bit_x == 4'd15)
                row_shift <= glyph_row;
            else if (bit_x[0])
                row_shift <= {row_shift[6:0], 1'b0};
        end
    end

    // Register the mask from pre-edge coordinates so it lines up with the
    // video_delay pixel registered on the same video clock edge.
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            text_on <= 1'b0;
            text_rgb <= 24'h6EE7F9;
            in_band <= 1'b0;
        end else begin
            text_on <= de && in_x && in_y && row_shift[7];
            text_rgb <= caption_color(column[1:0]);
            in_band <= de && text_len != 8'd0 &&
                       rx >= -14'sd8 &&
                       rx < $signed({2'b00, text_width}) + 14'sd8 &&
                       ry >= -11'sd4 && ry < 11'sd36;
        end
    end
endmodule
