`timescale 1ns/1ps
module tb_osd_panel_levels;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, de = 0, vs = 0;
    wire text_on, in_band;
    wire [23:0] text_rgb;
    wire [6:0] font_ascii;
    wire [3:0] font_row;
    wire [7:0] font_row_data;
    reg [7:0] font_mem [0:2047];
    osd_panel_levels #(
        .X_TOP(11'd8), .Y_TOP(10'd0)
    ) dut (
        .video_clk(clk), .rst(rst), .de(de), .vs(vs),
        .brightness_level(4'd5), .contrast_level(4'd3),
        .volume_level(4'd7),.image_width(12'd1280),.image_height(12'd720),
        .font_ascii(font_ascii), .font_row(font_row), .font_row_data(font_row_data),
        .text_on(text_on), .text_rgb(text_rgb), .in_band(in_band)
    );
    font_rom_2r #(
        .MEM_FILE("../board_display/user_source/hdl_source/SD/font.mem")
    ) font (
        .video_clk(clk),
        .ascii_a(7'd0), .row_a(4'd0), .row_data_a(),
        .ascii_b(font_ascii), .row_b(font_row), .row_data_b(font_row_data)
    );
    function automatic [7:0] panel_char(input integer row, input integer col);
        begin
            case (row)
                0: case (col)
                    0: panel_char="B"; 1: panel_char="R";
                    2: panel_char="I"; 3: panel_char=" ";
                    4: panel_char="5"; 5: panel_char="/";
                    6: panel_char="8"; default: panel_char=" ";
                endcase
                1: case (col)
                    0: panel_char="C"; 1: panel_char="O";
                    2: panel_char="N"; 3: panel_char=" ";
                    4: panel_char="3"; 5: panel_char="/";
                    6: panel_char="6"; default: panel_char=" ";
                endcase
                3: case (col)
                    0: panel_char="W"; 1: panel_char="1";
                    2: panel_char="2"; 3: panel_char="8";
                    4: panel_char="0"; default: panel_char=" ";
                endcase
                4: case (col)
                    0: panel_char="H"; 1: panel_char="7";
                    2: panel_char="2"; 3: panel_char="0";
                    default: panel_char=" ";
                endcase
                default: case (col)
                    0: panel_char="V"; 1: panel_char="O";
                    2: panel_char="L"; 3: panel_char=" ";
                    4: panel_char="7"; 5: panel_char="/";
                    6: panel_char="8"; default: panel_char=" ";
                endcase
            endcase
        end
    endfunction
    integer x, y, lit = 0;
    reg [7:0] glyph;
    reg expected;
    initial begin
        $readmemh("../board_display/user_source/hdl_source/SD/font.mem", font_mem);
        repeat (4) @(negedge clk); rst=0;
        vs=1; @(negedge clk); vs=0;
        for (y=0; y<162; y=y+1) begin
            de=1;
            for (x=0; x<136; x=x+1) begin
                @(negedge clk);
                expected=0;
                if (x>=8 && x<120 && y<160) begin
                    glyph=font_mem[panel_char(y/32,(x-8)/16)*16+((y%32)/2)];
                    expected=glyph[7-(((x-8)%16)/2)];
                end
                if (text_on !== expected)
                    $fatal(1,"panel pixel mismatch x=%0d y=%0d got=%b expect=%b",x,y,text_on,expected);
                if (text_on && text_rgb !== ((y<32) ? 24'hFFC857 :
                    (y<64) ? 24'h6EE7F9 : (y<96) ? 24'h64E6B5 : 24'hC4B5FD))
                    $fatal(1,"panel row color mismatch y=%0d rgb=%h",y,text_rgb);
                if (expected) lit=lit+1;
            end
            de=0;
            repeat (5) @(negedge clk);
        end
        if (lit<50) $fatal(1,"font ROM was blank");
        $display("PASS OSD panel: 2x glyph golden and colored BRI/CON/VOL/W/H (%0d lit pixels)",lit);
        $finish;
    end
endmodule
