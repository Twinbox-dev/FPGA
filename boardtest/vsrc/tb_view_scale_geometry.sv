`timescale 1ns/1ps
module tb_view_scale_geometry;
    reg clk=0,rst=1,start=0;
    always #4 clk=~clk;
    reg [11:0] sw=0,sh=0;
    reg [1:0] layout=0;
    wire busy,done,error;
    wire [11:0] dw,dh,left_pad,bottom_pad;
    wire [31:0] xs,ys,xo,yo;
    view_scale_geometry dut(.clk(clk),.rst(rst),.start(start),.source_width(sw),
        .source_height(sh),.layout(layout),.busy(busy),.done(done),.error(error),
        .dest_width(dw),.dest_height(dh),.left_pad(left_pad),.bottom_pad(bottom_pad),
        .x_step(xs),.y_step(ys),.x_origin(xo),.y_origin(yo));
    integer cases=0,i;
    task automatic check(input integer w,h,mode);
        integer lw,lh,ew,eh,exs,eys,exo,eyo,watchdog;
        begin
            lw=mode==0?1280:640;lh=mode==2?360:720;ew=w;eh=h;
            if(w>lw || h>lh)begin
                if(w*lh>=h*lw)begin ew=lw;eh=(h*lw)/w;if(eh==0)eh=1;end
                else begin eh=lh;ew=(w*lh)/h;if(ew==0)ew=1;end
            end
            exs=ew>1?((w-1)<<16)/(ew-1):0;eys=eh>1?((h-1)<<16)/(eh-1):0;
            exo=ew==1?(w-1)<<15:0;eyo=eh==1?(h-1)<<15:0;
            @(negedge clk);sw=w;sh=h;layout=mode;start=1;
            @(negedge clk);start=0;watchdog=0;
            while(!done && watchdog<120)begin @(negedge clk);watchdog++;end
            if(watchdog>=120 || error || dw!=ew || dh!=eh || xs!=exs || ys!=eys ||
               xo!=exo || yo!=eyo || left_pad!=(lw-ew)/2 || bottom_pad!=(lh-eh)-(lh-eh)/2)
                $fatal(1,"geometry %0dx%0d layout%0d got %0dx%0d steps %h,%h expected %0dx%0d %h,%h",
                       w,h,mode,dw,dh,xs,ys,ew,eh,exs,eys);
            cases++;
        end
    endtask
    initial begin
        repeat(5)@(negedge clk);rst=0;
        check(1280,720,0);check(1280,720,1);check(1280,720,2);
        check(640,480,1);check(640,480,2);check(504,720,2);check(571,720,2);
        check(1,1,2);check(1,720,2);check(3,720,2);check(1280,1,2);
        check(333,217,2);check(1280,719,2);
        for(i=0;i<60;i++)check(1+($urandom%1280),1+($urandom%720),1+($urandom%2));
        $display("PASS: %0d aspect-fit, no-upscale, Q16 endpoint and single-pixel geometry cases",cases);
        $finish;
    end
    initial begin #200000;$fatal(1,"geometry timeout");end
endmodule
