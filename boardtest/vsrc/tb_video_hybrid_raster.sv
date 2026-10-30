`timescale 1ns/1ps
module tb_video_hybrid_raster #(
 parameter W=32,H=12,WIN=32,HD=4,HT=160,VT=20,FRAMES=4,STALL_NS=0,INJECT_CRC=0,INJECT_TAG=0,PRODUCT_CHAIN=0,SCALE2=0
);
 reg ac=0,mc=0,pc=0,rst=1;always #4 ac=~ac;always #5 mc=~mc;always #6.667 pc=~pc;
 reg begin_row=0,rowstart=0,pwrite=0,commit=0;reg [15:0] fid=0,seq=0,pixel=0,seed=0,expected_crc=0;
 reg [8:0] ry=0;reg [9:0] px=0;wire source_ready,credit_event,nack;wire [15:0] credit,nseq;wire [7:0] free_rows;
 wire [31:0] good,bad,dups,word,underflows;wire [95:0] stats,read_stats;wire available,ready,wvalid;
 reg vs=1,de=0,hs=1;reg de_q=0,vs_q=1,pop_q=0,fetch_de_q=0;wire fetch_de;reg [9:0] vy=0;
 wire fs=vs_q&&!vs,ls=de&&!de_q,ld=SCALE2?(!fetch_de&&fetch_de_q):(!de&&de_q),pop=pop_q;
 wire read_en,delayed_de,delayed_vs,delayed_hs,unpack_de,unpack_vs;wire [23:0] raw_rgb,rgb,display_rgb;
 always @(posedge pc)begin
  if(rst)begin de_q<=0;vs_q<=1;pop_q<=0;fetch_de_q<=0;end
  else begin de_q<=de;vs_q<=vs;pop_q<=read_en;fetch_de_q<=fetch_de;end
 end
 video_delay #(.MIX_PIPELINE(1),.REPEAT_2X_ENABLED(SCALE2)) unpack(.repeat_2x(1'b1),.video_clk(pc),.rst(rst),.read_en(read_en),.read_data(word),.hs(hs),.vs(vs),.de(de),
 .hs_r(delayed_hs),.vs_r(unpack_vs),.de_r(unpack_de),.de_word(fetch_de),.vs_word(),.vout_data(raw_rgb));
 generate if(PRODUCT_CHAIN)begin:product_chain
  cv_pixel_effects_runtime #(.H_ACTIVE(1280),.H_TOTAL(1650),.V_ACTIVE(720)) cv(
   .clk(pc),.rst(rst),.rgb_in(raw_rgb),.de_in(unpack_de),.vs_in(unpack_vs),.mode_raw(3'd0),
   .rgb_out(display_rgb),.de_out(delayed_de),.vs_out(delayed_vs));
 end else begin:direct_chain
  assign display_rgb=raw_rgb;assign delayed_de=unpack_de;assign delayed_vs=unpack_vs;
 end endgenerate
 direct_video_region_mux #(.VIDEO_WIDTH(W*(SCALE2?2:1)),.VIDEO_HEIGHT(H*(SCALE2?2:1))) region(.clk(pc),.rst(rst),.video_mode(1'b1),
 .de(delayed_de),.vs(delayed_vs),.video_rgb(display_rgb),.still_rgb(24'd0),.rgb_out(rgb));
 wire awe,are;wire [20:0] awa,ara;wire [31:0] awdata;reg svalid=0;reg [31:0] sdata=0;
 reg [31:0] mcycle=0;wire busy=mcycle%97>=73 && mcycle%97<79;
 wire refresh=mcycle%3125>=3100 && mcycle%3125<3110;
 wire hold_response=mcycle%10000>=1600 && mcycle%10000<1900;
 localparam [15:0] FIRST=65500;
 localparam integer CORRUPT_SLOT=(FIRST+10)&(WIN-1);
 localparam integer CORRUPT_ADDR=CORRUPT_SLOT*512+(INJECT_TAG?0:5);
 video_hybrid_pipeline #(.WIDTH(W),.HEIGHT(H),.WINDOW(WIN),.HEAD_ROWS(HD),.PRIME_ROWS(H),.INGRESS_PAGES(4)) dut(
 .app_clk(ac),.mem_clk(mc),.pixel_clk(pc),.rst(rst),.memory_enable(1'b1),.sdr_init_done(!rst),.sdr_busy(busy),.sdr_refresh(refresh),.scratch_base(21'd0),
 .row_begin(begin_row),.row_start(rowstart),.pixel_write(pwrite),.row_commit(commit),.row_reject(1'b0),
 .row_frame(fid),.row_sequence(seq),.pixel_data(pixel),.crc_seed(seed),.crc_expected(expected_crc),.row_index(ry),.pixel_index(px),
 .memory_active(),.memory_idle(),.video_missing(),.source_ready(source_ready),.credit_sequence(credit),.credit_event(credit_event),.free_rows(free_rows),.accepted_rows(good),.rejected_rows(bad),.duplicate_rows(dups),
 .hybrid_stats(stats),.readback_stats(read_stats),.nack_event(nack),.nack_sequence(nseq),.frame_start(fs),.line_start(ls),.line_done(ld&&(!SCALE2||vy[0])),.word_pop(pop),.video_y(SCALE2?(vy>>1):vy),
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
  for(integer n=0;n<FRAMES*H;n=n+1)begin
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
 integer checked_pixels=0,out_frame=-1,out_x=0,out_y=0;reg de_monitor=0,vs_monitor=0;
 function [23:0] expand565(input [15:0] p);expand565={p[15:11],p[15:13],p[10:5],p[10:9],p[4:0],p[4:2]};endfunction
 always @(posedge pc)begin
  #1;
  if(!rst)begin
   if(vs_monitor&&!delayed_vs)begin out_frame++;out_y=0;end
   if(delayed_de)begin
    if(!de_monitor)out_x=0;else out_x++;
    if(out_frame>=0 && out_frame<FRAMES)begin
     if(rgb!==((out_x<W*(SCALE2?2:1)&&out_y<H*(SCALE2?2:1))?expand565(sample(FIRST+out_frame*H+(out_y/(SCALE2?2:1)),out_x/(SCALE2?2:1))):24'd0))
      $fatal(1,"raster RGB mismatch f%0d y%0d x%0d got%h",out_frame,out_y,out_x,rgb);
     checked_pixels++;
    end
   end else if(de_monitor)out_y++;
   de_monitor=delayed_de;vs_monitor=delayed_vs;
  end
 end
 initial begin:consumer
  wait(dut.primed);repeat(8)@(negedge pc);
  for(integer f=0;f<FRAMES;f=f+1)begin
   vs=0;repeat(5*HT)@(negedge pc);vs=1;repeat(20*HT)@(negedge pc);
   for(integer y=0;y<720;y=y+1)begin
    vy=y;hs=0;repeat(40)@(negedge pc);hs=1;repeat(220)@(negedge pc);
    de=1;repeat(1280)@(negedge pc);de=0;repeat(110)@(negedge pc);
   end
   repeat(5*HT)@(negedge pc);
  end
  repeat(40)@(negedge pc);repeat(10)@(negedge ac);
  if(checked_pixels!=FRAMES*1280*720)$fatal(1,"raster pixel count %0d",checked_pixels);
  if(read_stats[31:16]!=0 || read_stats[15:0]!=FRAMES*H*(SCALE2?2:1))$fatal(1,"raster head CRC evidence invalid %h",read_stats);
  if(bad || underflows || stats[95:48])$fatal(1,"raster loss bad%0d uflow%0d stats%h",bad,underflows,stats);
  $display("PASS actual 1280x720 raster: %0d RGB888 pixels, native RGB565 video+black margins, video_delay, all read CRCs exact",checked_pixels);$finish;
 end
 initial begin #150000000;$display("state%0d active%0d primed%0d occ%0d pf%0d cons%0d ingress_good%0d bad%0d stats%h",dut.state,dut.active,dut.primed,dut.occupancy,dut.prefetch_seq,credit,dut.ingress_good,dut.ingress_bad,stats);$fatal(1,"hybrid test timeout");end
endmodule
