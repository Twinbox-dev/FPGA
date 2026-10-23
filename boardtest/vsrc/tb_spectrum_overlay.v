`timescale 1ns/1ps
module tb_spectrum_overlay;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,de=0,vs=0,enable=1,done_toggle=0;
    reg [127:0] levels=0;
    wire ack_toggle,shade,hit;wire [23:0] rgb;
    integer x,y,bin,level,height;reg expected;reg [23:0] expected_rgb;
    spectrum_overlay dut(.video_clk(clk),.rst(rst),.de(de),.vs(vs),
        .enable_raw(enable),.levels_raw(levels),.done_toggle_raw(done_toggle),
        .ack_toggle(ack_toggle),.shade(shade),.bar_hit(hit),.bar_rgb(rgb));
    initial begin
        levels[0+:8]=120;levels[5*8+:8]=80;levels[15*8+:8]=255;
        repeat(4)@(negedge clk);rst=0;done_toggle=1;
        repeat(5)@(negedge clk);vs=1;@(negedge clk);vs=0;
        repeat(3)@(negedge clk);
        if(!ack_toggle)$fatal(1,"spectrum mailbox was not acknowledged");
        for(y=0;y<720;y=y+1)begin
            de=1;
            for(x=0;x<1280;x=x+1)begin
                #1;expected=0;expected_rgb=24'h26394E;
                // A later producer result may replace the raw mailbox as soon
                // as ACK propagates. The captured frame must remain intact.
                if(y==0 && x==8)begin levels=0;done_toggle=0;end
                if(x>=128 && x<1152 && (x-128)%64<48)begin
                    bin=(x-128)/64;level=(bin==0 || bin==15)?120:(bin==5?80:0);
                    height=(4*level+1)/3;
                    if(height!=0 && y>=710-height && y<710)begin
                        expected=1;expected_rgb=(height>128 && y<713-height)?24'hF6BD71:
                            (bin<8?24'h5DD5CA:24'h7FAFE6);
                    end else if(y>=708 && y<710)expected=1;
                end
                if(shade!==0 || hit!==expected || (expected && rgb!==expected_rgb))
                    $fatal(1,"spectrum x=%0d y=%0d shade=%b hit=%b/%b rgb=%h/%h",x,y,shade,hit,expected,rgb,expected_rgb);
                @(negedge clk);
            end
            de=0;repeat(3)@(negedge clk);
        end
        levels=0;done_toggle=0;repeat(5)@(negedge clk);
        if(dut.levels_frame[0+:8]!=160)$fatal(1,"mailbox changed without a frame boundary");
        vs=1;@(negedge clk);vs=0;repeat(40)@(negedge clk);
        if(dut.levels_frame!==128'd0)$fatal(1,"mailbox did not commit at VS");
        enable=0;repeat(4)@(negedge clk);
        if(shade || hit)$fatal(1,"disabled spectrum not hidden");
        $display("PASS spectrum: 160px clamp/golden, all 16 bands, transparent gaps and frame-atomic mailbox");$finish;
    end
endmodule
