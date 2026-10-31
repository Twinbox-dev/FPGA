`timescale 1ns/1ps
module tb_direct_video_region_mux;
    reg clk=0,rst=1,video_mode=1,de=0,vs=1;
    reg [23:0] video_rgb=24'h123456,still_rgb=24'habcdef;
    wire [23:0] rgb_out;
    integer x,y;
    always #5 clk=~clk;

    direct_video_region_mux #(.H_ACTIVE(8),.V_ACTIVE(4),.VIDEO_WIDTH(4),.VIDEO_HEIGHT(2)) dut(
        .clk(clk),.rst(rst),.video_mode(video_mode),.de(de),.vs(vs),
        .video_rgb(video_rgb),.still_rgb(still_rgb),.rgb_out(rgb_out)
    );

    initial begin
        repeat(3) @(negedge clk); rst=0;
        @(negedge clk); vs=0;
        repeat(2) @(negedge clk); vs=1;
        for (y=0;y<4;y=y+1) begin
            @(negedge clk); de=1;
            for (x=0;x<8;x=x+1) begin
                #1;
                if (rgb_out !== ((x<4)&&(y<2)?24'h123456:24'd0))
                    $fatal(1,"crop mismatch x=%0d y=%0d rgb=%06x",x,y,rgb_out);
                @(negedge clk);
            end
            de=0; @(negedge clk);
        end
        video_mode=0;
        #1;
        if (rgb_out!==still_rgb) $fatal(1,"still image path was not selected");
        $display("PASS direct-video region mux: top-left crop, black margins, static-path fallback");
        $finish;
    end
endmodule
