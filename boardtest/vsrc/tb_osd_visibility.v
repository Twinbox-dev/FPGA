`timescale 1ns/1ps
module tb_osd_visibility;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1, vs = 1'b0;
    reg [1:0] mode = 2'd1;
    reg [3:0] bri = 4'd6, ct = 4'd3, vol = 4'd12;
    reg [11:0] image_width_raw=12'd1280,image_height_raw=12'd720;
    wire show;
    wire [3:0] bri_level, ct_level, vol_level;
    wire [11:0] image_width,image_height;
    osd_visibility dut (
        .video_clk(clk), .rst(rst), .vs(vs), .mode_raw(mode),
        .bri_gray_raw(bri), .ct_gray_raw(ct), .vol_gray_raw(vol),
        .image_width_raw(image_width_raw),.image_height_raw(image_height_raw),
        .show_panel(show), .brightness_level(bri_level),
        .contrast_level(ct_level), .volume_level(vol_level),
        .image_width(image_width),.image_height(image_height)
    );
    task automatic frame;
        begin
            repeat (5) @(negedge clk);
            vs = 1'b1;
            @(negedge clk); vs = 1'b0;
        end
    endtask
    integer i;
    initial begin
        repeat (3) @(negedge clk); rst = 1'b0;
        frame();
        if (show || bri_level != 4 || ct_level != 2 || vol_level != 8 ||
            image_width != 1280 || image_height != 720)
            $fatal(1, "boot levels or initial visibility wrong");
        vol = 4'd4; // Gray(7)
        frame();
        if (!show || vol_level != 7) $fatal(1, "changed volume not shown");
        for (i = 0; i < 180; i = i + 1) frame();
        if (show) $fatal(1, "temporary OSD did not expire");
        mode = 2'd2; frame();
        if (!show) $fatal(1, "always-on mode failed");
        mode = 2'd0; frame();
        if (show) $fatal(1, "off mode failed");
        $display("PASS OSD visibility: actual levels, transient, always, off");
        $finish;
    end
endmodule
