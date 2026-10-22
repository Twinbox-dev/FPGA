`timescale 1ns/1ps
module tb_view_bilinear_shrink #(parameter PIPELINE=0);
    reg clk=0,rst=1,begin_frame=0,end_frame=0;
    always #4 clk=~clk;
    reg [11:0] sw=0,sh=0;
    reg [1:0] layout=2;
    wire in_ready,out_valid,out_begin,busy,done,error;
    wire [11:0] dw,dh;
    wire [31:0] out_data;
    reg out_ready=1;
    integer cfg_w=0,cfg_h=0,provided=0,expected_w=0,expected_h=0;
    integer input_words=0,sent=0,received=0,cycles=0,cases=0;
    function automatic [15:0] source_pixel(input integer index);
        integer x,y,r,g,b;
        begin
            x=index%cfg_w;y=index/cfg_w;
            r=(x*3+y*5)&31;g=(x*7+y*11)&63;b=(x*13+y*17)&31;
            source_pixel=index<provided ? ((r<<11)|(g<<5)|b) : 0;
        end
    endfunction
    wire [31:0] in_data={(sent*2+1<provided ? source_pixel(sent*2+1) : 16'd0),source_pixel(sent*2)};
    wire in_valid=!rst && busy && sent<input_words && cycles%11!=0;
    generate if(!PIPELINE)begin:g_shrink
    view_bilinear_shrink dut(.clk(clk),.rst(rst),.frame_begin(begin_frame),.frame_end(end_frame),
        .source_width(sw),.source_height(sh),.layout(layout),.in_data(in_data),.in_valid(in_valid),
        .in_ready(in_ready),.out_frame_begin(out_begin),.out_width(dw),.out_height(dh),
        .out_data(out_data),.out_valid(out_valid),.out_ready(out_ready),.busy(busy),.done(done),.error(error));
    end else begin:g_pipeline
        assign busy=1;assign error=0;assign out_begin=0;assign dw=expected_w;assign dh=expected_h;
        view_image_pipeline dut(.clk(clk),.rst(rst),.frame_begin(begin_frame),.frame_end(end_frame),
            .image_width(sw),.image_height(sh),.layout(layout),.in_audio(1'b0),
            .in_start(1'b0),.in_done(1'b0),.in_count(9'd0),.in_data(in_data),.in_valid(in_valid),
            .in_ready(in_ready),.out_audio(),.out_start(),.out_done(),.out_count(),
            .out_data(out_data),.out_valid(out_valid),.out_ready(out_ready),.frame_done(done));
    end endgenerate
    reg done_seen;
    always @(posedge clk)if(rst || begin_frame)done_seen<=0;else if(done)done_seen<=1;

    // Independent four-corner weighted sum, with one final rounding operation.
    function automatic [15:0] expected_pixel(input integer index);
        integer x,y,xq,yq,x0,x1,y0,y1,fx,fy,ch,mask,shift;
        integer a,b,c,d,value,result;
        begin
            if(index>=expected_w*expected_h)expected_pixel=0;
            else if(expected_w==cfg_w && expected_h==cfg_h)expected_pixel=source_pixel(index);
            else begin
                x=index%expected_w;y=index/expected_w;
                if(expected_w==1)xq=(cfg_w-1)<<15;
                else if(x==expected_w-1)xq=(cfg_w-1)<<16;
                else xq=(((cfg_w-1)<<16)/(expected_w-1))*x;
                if(expected_h==1)yq=(cfg_h-1)<<15;
                else if(y==expected_h-1)yq=(cfg_h-1)<<16;
                else yq=(((cfg_h-1)<<16)/(expected_h-1))*y;
                x0=xq>>16;y0=yq>>16;x1=x0+1<cfg_w?x0+1:x0;y1=y0+1<cfg_h?y0+1:y0;
                fx=(xq>>8)&255;fy=(yq>>8)&255;result=0;
                for(ch=0;ch<3;ch++)begin
                    shift=ch==0?0:(ch==1?5:11);mask=ch==1?63:31;
                    a=(source_pixel(y0*cfg_w+x0)>>shift)&mask;
                    b=(source_pixel(y0*cfg_w+x1)>>shift)&mask;
                    c=(source_pixel(y1*cfg_w+x0)>>shift)&mask;
                    d=(source_pixel(y1*cfg_w+x1)>>shift)&mask;
                    value=(a*(256-fx)*(256-fy)+b*fx*(256-fy)+c*(256-fx)*fy+d*fx*fy+32768)>>16;
                    result=result|(value<<shift);
                end
                expected_pixel=result;
            end
        end
    endfunction
    function automatic [15:0] stream_expected(input integer index);
        integer cw,ch,left,bottom,x,y;
        begin
            cw=layout==0 ? 1280 : 640;ch=layout==2 ? 360 : 720;
            x=index%cw;y=index/cw;left=(cw-expected_w)/2;bottom=(ch-expected_h+1)/2;
            stream_expected=!PIPELINE ? expected_pixel(index) :
                (x>=left && x<left+expected_w && y>=bottom && y<bottom+expected_h ?
                 expected_pixel((y-bottom)*expected_w+x-left) : 16'd0);
        end
    endfunction
    always @(negedge clk)out_ready=rst || (cycles%17!=0 && cycles%97>4);
    always @(posedge clk)begin
        if(rst || begin_frame)begin sent<=0;received<=0;cycles<=0;end
        else begin
            cycles<=cycles+1;
            if(in_valid && in_ready)sent<=sent+1;
            if(out_begin && (dw!=expected_w || dh!=expected_h))
                $fatal(1,"shrink metadata got %0dx%0d expected %0dx%0d",dw,dh,expected_w,expected_h);
            if(out_valid && out_ready)begin
                if(out_data!=={stream_expected(received*2+1),stream_expected(received*2)})
                    $fatal(1,"bilinear %0dx%0d->%0dx%0d word%0d got%08x expected%08x state%0d",
                           cfg_w,cfg_h,expected_w,expected_h,received,out_data,
                           {stream_expected(received*2+1),stream_expected(received*2)},0);
                received<=received+1;
            end
        end
    end
    task automatic check(input integer w,h,mode,available);
        integer lw,lh,watchdog,expected_words;
        begin
            @(negedge clk);rst=(cases==0);cfg_w=w;cfg_h=h;provided=available;sw=w;sh=h;layout=mode;
            lw=mode==0?1280:640;lh=mode==2?360:720;expected_w=w;expected_h=h;
            if(w>lw || h>lh)begin
                if(w*lh>=h*lw)begin expected_w=lw;expected_h=h*lw/w;if(expected_h==0)expected_h=1;end
                else begin expected_h=lh;expected_w=w*lh/h;if(expected_w==0)expected_w=1;end
            end
            input_words=(provided+1)/2;
            expected_words=PIPELINE ? lw*lh/2 : (expected_w*expected_h+1)/2;
            repeat(4)@(negedge clk);rst=0;
            @(negedge clk);begin_frame=1;
            @(negedge clk);begin_frame=0;
            wait(sent==input_words);
            @(negedge clk);end_frame=1;
            @(negedge clk);end_frame=0;watchdog=0;
            while((!(done || done_seen) || received!=expected_words) && watchdog<8000000)begin @(negedge clk);watchdog++;end
            if(watchdog>=8000000 || error || received!=expected_words)
                $fatal(1,"shrink completion error %0dx%0d received%0d expected%0d",w,h,received,expected_words);
            cases++;
            $display("PASS: bilinear %0dx%0d -> %0dx%0d (%0d source pixels), every RGB565 output exact",w,h,expected_w,expected_h,provided);
        end
    endtask
    initial begin
        check(1280,720,2,1280*720);
        check(640,480,2,640*480);
        check(571,720,2,571*720);
        check(504,720,1,504*720);
        check(333,217,2,333*217);
        check(1,1,2,1);
        check(3,720,2,3*720);
        check(1280,1,2,1280);
        check(640,480,2,640*480-3);
        $display("PASS: %0d consecutive bilinear/pass-through/single-axis/truncated cases, no inter-image reset, with source/sink backpressure",cases);
        $finish;
    end
    initial begin #1000000000;$fatal(1,"bilinear test timeout");end
endmodule
