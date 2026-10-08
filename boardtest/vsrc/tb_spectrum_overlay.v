`timescale 1ns/1ps
module tb_spectrum_overlay;
    reg clk=0;
    always #6.667 clk=~clk;
    reg rst=1, de=0, vs=0, enable=1, done_toggle=0;
    reg [127:0] levels=0;
    wire ack_toggle, shade, hit;
    wire [23:0] rgb;
    integer row, pixel;
    reg saw_bar=0, saw_empty=0, saw_caption_gap=0;
    spectrum_overlay dut (
        .video_clk(clk), .rst(rst), .de(de), .vs(vs),
        .enable_raw(enable), .levels_raw(levels),
        .done_toggle_raw(done_toggle), .ack_toggle(ack_toggle),
        .shade(shade), .bar_hit(hit), .bar_rgb(rgb)
    );
    initial begin
        levels[5*8 +: 8]=8'd80;
        repeat (4) @(negedge clk); rst=0;
        done_toggle=1;
        repeat (5) @(negedge clk);
        vs=1; @(negedge clk); vs=0;
        repeat (3) @(negedge clk);
        if (!ack_toggle || dut.levels_frame[5*8 +: 8] !== 8'd80)
            $fatal(1,"frame-atomic spectrum CDC failed");
        for (row=0; row<=650; row=row+1) begin
            @(negedge clk); de=1;
            for (pixel=0; pixel<470; pixel=pixel+1) begin
                @(negedge clk);
                if (row==504 && dut.x_cnt==11'd458 && !shade && !hit)
                    saw_caption_gap=1;
                if (row==650 && dut.x_cnt==11'd458 && shade && hit && rgb==24'h5DD5CA)
                    saw_bar=1;
                if (row==650 && dut.x_cnt==11'd400 && shade && !hit)
                    saw_empty=1;
            end
            de=0;
            repeat (3) @(negedge clk);
        end
        if (!saw_caption_gap || !saw_bar || !saw_empty)
            $fatal(1,"bottom spectrum geometry failed gap=%b bar=%b empty=%b",
                   saw_caption_gap,saw_bar,saw_empty);
        enable=0; repeat (4) @(negedge clk);
        if (shade || hit) $fatal(1,"Q off did not hide spectrum");
        $display("PASS spectrum overlay: VS mailbox, y=504 gap, band geometry, Q off");
        $finish;
    end
endmodule
