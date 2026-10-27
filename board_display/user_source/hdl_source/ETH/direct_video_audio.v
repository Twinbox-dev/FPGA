`timescale 1ns/1ps
// One CRC-protected 396-byte PCM block per video frame. Four bounded slots,
// two native BRAM9K, no new memory controller or audio feedback connection.
module direct_video_audio #(
 parameter SAMPLES=396,HALF_BASE=1562,START_DELAY=15
)(
 input wire app_clk,pixel_clk,rst,
 input wire rx_valid,packet_start,packet_end,input wire [7:0] rx_data,input wire [15:0] packet_length,
 input wire session_event,session_live,input wire [15:0] session_frame,
 input wire video_ready,frame_start,
 output reg missing_seen,output reg audio_valid,output reg [23:0] audio_data,
 output reg [95:0] audio_stats
);
 localparam WORDS=SAMPLES/2,LENGTH=8+SAMPLES+2;
 reg session_known,session_toggle;reg [15:0] base_frame;
 reg [3:0] valid_bits;reg [15:0] tags[0:3],seeds[0:3],expected[0:3];
 reg [9:0] count;wire [9:0] idx=packet_start?0:count;
 reg [7:0] first,low_sample,wire_crc_low;reg identified,header_ok,admitted;
 reg [15:0] fid,crc;reg [1:0] write_slot;
 reg write_q;reg [9:0] write_addr;reg [15:0] write_data;
 reg [15:0] accepted,bad_packets,duplicates;reg audio_enabled;
 reg [15:0] played_frame,played_gray;
 reg [15:0] played_meta,played_sync,played_binary;reg admission_q;reg [1:0] armed_meta;
 reg playing;
 function [15:0] ungray(input [15:0] g);integer n;begin ungray[15]=g[15];for(n=14;n>=0;n=n-1)ungray[n]=ungray[n+1]^g[n];end endfunction
 function [15:0] crc_byte(input [15:0] c,input [7:0] d);
  reg [15:0] v;integer n;begin v=c^{d,8'd0};for(n=0;n<8;n=n+1)v=v[15]?(v<<1)^16'h1021:v<<1;crc_byte=v;end
 endfunction
 wire [15:0] crc_next=crc_byte(packet_start?16'hffff:crc,rx_data);
 wire [15:0] distance=fid-(armed_meta[1]?played_binary:base_frame);
 wire slot_duplicate=valid_bits[fid[1:0]]&&tags[fid[1:0]]==fid;
 wire can_accept=session_known&&!distance[15]&&distance<4&&!(armed_meta[1]&&distance==0)&&!slot_duplicate;
 reg [15:0] parsed_seed;
 always @(posedge app_clk or posedge rst)begin
  if(rst)begin
   session_known<=0;session_toggle<=0;base_frame<=0;valid_bits<=0;count<=0;first<=0;identified<=0;header_ok<=0;admitted<=0;
   fid<=0;crc<=16'hffff;write_slot<=0;low_sample<=0;wire_crc_low<=0;write_q<=0;write_addr<=0;write_data<=0;
   accepted<=0;bad_packets<=0;duplicates<=0;audio_enabled<=0;played_meta<=0;played_sync<=0;played_binary<=0;admission_q<=0;armed_meta<=0;parsed_seed<=0;
  end else begin
   played_meta<=played_gray;played_sync<=played_meta;played_binary<=ungray(played_sync);armed_meta<={armed_meta[0],playing};write_q<=0;
   if(!session_live)begin session_known<=0;audio_enabled<=0;end
   if(session_event&&(!session_known||session_frame!=base_frame))begin
    base_frame<=session_frame;session_known<=1;session_toggle<=~session_toggle;valid_bits<=0;audio_enabled<=0;
   end
   if(packet_start)begin count<=0;identified<=0;header_ok<=packet_length==LENGTH;admitted<=0;end
   if(rx_valid)begin
    count<=idx+1'b1;
    if(idx<8+SAMPLES)crc<=crc_next;
    case(idx)
     0:first<=rx_data;
     1:identified<=first==8'h41&&rx_data==8'h44;
     2:if(rx_data!=1)header_ok<=0;
     3:if(rx_data!=0)header_ok<=0;
     4:fid[7:0]<=rx_data;
     5:fid[15:8]<=rx_data;
     6:begin admission_q<=can_accept;if(rx_data!=SAMPLES%256)header_ok<=0;end
     7:begin
      parsed_seed<=crc_next;write_slot<=fid[1:0];
      admitted<=identified&&header_ok&&rx_data==SAMPLES/256&&admission_q;
      if(identified&&header_ok&&rx_data==SAMPLES/256&&admission_q)valid_bits[fid[1:0]]<=0;
     end
     default:begin
      if(idx>=8&&idx<8+SAMPLES&&admitted)begin
       if(!idx[0])low_sample<=rx_data;
       else begin write_q<=1;write_addr<=write_slot*WORDS+((idx-8)>>1);write_data<={rx_data,low_sample};end
      end
      if(idx==8+SAMPLES)wire_crc_low<=rx_data;
      if(idx==9+SAMPLES&&identified)begin
       if(header_ok&&{rx_data,wire_crc_low}==crc)begin
        if(admitted)begin
         valid_bits[write_slot]<=1;tags[write_slot]<=fid;seeds[write_slot]<=parsed_seed;expected[write_slot]<={rx_data,wire_crc_low};
         accepted<=accepted+1'b1;audio_enabled<=1;
        end else duplicates<=duplicates+1'b1;
       end else bad_packets<=bad_packets+1'b1;
      end
     end
    endcase
   end
  end
 end
 reg [2:0] session_sync;reg session_ack;reg [15:0] base_meta,base_sync;
 reg [3:0] valid_meta,valid_sync;reg [1:0] enabled_sync;
 reg ready_d,block_valid,repeat_half;reg [8:0] sample_index;
 reg [10:0] timer;reg odd_half;
 reg [15:0] play_crc,play_expected,good_blocks,bad_blocks,missing_frames;
 wire [1:0] slot=played_frame[1:0];
 wire [9:0] read_addr=slot*WORDS+(sample_index>>1);
 wire [15:0] q0,q1;reg read_bank;
 wire [15:0] read_word=read_bank?q1:q0;
 wire [7:0] sample_byte=sample_index[0]?read_word[15:8]:read_word[7:0];
 wire [15:0] next_play_crc=crc_byte(play_crc,sample_byte);
 wire [15:0] next_frame=played_frame+1'b1;
 direct_video_bram_9k_16 ram0(.wr_clk(app_clk),.wr_en(write_q&&!write_addr[9]),.wr_addr(write_addr[8:0]),.wr_data(write_data),
  .rd_clk(pixel_clk),.rd_en(playing),.rd_addr(read_addr[8:0]),.rd_data(q0));
 direct_video_bram_9k_16 ram1(.wr_clk(app_clk),.wr_en(write_q&&write_addr[9]),.wr_addr(write_addr[8:0]),.wr_data(write_data),
  .rd_clk(pixel_clk),.rd_en(playing),.rd_addr(read_addr[8:0]),.rd_data(q1));
 task start_block(input [15:0] f);
  begin
   played_frame<=f;sample_index<=0;repeat_half<=0;timer<=START_DELAY;audio_valid<=0;audio_data<=0;odd_half<=0;
   block_valid<=valid_sync[f[1:0]]&&tags[f[1:0]]==f;
   play_crc<=seeds[f[1:0]];play_expected<=expected[f[1:0]];
   if(enabled_sync[1]&&!(valid_sync[f[1:0]]&&tags[f[1:0]]==f))begin missing_frames<=missing_frames+1'b1;missing_seen<=1;end
  end
 endtask
 always @(posedge pixel_clk or posedge rst)begin
  if(rst)begin
   session_sync<=0;session_ack<=0;base_meta<=0;base_sync<=0;valid_meta<=0;valid_sync<=0;enabled_sync<=0;
   missing_seen<=0;playing<=0;played_frame<=0;played_gray<=0;ready_d<=0;block_valid<=0;repeat_half<=0;sample_index<=0;
   timer<=0;odd_half<=0;read_bank<=0;audio_valid<=0;audio_data<=0;play_crc<=0;play_expected<=0;good_blocks<=0;bad_blocks<=0;missing_frames<=0;
  end else begin
   session_sync<={session_sync[1:0],session_toggle};base_meta<=base_frame;base_sync<=base_meta;
   valid_meta<=valid_bits;valid_sync<=valid_meta;enabled_sync<={enabled_sync[0],audio_enabled};
   played_gray<=played_frame^(played_frame>>1);read_bank<=read_addr[9];ready_d<=video_ready;audio_valid<=0;
   if(timer!=0)timer<=timer-1'b1;
   else begin
    timer<=odd_half?HALF_BASE-1:HALF_BASE;odd_half<=~odd_half;audio_valid<=1;
    audio_data<=(playing&&block_valid&&sample_index<SAMPLES)?{sample_byte^8'h80,16'd0}:24'd0;
    if(playing&&sample_index<SAMPLES)begin
     repeat_half<=~repeat_half;
     if(repeat_half)begin
      sample_index<=sample_index+1'b1;
      if(block_valid)begin
       play_crc<=next_play_crc;
       if(sample_index==SAMPLES-1)begin
        if(next_play_crc==play_expected)good_blocks<=good_blocks+1'b1;else bad_blocks<=bad_blocks+1'b1;
       end
      end
     end
    end
   end
   if(session_sync[2]!=session_ack)begin missing_seen<=0;session_ack<=session_sync[2];playing<=0;ready_d<=0;played_frame<=base_sync;block_valid<=0;end
   else if(!video_ready)begin playing<=0;block_valid<=0;end
   else if(!ready_d)begin playing<=1;start_block(base_sync);end
   else if(frame_start&&playing)start_block(next_frame);
  end
 end
 reg [15:0] gg,bg,mg,g1,g2,b1,b2,m1,m2;
 always @(posedge pixel_clk or posedge rst)if(rst)begin gg<=0;bg<=0;mg<=0;end else begin gg<=good_blocks^(good_blocks>>1);bg<=bad_blocks^(bad_blocks>>1);mg<=missing_frames^(missing_frames>>1);end
 always @(posedge app_clk or posedge rst)begin
  if(rst)begin g1<=0;g2<=0;b1<=0;b2<=0;m1<=0;m2<=0;audio_stats<=0;end
  else begin
   g1<=gg;g2<=g1;b1<=bg;b2<=b1;m1<=mg;m2<=m1;
   audio_stats<={duplicates,ungray(b2),ungray(m2),ungray(g2),bad_packets,accepted};
  end
 end
endmodule
