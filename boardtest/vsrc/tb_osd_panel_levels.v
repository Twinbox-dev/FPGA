`timescale 1ns/1ps
module tb_osd_panel_levels;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, de = 0, vs = 0;
    wire text_on, in_band;
    reg [7:0] font_mem [0:2047];
    osd_panel_levels #(
        .FONT_FILE("../board/user_source/hdl_source/SD/font.mem"),
        .X_TOP(11'd8), .Y_TOP(10'd0)
    ) dut (
        .video_clk(clk), .rst(rst), .de(de), .vs(vs),
        .brightness_level(4'd5), .contrast_level(4'd3),
        .volume_level(4'd7), .text_on(text_on), .in_band(in_band)
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
        $readmemh("../board/user_source/hdl_source/SD/font.mem", font_mem);
        repeat (4) @(negedge clk); rst=0;
        vs=1; @(negedge clk); vs=0;
        for (y=0; y<48; y=y+1) begin
            de=1;
            for (x=0; x<80; x=x+1) begin
                @(negedge clk);
                expected=0;
                if (x>=8 && x<64) begin
                    glyph=font_mem[panel_char(y/16,(x-8)/8)*16+(y%16)];
                    expected=glyph[7-((x-8)%8)];
                end
                if (text_on !== expected)
                    $fatal(1,"panel pixel mismatch x=%0d y=%0d got=%b expect=%b",x,y,text_on,expected);
                if (expected) lit=lit+1;
            end
            de=0;
            repeat (5) @(negedge clk);
        end
        if (lit<50) $fatal(1,"font ROM was blank");
        $display("PASS OSD panel: real BRI/CON/VOL levels and glyph alignment (%0d lit pixels)",lit);
        $finish;
    end
endmodule
