// One 8x16 glyph row at a time. Text RAM and font ROM are both synchronous:
// request next character at pixel 4, fetch its glyph at pixel 6, then load
// the shift register at pixel 7 for the next cell.
module subtitle_text_renderer(
    input  wire               video_clk,
    input  wire               rst,
    input  wire               de,
    input  wire               vs,
    input  wire signed [11:0] ox,
    input  wire [9:0]         oy,
    input  wire [7:0]         text_len,
    output reg  [7:0]         char_index,
    input  wire [7:0]         char_data,
    output wire [6:0]         font_ascii,
    output wire [3:0]         font_row,
    input  wire [7:0]         font_row_data,
    output reg                text_on,
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

    // x can be 1279 while ox reaches -1280; keep the full 0..2559 range.
    wire signed [12:0] rx = $signed({2'b00, x_cnt}) - $signed({ox[11], ox});
    wire signed [10:0] ry = $signed({1'b0, y_cnt}) - $signed({1'b0, oy});
    wire [10:0] text_width = {text_len, 3'b000};
    wire in_x = (rx >= 13'sd0) &&
                (rx < $signed({2'b00, text_width}));
    wire in_y = (ry >= 11'sd0) && (ry < 11'sd16);
    wire [2:0] bit_x = rx[2:0];
    wire [3:0] glyph_y = ry[3:0];
    wire signed [12:0] column = rx >>> 3;

    reg [7:0] row_shift;
    wire [7:0] glyph_row = font_row_data;
    assign font_ascii = char_data[6:0];
    assign font_row = glyph_y;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            char_index <= 8'd0;
            row_shift <= 8'd0;
        end else if (!de) begin
            row_shift <= 8'd0;
        end else begin
            if (bit_x == 3'd4)
                char_index <= column[7:0] + 8'd1;
            if (bit_x == 3'd7)
                row_shift <= glyph_row;
            else
                row_shift <= {row_shift[6:0], 1'b0};
        end
    end

    // Register the mask from pre-edge coordinates so it lines up with the
    // video_delay pixel registered on the same video clock edge.
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            text_on <= 1'b0;
            in_band <= 1'b0;
        end else begin
            text_on <= de && in_x && in_y && row_shift[7];
            in_band <= de && text_len != 8'd0 &&
                       rx >= -13'sd8 &&
                       rx < $signed({2'b00, text_width}) + 13'sd8 &&
                       ry >= -11'sd4 && ry < 11'sd20;
        end
    end
endmodule
