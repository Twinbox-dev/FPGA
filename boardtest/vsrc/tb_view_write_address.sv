`timescale 1ns/1ps
module tb_view_write_address;
    reg clk=0,rst=1,start=0,advance=0;
    always #5 clk=~clk;
    reg [20:0] base=0;
    reg [1:0] layout=0,window=0;
    wire [20:0] address,total;
    wire [9:0] remaining;
    wire active,done,error;
    view_write_address dut(.clk(clk),.rst(rst),.start(start),.advance(advance),
        .frame_base(base),.layout(layout),.window(window),.address(address),
        .total_words(total),.line_words(remaining),.active(active),.done(done),.error(error));
    task automatic check(input integer mode,win,frame_base);
        integer width,height,words,i,expected,slot_base;
        begin
            width=mode==0?640:320;height=mode==2?360:720;words=width*height;
            slot_base=frame_base+win*words;
            @(negedge clk);layout=mode;window=win;base=frame_base;start=1;
            @(negedge clk);start=0;
            for(i=0;i<words;i++)begin
                expected=slot_base+(height-1-i/width)*width+i%width;
                if(!active || error || total!=words || address!=expected || remaining!=width-i%width ||
                   address<slot_base || address>=slot_base+words)
                    $fatal(1,"write slot layout%0d window%0d word%0d addr%0d expected%0d",mode,win,i,address,expected);
                if(i%13==0)begin repeat(2)@(negedge clk);if(address!=expected)$fatal(1,"write moved under stall");end
                advance=1;@(negedge clk);advance=0;
            end
            if(!done || active)$fatal(1,"write slot completion count mismatch");
            $display("PASS: layout%0d window%0d base%0d all %0d flipped writes stay inside their slot",mode,win,frame_base,words);
            repeat(3)@(negedge clk);
        end
    endtask
    initial begin
        repeat(5)@(negedge clk);rst=0;
        check(0,0,0);check(1,0,460800);check(1,1,460800);
        check(2,0,0);check(2,1,0);check(2,2,0);check(2,3,0);
        $display("PASS: every full/dual/quad slot address, row boundary and frame length exact");
        $finish;
    end
    initial begin #100000000;$fatal(1,"write-address timeout");end
endmodule
