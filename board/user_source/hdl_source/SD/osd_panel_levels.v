// Fixed three-line OSD: BRI 4/8, CON 2/6, VOL 8/8. Values are actual control
// levels, not demo counters. One synchronous glyph ROM is shared by all rows.
module osd_panel_levels #(
    parameter FONT_FILE = "../user_source/hdl_source/SD/font.mem",
    parameter [10:0] X_TOP = 11'd1216,
    parameter [9:0]  Y_TOP = 10'd8
)(
    input  wire        video_clk,
    input  wire        rst,
    input  wire        de,
    input  wire        vs,
    input  wire [3:0]  brightness_level,
    input  wire [3:0]  contrast_level,
    input  wire [3:0]  volume_level,
    output reg         text_on,
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
    wire in_x = rx >= 12'sd0 && rx < 12'sd56;
    wire in_y = ry >= 11'sd0 && ry < 11'sd48;
    wire [2:0] bit_x = rx[2:0];
    wire [3:0] glyph_y = ry[3:0];
    wire [1:0] panel_row = ry[5:4];
    wire [5:0] column = rx[8:3];
    reg [5:0] font_col;
    reg [7:0] row_shift;
    wire [7:0] glyph_row;
    wire [3:0] level = (panel_row == 2'd0) ? brightness_level :
                       (panel_row == 2'd1) ? contrast_level : volume_level;
    wire [7:0] label0 = (panel_row == 2'd0) ? "B" :
                        (panel_row == 2'd1) ? "C" : "V";
    wire [7:0] label1 = (panel_row == 2'd0) ? "R" : "O";
    wire [7:0] label2 = (panel_row == 2'd0) ? "I" :
                        (panel_row == 2'd1) ? "N" : "L";
    wire [7:0] denom = (panel_row == 2'd1) ? "6" : "8";
    reg [7:0] glyph_ascii;
    always @* begin
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
    end
    font_rom #(.MEM_FILE(FONT_FILE)) u_font (
        .video_clk(video_clk), .ascii(glyph_ascii[6:0]),
        .row(glyph_y), .row_data(glyph_row)
    );
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            font_col <= 6'd0;
            row_shift <= 8'd0;
        end else if (!de) begin
            row_shift <= 8'd0;
        end else begin
            if (bit_x == 3'd5) font_col <= column + 6'd1;
            if (bit_x == 3'd7) row_shift <= glyph_row;
            else row_shift <= {row_shift[6:0], 1'b0};
        end
    end

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            text_on <= 1'b0;
            in_band <= 1'b0;
        end else begin
            text_on <= de && in_x && in_y && row_shift[7];
            in_band <= de && rx >= -12'sd8 && rx < 12'sd64 &&
                       ry >= -11'sd4 && ry < 11'sd52;
        end
    end
endmodule
