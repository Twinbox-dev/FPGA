`timescale 1ns/1ps
module tb_video_hybrid_pipeline #(
 parameter W=32,H=12,WIN=32,HD=4,HT=160,VT=20,FRAMES=4,STALL_NS=0,INJECT_CRC=0,INJECT_TAG=0,WAIT_READY=0,RECOVER_HOLE=0,INJECT_METADATA=0
);
 reg ac=0,mc=0,pc=0,rst=1;always #4 ac=~ac;always #5 mc=~mc;always #6.667 pc=~pc;
 reg begin_row=0,rowstart=0,pwrite=0,commit=0;reg [15:0] fid=0,seq=0,pixel=0,seed=0,expected_crc=0;
 reg [8:0] ry=0;reg [9:0] px=0;wire source_ready,credit_event,nack;wire [15:0] credit,nseq;wire [7:0] free_rows;
 wire [31:0] good,bad,dups,word,underflows;wire [95:0] stats,read_stats;wire available,ready,wvalid;
 wire session_ready;wire [15:0] ready_seq,ready_frame;reg granted=0;
 wire memory_enable=!WAIT_READY||granted;
 initial begin if(WAIT_READY)begin #2000000;granted=1;end end
 reg ready_seen=0;always @(posedge ac)if(session_ready)begin if(ready_seq!==FIRST||ready_frame!==100)$fatal(1,"READY identity wrong");ready_seen<=1;end
 reg fs=0,ls=0,ld=0,pop=0;reg [9:0] vy=0;
 wire awe,are;wire [20:0] awa,ara;wire [31:0] awdata;reg svalid=0;reg [31:0] sdata=0;
 reg [31:0] mcycle=0;wire busy=mcycle%97>=73 && mcycle%97<79;
 wire refresh=mcycle%3125>=3100 && mcycle%3125<3110;
 wire hold_response=mcycle%10000>=1600 && mcycle%10000<1900;
 localparam [15:0] FIRST=65500;
 localparam integer CORRUPT_SLOT=(FIRST+10)&(WIN-1);
 localparam integer CORRUPT_ADDR=CORRUPT_SLOT*512+(INJECT_TAG?0:5);
 video_hybrid_pipeline #(.WIDTH(W),.HEIGHT(H),.WINDOW(WIN),.HEAD_ROWS(HD),.PRIME_ROWS(H),.INGRESS_PAGES(4)) dut(
 .app_clk(ac),.mem_clk(mc),.pixel_clk(pc),.rst(rst),.memory_enable(memory_enable),.sdr_init_done(!rst),.sdr_busy(busy),.sdr_refresh(refresh),.scratch_base(21'd0),
 .row_begin(begin_row),.row_start(rowstart),.pixel_write(pwrite),.row_commit(commit),.row_reject(1'b0),
 .row_frame(fid),.row_sequence(seq),.pixel_data(pixel),.crc_seed(seed),.crc_expected(expected_crc),.row_index(ry),.pixel_index(px),
 .ready_event(session_ready),.ready_sequence(ready_seq),.ready_frame(ready_frame),.memory_active(),.memory_idle(),.video_missing(),.source_ready(source_ready),.credit_sequence(credit),.credit_event(credit_event),.free_rows(free_rows),.accepted_rows(good),.rejected_rows(bad),.duplicate_rows(dups),
 .hybrid_stats(stats),.readback_stats(read_stats),.nack_event(nack),.nack_sequence(nseq),.frame_start(fs),.line_start(ls),.line_done(ld),.word_pop(pop),.video_y(vy),
 .word_data(word),.word_valid(wvalid),.line_available(available),.video_ready(ready),.underflows(underflows),
 .app_wr_en(awe),.app_wr_addr(awa),.app_wr_data(awdata),.app_rd_en(are),.app_rd_addr(ara),.sdr_rd_en(svalid),.sdr_rd_data(sdata));
 reg [31:0] mem[0:WIN*512-1],response_data[0:127],response_due[0:127];
 reg [6:0] qw=0,qr=0;integer qcount=0;reg injected=0;
 wire response_pop=qcount!=0 && response_due[qr]<=mcycle && !hold_response;
 always @(posedge mc)begin
  if(rst)begin mcycle<=0;qw<=0;qr<=0;qcount<=0;svalid<=0;injected<=0;end
  else begin
   mcycle<=mcycle+1'b1;svalid<=0;
   if(awe)mem[awa]<=awdata;
   if(are)begin
    response_data[qw]<=mem[ara]^(((INJECT_CRC||INJECT_TAG)&&!injected&&ara==CORRUPT_ADDR)?32'd1:32'd0);
    response_due[qw]<=mcycle+3+ara[1:0];qw<=qw+1'b1;
    if((INJECT_CRC||INJECT_TAG)&&!injected&&ara==CORRUPT_ADDR)injected<=1;
   end
   if(response_pop)begin svalid<=1;sdata<=response_data[qr];qr<=qr+1'b1;end
   case({are,response_pop})2'b10:qcount<=qcount+1;2'b01:qcount<=qcount-1;default:;endcase
   if(awe&&are)$fatal(1,"hybrid simultaneous memory read/write");
   if((awe&&awa>=WIN*512)||(are&&ara>=WIN*512))$fatal(1,"hybrid memory out of range");
   if(qcount>120)$fatal(1,"response model overflow");
  end
 end
 function [15:0] sample(input integer s,x);sample=16'(s ^ (32'h91825+x*37));endfunction
 function [15:0] crc_byte(input [15:0] c,input [7:0] d);
  reg [15:0] v;begin v=c^{d,8'd0};for(integer i=0;i<8;i=i+1)v=v[15]?(v<<1)^16'h1021:v<<1;return v;end
 endfunction
 initial begin:producer
  reg [15:0] c,p;
  repeat(10)@(negedge ac);rst=0;
  for(integer sent=0;sent<FRAMES*H;sent=sent+1)begin : rows
   integer n;
   n=sent;
   if(RECOVER_HOLE)begin
    if(sent==5)n=6;
    else if(sent>5&&sent<H-1)n=sent+1;
    else if(sent==H-1)begin
     wait(nack&&nseq==16'(FIRST+5));@(negedge ac);n=5;
    end
   end
   if(WAIT_READY&&sent==1)begin wait(ready_seen);@(negedge ac);end
   if(STALL_NS>0&&n==H+H/3)#(STALL_NS);
   seq=16'(FIRST+n);fid=16'(100+n/H);ry=n%H;rowstart=n==0;seed=16'hffff^16'(seq*31);c=seed;
   if(n!=0)while(16'(seq-credit)>=WIN)@(negedge ac);
   // The 72-cycle gap plus row strobes models Ethernet header/FCS/IFG.
   repeat(72)@(negedge ac);begin_row=1;@(negedge ac);begin_row=0;
   for(integer x=0;x<W;x=x+1)begin
    p=sample(FIRST+n,x);c=crc_byte(crc_byte(c,p[7:0]),p[15:8]);pwrite=1;px=x;pixel=p;
    @(negedge ac);pwrite=0;@(negedge ac);
   end
   repeat(3)@(negedge ac);expected_crc=c;commit=1;@(negedge ac);commit=0;rowstart=0;
  end
 end
 // Inject a single corrupted CRC field at the actual BRAM metadata output.
 // Row identity still matches, so payload CRC must reject and hide that row.
 generate if(INJECT_METADATA)begin:g_metadata_fault
  reg used=0,forced=0;reg [95:0] damaged;
  always @(negedge mc)begin
   if(forced)begin release dut.tag_read_data;forced=0;end
   else if(!used && dut.state==5 && dut.purpose==1 && dut.job_seq==16'(FIRST+10))begin
    damaged=dut.tag_read_data^(96'd1<<64);force dut.tag_read_data=damaged;used=1;forced=1;
   end
  end
 end endgenerate
 integer total_words=0;
 initial begin:consumer
  reg missing_expected;
  wait(dut.primed);repeat(8)@(negedge pc);
  for(integer f=0;f<FRAMES;f=f+1)begin
   fs=1;@(negedge pc);fs=0;repeat(4)@(negedge pc);
   if(!ready)$fatal(1,"hybrid failed to arm frame%0d state%0d",f,dut.state);
   for(integer y=0;y<H;y=y+1)begin
    vy=y;ls=1;@(negedge pc);ls=0;repeat(18)@(negedge pc);
    missing_expected=(INJECT_CRC||INJECT_TAG||INJECT_METADATA)&&f==0&&y==10;
    if(available==missing_expected)$fatal(1,"hybrid row validity frame%0d y%0d avail%0d expected_missing%0d good%0d bad%0d ingressbad%0d state%0d seq%0d pf%0d cons%0d stats%h",f,y,available,missing_expected,good,bad,dut.ingress_bad,dut.state,dut.job_seq,dut.prefetch_seq,credit,stats);
    for(integer x=0;x<W/2;x=x+1)begin
     pop=1;@(posedge pc);#1;
     if(missing_expected)begin if(word!==32'hf800f800)$fatal(1,"corrupt row was not hidden");end
     else if(!wvalid || word!=={sample(FIRST+f*H+y,x*2+1),sample(FIRST+f*H+y,x*2)})
      $fatal(1,"hybrid pixel mismatch f%0d y%0d word%0d got%h",f,y,x,word);
     total_words++;@(negedge pc);pop=0;@(negedge pc);
    end
    repeat(4)@(negedge pc);ld=1;@(negedge pc);ld=0;repeat(HT-W-25)@(negedge pc);
   end
   repeat((VT-H)*HT)@(negedge pc);
  end
  repeat(10)@(negedge ac);
  if(read_stats[15:0]!=FRAMES*H-((INJECT_CRC||INJECT_TAG||INJECT_METADATA)?1:0))$fatal(1,"HDMI head CRC checker row count invalid %0d",read_stats[15:0]);
  if(read_stats[31:16]!=0)$fatal(1,"HDMI head readback CRC failed %h",read_stats);
  if(stats[95:80]!=0)$fatal(1,"hybrid port failure");
  if(!(INJECT_CRC||INJECT_TAG||INJECT_METADATA) && (bad!=0 || underflows!=0 || stats[79:48]!=0))$fatal(1,"hybrid loss bad%0d underflows%0d stats%h",bad,underflows,stats);
  if((INJECT_CRC||INJECT_METADATA) && stats[63:48]!=1)$fatal(1,"CRC fault counter invalid");
  if(INJECT_TAG && stats[79:64]!=1)$fatal(1,"tag fault counter invalid");
  $display("PASS hybrid W%0d H%0d: %0d RGB565 words golden, 3 clocks, stall%0d ns, CRCfault%0d tagfault%0d, stats%h",W,H,total_words,STALL_NS,INJECT_CRC,INJECT_TAG,stats);$finish;
 end
 initial begin #150000000;$display("state%0d active%0d primed%0d occ%0d pf%0d cons%0d ingress_good%0d bad%0d stats%h",dut.state,dut.active,dut.primed,dut.occupancy,dut.prefetch_seq,credit,dut.ingress_good,dut.ingress_bad,stats);$fatal(1,"hybrid test timeout");end
endmodule
