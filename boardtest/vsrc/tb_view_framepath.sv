`timescale 1ns/1ps
// Real write/read engines and async FIFOs. Only SDRAM storage/latency is a model.
module tb_view_framepath;
    parameter integer USE_STREAM_CLOCK=0;
    reg wc=0,mc=0,vc=0,rst=1;
    reg audio_clk=0;always #5 audio_clk=~audio_clk;
    always #(USE_STREAM_CLOCK ? 4 : 10) wc=~wc;
    always #5 mc=~mc;
    always #6.666 vc=~vc;
    reg wr_req=0,wr_en=0,rd_req=0,rd_en=0;
    reg [31:0] wr_data=0;
    reg [1:0] mode=0,window=0;
    reg [3:0] mask=1;
    reg epoch=0;
    wire wr_ack,wr_ready,wr_finish,rd_ack,rd_finish,empty,drained;
    wire [31:0] rd_data,app_data;
    wire app_wr,app_rd;
    wire [20:0] wa,ra;
    reg [2:0] latency=0;
    reg [20:0] a0=0,a1=0,a2=0;
    reg rv=0;
    reg [31:0] rdata=0;
    reg [31:0] memory[0:460799];
    wire [20:0] length=mode==0 ? 460800 : (mode==1 ? 230400 : 115200);
    reg [7:0] refresh=0;
    always @(posedge mc)refresh<=refresh+1'b1;
    frame_read_write #(.VIEW_ENABLE(1),.STREAM_CLOCK(USE_STREAM_CLOCK),.FRAME_WIDTH(640),.FRAME_HEIGHT(720)) dut(
        .rst(rst),.mem_clk(mc),.Sdr_init_done(1'b1),
        .Sdr_init_ref_vld(refresh>250),.Sdr_busy(refresh>250),
        .App_rd_en(app_rd),.App_rd_addr(ra),.Sdr_rd_en(rv),.Sdr_rd_dout(rdata),
        .read_clk(vc),.read_req(rd_req),.read_req_ack(rd_ack),.read_finish(rd_finish),
        .read_addr_0(21'd0),.read_addr_1(21'd460800),.read_addr_2(21'd921600),.read_addr_3(21'd1509376),
        .read_addr_index(2'd0),.read_len(21'd460800),.read_en(rd_en),.read_data(rd_data),
        .o_vid_rd_empty(empty),.o_mem_rd_audio(),.o_mem_rd_busy(),.o_mem_wr_busy(),
        .o_vid_fifo_words(),.line_hold(1'b0),
        .aud_read_req(1'b0),.aud_read_req_ack(),.aud_read_finish(),.aud_read_addr_index(2'd2),
        .aud_read_len(21'd0),.aud_rd_en(1'b0),.aud_rd_data(),.o_aud_fifo_words(),
        .App_wr_en(app_wr),.App_wr_addr(wa),.App_wr_din(app_data),.App_wr_dm(),
        .write_clk(USE_STREAM_CLOCK ? audio_clk : wc),.write_req(wr_req),.write_req_ack(wr_ack),.write_finish(wr_finish),
        .write_addr_0(21'd0),.write_addr_1(21'd460800),.write_addr_2(21'd921600),.write_addr_3(21'd1509376),
        .write_addr_index(2'd0),.write_len(length),.vrow_off(20'd0),
        .write_ready(wr_ready),.write_en(wr_en),.write_data(wr_data),
        .stream_clk(wc),
        .view_read_layout(mode),.view_write_layout(mode),.view_write_window(window),
        .view_valid_mask(mask),.view_epoch(epoch),.view_drained_epoch(drained));
    integer writes=0,reads=0,last_read=-1,consecutive=0,max_burst=0;
    integer check_write_index=0,expected_address,slot_size,row_words,rows;
    reg check_write=0,check_hidden=0;
    function automatic [31:0] pattern(input integer slot,input integer y,input integer x);
        pattern=32'h91234567 ^ (slot*32'h16273a4b) ^ (y*32'h76543) ^ (x*32'h8ab9);
    endfunction
    always @(posedge mc)begin
        latency<={latency[1:0],app_rd};a0<=ra;a1<=a0;a2<=a1;
        rv<=latency[2];if(latency[2])rdata<=memory[a2];
        if(app_wr)begin
            if(wa>=460800)$fatal(1,"out-of-bank write");
            memory[wa]<=app_data;writes<=writes+1;
            if(check_write)begin
                expected_address=window*slot_size+(rows-1-check_write_index/row_words)*row_words+check_write_index%row_words;
                if(wa!=expected_address || app_data!=pattern(window,rows-1-check_write_index/row_words,check_write_index%row_words))
                    $fatal(1,"slot write mismatch mode=%0d win=%0d i=%0d addr=%0d expected=%0d data=%h",mode,window,check_write_index,wa,expected_address,app_data);
                check_write_index<=check_write_index+1;
            end
        end
        if(app_rd)begin
            reads<=reads+1;consecutive<=consecutive+1;last_read<=ra;
            if(ra>=460800)$fatal(1,"out-of-bank read");
            if(mode!=0 && consecutive!=0 && ra%320==0)
                $fatal(1,"burst crossed a window row");
            if(check_hidden && ((mode==1 && ra>=230400) || (mode==2 && ra>=115200 && ra<230400)))
                $fatal(1,"hidden slot read after drain ACK");
        end else begin
            if(consecutive>max_burst)max_burst<=consecutive;
            consecutive<=0;
        end
    end
    task automatic write_slot(input integer s);
        integer j;
        begin
            @(negedge wc);window=s;check_write_index=0;check_write=1;
            wr_req=1;wait(wr_ack);@(negedge wc);wr_req=0;
            repeat(16)@(negedge wc);
            for(j=0;j<slot_size;j=j+1)begin
                while(!wr_ready)begin wr_en=0;@(negedge wc);end
                wr_en=1;wr_data=pattern(s,rows-1-j/row_words,j%row_words);
                @(negedge wc);
            end
            wr_en=0;wait(wr_finish);repeat(8)@(negedge mc);
            if(check_write_index!=slot_size)$fatal(1,"missing slot writes");
            check_write=0;
        end
    endtask
    task automatic scan_frame(input bit hidden);
        integer j,yy,xx,s,local_y,local_x,warm;
        reg [31:0] expected;
        begin
            if(hidden)begin
                // Hide window 1 while its OLD SDRAM burst has live requests
                // and delayed returns. The new epoch ACK must wait them out.
                @(negedge vc);epoch=~epoch;mask=15;rd_req=1;
                wait(rd_ack);@(negedge vc);rd_req=0;
                warm=0;
                while(!(app_rd && ra>=slot_size && ra<slot_size+128) && warm<20000)begin
                    @(negedge vc);rd_en=warm[0];warm=warm+1;
                end
                rd_en=0;
                if(warm==20000)$fatal(1,"did not reach an in-flight target-window burst");
            end
            @(negedge vc);epoch=~epoch;mask=hidden ? (mode==1 ? 4'b0001 : 4'b1101) : 4'b1111;
            rd_req=1;wait(rd_ack);wait(drained==epoch);
            if(hidden && (rv || latency!=0))$fatal(1,"epoch acknowledged before old SDRAM returns drained");
            @(negedge vc);rd_req=0;check_hidden=hidden;
            repeat(70)@(negedge vc);
            for(j=0;j<460800;j=j+1)begin
                while(empty)@(negedge vc);
                rd_en=1;@(negedge vc);rd_en=0;
                yy=j/640;xx=j%640;
                s=mode==0 ? 0 : (mode==1 ? xx/320 : (yy/360)*2+xx/320);
                local_y=mode==2 ? yy%360 : yy;local_x=mode==0 ? xx : xx%320;
                expected=mask[s] ? pattern(s,local_y,local_x) : 0;
                if(rd_data!==expected)$fatal(1,"scan mismatch mode=%0d hidden=%0d i=%0d got=%h expected=%h",mode,hidden,j,rd_data,expected);
                @(negedge vc);
            end
            wait(rd_finish);check_hidden=0;
            $display("PASS view real FIFO scan mode=%0d mask=%b read_words=%0d max_burst=%0d",mode,mask,reads,max_burst);
        end
    endtask
    integer m,s;
    initial begin
        repeat(12)@(negedge wc);rst=0;
        for(m=0;m<3;m=m+1)begin
            mode=m;row_words=m==0 ? 640 : 320;rows=m==2 ? 360 : 720;
            slot_size=row_words*rows;
            for(s=0;s<(m==0?1:(m==1?2:4));s=s+1)write_slot(s);
            scan_frame(0);
            if(m!=0)scan_frame(1);
        end
        $display("PASS: multiview storage, real async FIFOs, black generation and drain barrier");$finish;
    end
    initial begin #250000000;$fatal(1,"view framepath timeout mode=%0d w=%0d rdstate=%0d burst=%0d limit=%0d black=%0d",mode,window,dut.frame_fifo_read_m0.state,dut.frame_fifo_read_m0.burst_cnt,dut.frame_fifo_read_m0.burst_limit,dut.frame_fifo_read_m0.burst_black);end
endmodule
