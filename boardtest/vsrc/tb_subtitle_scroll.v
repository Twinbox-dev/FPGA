`timescale 1ns/1ps
module tb_subtitle_scroll;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1, vs=0, changed=0;
    reg [7:0] len=0;
    wire signed [12:0] ox;
    wire [9:0] oy;
    subtitle_scroll dut (
        .video_clk(clk), .rst(rst), .vs(vs),
        .text_changed_pulse(changed), .text_len(len), .ox(ox), .oy(oy)
    );
    task frame;
        begin
            @(negedge clk); vs=1;
            @(negedge clk); vs=0;
            @(negedge clk);
        end
    endtask
    integer k;
    initial begin
        repeat (3) @(negedge clk); rst=0; len=160;
        changed=1; @(negedge clk); changed=0;
        if (ox !== 1280 || oy !== 480) $fatal(1,"scroll start/y wrong");
        for (k=1; k<=1920; k=k+1) begin
            frame();
            if (ox !== 1280-2*k)
                $fatal(1,"frame %0d x=%0d",k,ox);
        end
        frame();
        if (ox !== 1280) $fatal(1,"160-char loop did not restart");
        len=0; frame();
        if (ox !== 1280) $fatal(1,"clear did not reset scroll");
        $display("PASS subtitle scroll: 2 px/frame, 2560-pixel text, y=480, restart/clear");
        $finish;
    end
endmodule
