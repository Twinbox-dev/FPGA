`timescale 1ns/1ps
module tb_view_scan_address;
    reg clk=0,rst=1,start=0,advance=0;
    always #5 clk=~clk;
    reg [20:0] base=0;
    reg [20:0] alt_base=460800;
    reg [1:0] layout=0;
    reg [3:0] mask=0;
    reg [3:0] buffers=0;
    wire [20:0] addr;
    wire [1:0] window_index;
    wire black,active,done,error;
    wire [9:0] remaining;
    view_scan_address dut(.clk(clk),.rst(rst),.frame_begin(start),.advance(advance),
        .frame_base(base),.frame_base_alt(alt_base),.window_buffers(buffers),
        .layout(layout),.valid_mask(mask),.address(addr),
        .window_index(window_index),.black(black),.segment_words(remaining),
        .active(active),.done(done),.error(error));
    task automatic run(input integer mode,frame_base,valid_windows,page_select);
        integer i,x,y,window_num,expected,segment,black_words,page_base;
        begin
            @(negedge clk);layout=mode;base=frame_base;alt_base=frame_base==0 ? 460800 : 0;
            mask=valid_windows;buffers=page_select;start=1;
            @(negedge clk);start=0;black_words=0;
            for(i=0;i<460800;i++)begin
                x=i%640;y=i/640;
                if(mode==0)begin window_num=0;expected=frame_base+i;segment=640-x;end
                else if(mode==1)begin
                    window_num=x>=320;expected=frame_base+window_num*230400+y*320+x%320;segment=320-x%320;
                end else begin
                    window_num=(y>=360)*2+(x>=320);
                    expected=frame_base+window_num*115200+(y%360)*320+x%320;segment=320-x%320;
                end
                page_base=((page_select>>window_num)&1) ? (frame_base==0 ? 460800 : 0) : frame_base;
                expected=expected-frame_base+page_base;
                if(!active || error || addr!=expected || window_index!=window_num ||
                   remaining!=segment || black!=!(valid_windows&(1<<window_num)))
                    $fatal(1,"scan layout%0d word%0d gotaddr%0d win%0d rem%0d expected%0d/%0d/%0d",
                           mode,i,addr,window_index,remaining,expected,window_num,segment);
                if(black)black_words++;
                if(i%11==0)begin
                    repeat(2)@(negedge clk);
                    if(addr!=expected)$fatal(1,"address advanced under stall");
                end
                advance=1;@(negedge clk);advance=0;
            end
            if(!done || active)$fatal(1,"scan did not finish at exactly 460800 words");
            $display("PASS: layout%0d base%0d mask%04b page-select%04b every slot address exact (%0d black)",
                     mode,frame_base,valid_windows[3:0],page_select[3:0],black_words);
            repeat(3)@(negedge clk);
        end
    endtask
    initial begin
        repeat(5)@(negedge clk);rst=0;
        run(0,0,1,0);run(1,460800,1,0);run(2,0,15,0);run(2,460800,10,0);
        run(1,0,3,2'b0010);run(2,0,15,4'b1010);
        $display("PASS: single/dual/quad scan mapping, mixed page pointers, stalls and invalid masks");
        $finish;
    end
    initial begin #100000000;$fatal(1,"scan-address timeout");end
endmodule
