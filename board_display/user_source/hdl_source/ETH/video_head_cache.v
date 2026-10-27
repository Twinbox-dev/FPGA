`timescale 1ns/1ps
// Small deterministic BRAM scanout queue. Only completed rows become visible.
// Paired native 16-bit RAMs accept one 32-bit SDRAM return each memory clock.
module video_head_cache #(
 parameter WIDTH=720,HEIGHT=360,DEPTH=8,LGDEPTH=$clog2(DEPTH),B32_GROUPS=1,READ_CRC_ENABLE=0,
 parameter [15:0] MISSING_RGB565=16'hf800
)(
 input wire mem_clk,mem_rst,session_start,stream_enable,primed,
 input wire [15:0] session_base,write_sequence,publish_sequence,
 input wire write_en,input wire [8:0] write_index,input wire [31:0] write_data,
 input wire publish,publish_good,input wire [15:0] publish_crc_seed,publish_crc_expected,output wire write_ready,output reg [15:0] consumed_mem,
 output reg credit_event,output reg [31:0] accepted,rejected,
 input wire pixel_clk,pixel_rst,frame_start,line_start,line_done,word_pop,
 input wire [9:0] video_y,output wire [31:0] word_data,output wire word_valid,line_available,
 output wire video_ready,output reg [31:0] underflows,
 output reg missing_seen,output reg [15:0] read_crc_good,read_crc_bad,output reg [47:0] read_crc_last_bad
);
 // Four 720-pixel rows already occupy a 2048-word native allocation.
 // Use its spare words as row padding: 512-word strides remove both address
 // multipliers/adders without adding RAM. Keep other profiles packed.
 localparam WORDS=WIDTH/2;
 localparam ROW_STRIDE=(DEPTH==4)?(1<<$clog2(WORDS)):WORDS;
 localparam TOTAL_WORDS=DEPTH*ROW_STRIDE;
 localparam AW=($clog2(TOTAL_WORDS)<11)?11:$clog2(TOTAL_WORDS);
 localparam B32=(B32_GROUPS<(TOTAL_WORDS+2047)/2048)?B32_GROUPS:(TOTAL_WORDS+2047)/2048;
 localparam BASE9=B32*2048,B9=(TOTAL_WORDS>BASE9)?((TOTAL_WORDS-BASE9+511)/512):0;
 localparam N32=B32?B32:1,N9=B9?B9:1;
 reg active,toggle;reg [15:0] base_mem,last_consumed;
 reg [15:0] crc_seeds[0:DEPTH-1],crc_expected_table[0:DEPTH-1];
 reg [DEPTH-1:0] valid_bits;reg [2:0] ack_sync;
 reg [15:0] consumed_gray_meta,consumed_gray_sync;reg [15:0] consumed_pixel,consumed_gray;
 reg ack;reg [2:0] toggle_sync,active_sync;reg [1:0] primed_sync;
 reg [15:0] base_meta,base_sync,frame_base,line_sequence;
 reg [DEPTH-1:0] valid_meta,valid_sync;
 reg armed,line_valid,have_word;reg [8:0] read_word_index;
 wire [LGDEPTH-1:0] wslot=write_sequence[LGDEPTH-1:0],pslot=publish_sequence[LGDEPTH-1:0];
 wire [15:0] wd=write_sequence-consumed_mem,pd=publish_sequence-consumed_mem;
 wire head_release=active && ack_sync[2]==toggle && consumed_mem!=last_consumed;
 wire [LGDEPTH-1:0] release_slot=last_consumed[LGDEPTH-1:0];
 assign write_ready=active && ack_sync[2]==toggle && wd<DEPTH &&
                    (!valid_bits[wslot] || (head_release && release_slot==wslot));
 reg write_q;reg [AW-1:0] wa_q;reg [31:0] data_q;
 wire [AW-1:0] read_address=line_sequence[LGDEPTH-1:0]*ROW_STRIDE+read_word_index;
 wire read_en=word_pop&&line_valid&&read_word_index<WORDS;
 wire read32=read_address<BASE9,write32=wa_q<BASE9;
 wire [AW-1:0] ra9=read_address-BASE9,wa9=wa_q-BASE9;
 wire [31:0] q32[0:N32-1],q9[0:N9-1];reg read_is32;reg [5:0] read_bank;
 wire [31:0] selected=read_is32?q32[read_bank]:q9[read_bank];
 assign word_valid=have_word&&line_valid;
 assign word_data=word_valid?selected:(!line_valid?{2{MISSING_RGB565}}:32'd0);
 wire [15:0] expected=frame_base+video_y;
 assign line_available=armed&&active_sync[2]&&video_y<HEIGHT&&valid_sync[expected[LGDEPTH-1:0]];
 assign video_ready=armed&&active_sync[2];
 function [15:0] gray_to_binary(input [15:0] g);
  integer i;begin gray_to_binary[15]=g[15];for(i=14;i>=0;i=i-1)gray_to_binary[i]=gray_to_binary[i+1]^g[i];end
 endfunction
 genvar k;
 generate for(k=0;k<N32;k=k+1)begin:g32
  if(k<B32)begin
   direct_video_bram_32k_16 lo(.wr_clk(mem_clk),.wr_en(write_q&&write32&&(wa_q>>11)==k),.wr_addr(wa_q[10:0]),.wr_data(data_q[15:0]),
      .rd_clk(pixel_clk),.rd_en(read_en&&read32&&(read_address>>11)==k),.rd_addr(read_address[10:0]),.rd_data(q32[k][15:0]));
   direct_video_bram_32k_16 hi(.wr_clk(mem_clk),.wr_en(write_q&&write32&&(wa_q>>11)==k),.wr_addr(wa_q[10:0]),.wr_data(data_q[31:16]),
      .rd_clk(pixel_clk),.rd_en(read_en&&read32&&(read_address>>11)==k),.rd_addr(read_address[10:0]),.rd_data(q32[k][31:16]));
  end else assign q32[k]=0;
 end
 for(k=0;k<N9;k=k+1)begin:g9
  if(k<B9)begin
   direct_video_bram_9k_16 lo(.wr_clk(mem_clk),.wr_en(write_q&&!write32&&(wa9>>9)==k),.wr_addr(wa9[8:0]),.wr_data(data_q[15:0]),
      .rd_clk(pixel_clk),.rd_en(read_en&&!read32&&(ra9>>9)==k),.rd_addr(ra9[8:0]),.rd_data(q9[k][15:0]));
   direct_video_bram_9k_16 hi(.wr_clk(mem_clk),.wr_en(write_q&&!write32&&(wa9>>9)==k),.wr_addr(wa9[8:0]),.wr_data(data_q[31:16]),
      .rd_clk(pixel_clk),.rd_en(read_en&&!read32&&(ra9>>9)==k),.rd_addr(ra9[8:0]),.rd_data(q9[k][31:16]));
  end else assign q9[k]=0;
 end endgenerate
 always @(posedge mem_clk or posedge mem_rst)begin
  if(mem_rst)begin
   active<=0;toggle<=0;base_mem<=0;last_consumed<=0;valid_bits<=0;ack_sync<=0;
   consumed_gray_meta<=0;consumed_gray_sync<=0;consumed_mem<=0;credit_event<=0;accepted<=0;rejected<=0;
   write_q<=0;wa_q<=0;data_q<=0;
  end else begin
   ack_sync<={ack_sync[1:0],ack};consumed_gray_meta<=consumed_gray;consumed_gray_sync<=consumed_gray_meta;
   credit_event<=0;write_q<=write_en&&write_ready&&write_index<WORDS;
   if(write_en&&write_ready)begin wa_q<=wslot*ROW_STRIDE+write_index;data_q<=write_data;end
   if(session_start)begin
    active<=1;toggle<=~toggle;base_mem<=session_base;last_consumed<=session_base;consumed_mem<=session_base;valid_bits<=0;write_q<=0;
   end else if(!stream_enable)begin active<=0;valid_bits<=0;write_q<=0;end
   else begin
    if(ack_sync[2]!=toggle)consumed_mem<=base_mem;
    else consumed_mem<=gray_to_binary(consumed_gray_sync);
    if(head_release)begin valid_bits[release_slot]<=0;last_consumed<=consumed_mem;credit_event<=1;end
    if(publish)begin
     if(publish_good && pd<DEPTH && (!valid_bits[pslot]||(head_release&&release_slot==pslot)))begin
      valid_bits[pslot]<=1;accepted<=accepted+1'b1;
      if(READ_CRC_ENABLE)begin crc_seeds[pslot]<=publish_crc_seed;crc_expected_table[pslot]<=publish_crc_expected;end
     end else rejected<=rejected+1'b1;
    end
   end
  end
 end
 always @(posedge pixel_clk or posedge pixel_rst)begin
  if(pixel_rst)begin
   ack<=0;toggle_sync<=0;active_sync<=0;primed_sync<=0;base_meta<=0;base_sync<=0;valid_meta<=0;valid_sync<=0;
   consumed_pixel<=0;consumed_gray<=0;frame_base<=0;line_sequence<=0;armed<=0;line_valid<=0;have_word<=0;
   read_word_index<=0;read_is32<=0;read_bank<=0;underflows<=0;missing_seen<=0;
  end else begin
   toggle_sync<={toggle_sync[1:0],toggle};active_sync<={active_sync[1:0],active};primed_sync<={primed_sync[0],primed};
   base_meta<=base_mem;base_sync<=base_meta;valid_meta<=valid_bits;valid_sync<=valid_meta;
   if(toggle_sync[2]!=ack)begin
    missing_seen<=0;ack<=toggle_sync[2];consumed_pixel<=base_sync;consumed_gray<=base_sync^(base_sync>>1);
    frame_base<=base_sync;armed<=0;line_valid<=0;have_word<=0;read_word_index<=0;
   end else if(!active_sync[2])begin armed<=0;line_valid<=0;have_word<=0;end
   else begin
    consumed_gray<=consumed_pixel^(consumed_pixel>>1);
    if(frame_start && (armed || (primed_sync[1]&&valid_sync[base_sync[LGDEPTH-1:0]])))begin
     if(armed)begin frame_base<=frame_base+HEIGHT;consumed_pixel<=frame_base+HEIGHT;end
     else begin frame_base<=base_sync;consumed_pixel<=base_sync;end
     armed<=1;
    end else if(armed && line_done && video_y<HEIGHT)consumed_pixel<=expected+1'b1;
    if(line_start)begin
     line_sequence<=expected;line_valid<=line_available;read_word_index<=0;have_word<=0;
     if(!line_available && video_y<HEIGHT)begin underflows<=underflows+1'b1;if(armed)missing_seen<=1;end
    end else if(read_en)begin
     read_word_index<=read_word_index+1'b1;have_word<=1;read_is32<=read32;read_bank<=read32?(read_address>>11):(ra9>>9);
    end
   end
  end
 end
// Passive readback integrity check: these are the same registered words
 // consumed by video_delay. The seed/expected CRC came from the original row.
 function [15:0] crc_byte(input [15:0] c,input [7:0] d);
  reg [15:0] v;integer j;begin v=c^{d,8'd0};for(j=0;j<8;j=j+1)v=v[15]?(v<<1)^16'h1021:v<<1;crc_byte=v;end
 endfunction
 function [15:0] crc_word(input [15:0] c,input [31:0] d);
  reg [15:0] v;integer j;begin v=c;for(j=0;j<4;j=j+1)v=crc_byte(v,d[j*8+:8]);crc_word=v;end
 endfunction
 reg verify_active,verify_strobe;reg [8:0] verify_index;
 reg [15:0] verify_crc,verify_expected,verify_sequence;
 wire [15:0] verify_next=crc_word(verify_crc,selected);
 always @(posedge pixel_clk or posedge pixel_rst)begin
  if(pixel_rst)begin
   verify_active<=0;verify_strobe<=0;verify_index<=0;verify_crc<=0;verify_expected<=0;verify_sequence<=0;
   read_crc_good<=0;read_crc_bad<=0;read_crc_last_bad<=0;
  end else if(READ_CRC_ENABLE)begin
   verify_strobe<=read_en;if(read_en)verify_index<=read_word_index;
   if(!active_sync[2]||toggle_sync[2]!=ack)begin verify_active<=0;verify_strobe<=0;end
   else if(line_start)begin
    verify_active<=line_available;verify_crc<=crc_seeds[expected[LGDEPTH-1:0]];
    verify_expected<=crc_expected_table[expected[LGDEPTH-1:0]];verify_sequence<=expected;
   end else if(verify_strobe&&verify_active)begin
    verify_crc<=verify_next;
    if(verify_index==WORDS-1)begin
     verify_active<=0;
     if(verify_next==verify_expected)read_crc_good<=read_crc_good+1'b1;
     else begin read_crc_bad<=read_crc_bad+1'b1;read_crc_last_bad<={verify_sequence,verify_expected,verify_next};end
    end
   end
  end
 end
`ifdef VERILATOR
 initial if((DEPTH&(DEPTH-1))!=0 || WIDTH%2!=0)$fatal(1,"head needs power-of-two depth and even width");
 always @(posedge mem_clk)if(!mem_rst && active && ack_sync[2]==toggle && consumed_mem!=last_consumed &&
  (consumed_mem-last_consumed)!=16'd1 && !session_start)$fatal(1,"head consumer skipped a sequence");
`endif
endmodule
