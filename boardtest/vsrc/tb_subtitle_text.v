`timescale 1ns/1ps
module tb_subtitle_text;
    reg clk = 1'b0;
    always #6.667 clk = ~clk;
    reg rst = 1'b1, de = 1'b0, vs = 1'b0;
    wire [7:0] char_index;
    reg [7:0] char_data;
    wire text_on, in_band;
    integer lit = 0;
    subtitle_text_renderer #(
        .FONT_FILE("../board_display/user_source/hdl_source/SD/font.mem")
    ) dut (
        .video_clk(clk), .rst(rst), .de(de), .vs(vs),
        .ox(12'sd8), .oy(10'd0), .text_len(8'd1),
        .char_index(char_index), .char_data(char_data),
        .text_on(text_on), .in_band(in_band)
    );
    always @(posedge clk)
        char_data <= (char_index == 8'd0) ? "A" : " ";

    task automatic scan_line(input integer check_row);
        integer x;
        begin
            @(negedge clk); de = 1'b1;
            for (x = 0; x < 32; x = x + 1) begin
                @(negedge clk);
                if (check_row && text_on) begin
                    if (x != 11 && x != 12)
                        $fatal(1, "glyph A row 1 shifted to x=%0d", x);
                    lit = lit + 1;
                end
            end
            de = 1'b0;
            repeat (5) @(negedge clk);
        end
    endtask
    initial begin
        repeat (4) @(negedge clk); rst = 1'b0;
        vs = 1'b1;
        @(negedge clk); vs = 1'b0;
        scan_line(0); // glyph row 0 is blank
        scan_line(1); // glyph row 1: 0x18, two middle pixels
        if (lit != 2) $fatal(1, "glyph A row 1 had %0d pixels", lit);
        $display("PASS subtitle text: synchronous character and font ROM alignment");
        $finish;
    end
endmodule
