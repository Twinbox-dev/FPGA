`timescale 1ns/1ps
module tb_display_tx_packet_fifo;
    reg wc=0,rc=0,rst=1;always #5 wc=~wc;always #4 rc=~rc;
    reg [7:0] wd=0;reg sof=1,eof=1,valid_n=1,en=1,ack=0;
    wire ready_n,overflow,tv;wire [7:0] td;
    display_tx_packet_fifo dut(.wr_clk(wc),.wr_sreset(rst),.wr_data(wd),
        .wr_sof_n(sof),.wr_eof_n(eof),.wr_src_rdy_n(valid_n),.wr_dst_rdy_n(ready_n),.wr_fifo_status(),
        .rd_clk(rc),.rd_sreset(rst),.rd_enable(en),.tx_data(td),.tx_data_valid(tv),
        .tx_ack(ack),.tx_collision(1'b0),.tx_retransmit(1'b0),.overflow(overflow));
    integer cycles=0;
    always @(negedge rc)begin cycles=cycles+1;en=(cycles%7!=1&&cycles%19>2);end
    function automatic [7:0] value(input integer frame_no,index);
        value=8'((frame_no*73)^(index*19)^(index>>2));
    endfunction
    function automatic integer length_of(input integer f);
        case(f%6)0:length_of=1;1:length_of=2;2:length_of=60;3:length_of=74;4:length_of=128;default:length_of=43;endcase
    endfunction
    task automatic transmit(input integer f,n);
        begin
            for(integer i=0;i<n;i++)begin
                @(negedge wc);wd=value(f,i);sof=i!=0;eof=i!=n-1;valid_n=0;
                do @(posedge wc);while(ready_n);
                @(negedge wc);valid_n=1;sof=1;eof=1;
            end
        end
    endtask
    task automatic tick;begin do @(posedge rc);while(!en);end endtask
    task automatic receive(input integer f,n);
        reg [7:0] first;
        begin
            wait(tv);first=td;
            repeat(f%13+1)begin tick();if(!tv||td!==first)$fatal(1,"first byte changed before MAC ACK");end
            @(negedge rc);ack=1;tick();
            if(td!==value(f,0))$fatal(1,"first byte f%0d got%h",f,td);
            @(negedge rc);ack=0;
            for(integer i=1;i<n;i++)begin
                tick();
                if(!tv||td!==value(f,i))$fatal(1,"byte f%0d i%0d got%h expected%h valid%b",f,i,td,value(f,i),tv);
            end
            #1;if(tv)$fatal(1,"MAC valid extended beyond frame length");
        end
    endtask
    task automatic reset_all;
        begin rst=1;valid_n=1;sof=1;eof=1;ack=0;repeat(6)@(negedge wc);rst=0;repeat(6)@(negedge rc);end
    endtask
    initial begin
        reset_all();
        fork
            begin for(integer f=0;f<18;f++)transmit(f,length_of(f));end
            begin for(integer f=0;f<18;f++)receive(f,length_of(f));end
        join
        if(overflow)$fatal(1,"valid replies overflowed");
        transmit(40,130);repeat(100)@(negedge rc);
        if(!overflow||tv||ready_n)$fatal(1,"oversize frame was published or failed to recover");
        fork transmit(41,74);receive(41,74);join
        // Reset after a partial frame, then while a complete frame awaits ACK.
        @(negedge wc);valid_n=0;sof=0;eof=1;wd=8'h5a;@(posedge wc);
        @(negedge wc);valid_n=1;reset_all();
        fork transmit(42,60);receive(42,60);join
        transmit(43,74);wait(tv);reset_all();
        fork transmit(44,128);receive(44,128);join
        $display("PASS display TX mailbox: independent clocks, MAC ACK delay, clock-enable stalls, backpressure, bounds and reset");$finish;
    end
    initial begin #2000000;$fatal(1,"TX mailbox watchdog");end
endmodule
