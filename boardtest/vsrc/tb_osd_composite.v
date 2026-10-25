`timescale 1ns/1ps
module tb_osd_composite;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1, de = 1'b0, vs = 1'b0;
    reg panel_show = 1'b0, panel_text = 1'b0, panel_band = 1'b0;
    reg subtitle_text = 1'b0, subtitle_band = 1'b0;
    reg [23:0] video = 24'hfe8002;
    wire [23:0] out;
    wire de_out, vs_out;
    osd_composite dut (
        .video_clk(clk), .rst(rst), .video_in(video),
        .de_in(de), .vs_in(vs),
        .panel_show(panel_show), .panel_text_on(panel_text),
        .panel_text_rgb(24'hFFC857), .subtitle_text_rgb(24'h6EE7F9),
        .panel_band(panel_band), .subtitle_text_on(subtitle_text),
        .subtitle_band(subtitle_band), .video_out(out),
        .de_out(de_out), .vs_out(vs_out)
    );
    initial begin
        repeat (3) @(negedge clk); rst = 1'b0;
        de = 1'b1; vs = 1'b1; panel_band = 1'b1;
        @(negedge clk); // video/timing first enter the alignment register
        @(negedge clk);
        if (out !== video || !de_out || !vs_out)
            $fatal(1, "hidden panel changed the video or timing");
        panel_show = 1'b1;
        @(negedge clk);
        if (out !== video) $fatal(1, "panel background must stay transparent %h", out);
        subtitle_band = 1'b1;
        @(negedge clk);
        if (out !== video) $fatal(1, "subtitle background must stay transparent %h", out);
        subtitle_text = 1'b1;
        @(negedge clk);
        if (out !== 24'h6EE7F9) $fatal(1, "subtitle text color failed");
        panel_text = 1'b1;
        @(negedge clk);
        if (out !== 24'h6EE7F9) $fatal(1, "subtitle must retain priority over OSD");
        subtitle_text = 1'b0; panel_text = 1'b1;
        @(negedge clk);
        if (out !== 24'hFFC857) $fatal(1, "panel text color failed");
        de = 1'b0; vs = 1'b0;
        @(negedge clk);
        @(negedge clk);
        if (de_out || vs_out) $fatal(1, "sync signals not pipelined with RGB");
        $display("PASS OSD composite: transparent bands, colored glyph priority and RGB sync");
        $finish;
    end
endmodule
