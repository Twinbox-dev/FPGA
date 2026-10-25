// Fixed five-line OSD: brightness, contrast, volume, source width and height.
// Resolution digits are decimal; one synchronous glyph ROM is shared by rows.
module osd_panel_levels #(
    parameter [10:0] X_TOP = 11'd1160,
    parameter [9:0]  Y_TOP = 10'd8
)(
    input  wire        video_clk,
    input  wire        rst,
    input  wire        de,
    input  wire        vs,
    input  wire [3:0]  brightness_level,
    input  wire [3:0]  contrast_level,
    input  wire [3:0]  volume_level,
    input  wire [11:0] image_width,
    input  wire [11:0] image_height,
    output wire [6:0]  font_ascii,
    output wire [3:0]  font_row,
    input  wire [7:0]  font_row_data,
    output reg         text_on,
    output reg [23:0]  text_rgb,
    output reg         in_band
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

    wire signed [11:0] rx = $signed({1'b0, x_cnt}) - $signed({1'b0, X_TOP});
    wire signed [10:0] ry = $signed({1'b0, y_cnt}) - $signed({1'b0, Y_TOP});
    wire in_x = rx >= 12'sd0 && rx < 12'sd112;
    wire in_y = ry >= 11'sd0 && ry < 11'sd160;
    wire [3:0] bit_x = rx[3:0];
    wire [3:0] glyph_y = ry[4:1];
    wire [2:0] panel_row = ry[7:5];
    wire [5:0] column = rx[9:4];
    reg [5:0] font_col;
    reg [7:0] row_shift;
    wire [7:0] glyph_row = font_row_data;
    function [15:0] to_bcd4;
        input [11:0] value;
        integer i;
        reg [15:0] bcd;
        begin
            bcd = 16'd0;
            for (i=11; i>=0; i=i-1) begin
                if (bcd[3:0] >= 5) bcd[3:0] = bcd[3:0] + 4'd3;
                if (bcd[7:4] >= 5) bcd[7:4] = bcd[7:4] + 4'd3;
                if (bcd[11:8] >= 5) bcd[11:8] = bcd[11:8] + 4'd3;
                if (bcd[15:12] >= 5) bcd[15:12] = bcd[15:12] + 4'd3;
                bcd = {bcd[14:0],value[i]};
            end
            to_bcd4 = bcd;
        end
    endfunction
    wire [15:0] width_bcd = to_bcd4(image_width);
    wire [15:0] height_bcd = to_bcd4(image_height);
    wire [3:0] level = (panel_row == 3'd0) ? brightness_level :
                       (panel_row == 3'd1) ? contrast_level : volume_level;
    wire [7:0] label0 = (panel_row == 3'd0) ? "B" :
                        (panel_row == 3'd1) ? "C" : "V";
    wire [7:0] label1 = (panel_row == 3'd0) ? "R" : "O";
    wire [7:0] label2 = (panel_row == 3'd0) ? "I" :
                        (panel_row == 3'd1) ? "N" : "L";
    wire [7:0] denom = (panel_row == 3'd1) ? "6" : "8";
    reg [7:0] glyph_ascii;
    always @* begin
        glyph_ascii = " ";
        if (panel_row <= 3'd2) begin
            case (font_col)
                6'd0: glyph_ascii = label0;
                6'd1: glyph_ascii = label1;
                6'd2: glyph_ascii = label2;
                6'd3: glyph_ascii = " ";
                6'd4: glyph_ascii = 8'h30 + {4'd0, level};
                6'd5: glyph_ascii = "/";
                6'd6: glyph_ascii = denom;
                default: glyph_ascii = " ";
            endcase
        end else if (panel_row == 3'd3) begin
            case (font_col)
                6'd0: glyph_ascii = "W";
                6'd1: glyph_ascii = 8'h30 + {4'd0,width_bcd[15:12]};
                6'd2: glyph_ascii = 8'h30 + {4'd0,width_bcd[11:8]};
                6'd3: glyph_ascii = 8'h30 + {4'd0,width_bcd[7:4]};
                6'd4: glyph_ascii = 8'h30 + {4'd0,width_bcd[3:0]};
                default: glyph_ascii = " ";
            endcase
        end else if (panel_row == 3'd4) begin
            case (font_col)
                6'd0: glyph_ascii = "H";
                6'd1: glyph_ascii = 8'h30 + {4'd0,height_bcd[11:8]};
                6'd2: glyph_ascii = 8'h30 + {4'd0,height_bcd[7:4]};
                6'd3: glyph_ascii = 8'h30 + {4'd0,height_bcd[3:0]};
                default: glyph_ascii = " ";
            endcase
        end
    end
    assign font_ascii = glyph_ascii[6:0];
    assign font_row = glyph_y;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            font_col <= 6'd0;
            row_shift <= 8'd0;
        end else if (!de) begin
            font_col <= column;
            row_shift <= glyph_row << bit_x[3:1];
        end else begin
            if (bit_x == 4'd10) font_col <= column + 6'd1;
            if (bit_x == 4'd15) row_shift <= glyph_row;
            else if (bit_x[0]) row_shift <= {row_shift[6:0], 1'b0};
        end
    end

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            text_on <= 1'b0;
            text_rgb <= 24'hFFC857;
            in_band <= 1'b0;
        end else begin
            text_on <= de && in_x && in_y && row_shift[7];
            case (panel_row)
                0: text_rgb <= 24'hFFC857;
                1: text_rgb <= 24'h6EE7F9;
                2: text_rgb <= 24'h64E6B5;
                default: text_rgb <= 24'hC4B5FD;
            endcase
            in_band <= de && rx >= -12'sd8 && rx < 12'sd120 &&
                       ry >= -11'sd4 && ry < 11'sd164;
        end
    end
endmodule
