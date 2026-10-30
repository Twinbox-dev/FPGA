`timescale 1ns/1ps
// RGB565 row-stream pipeline: bounded ingress -> optional SDRAM spill ->
// small BRAM head -> HDMI. There is no per-frame SDRAM commit/scan engine.
module video_hybrid_pipeline #(
 parameter WIDTH=640,HEIGHT=360,WINDOW=512,LW=$clog2(WINDOW),HEAD_ROWS=8,
 parameter PRIME_ROWS=HEIGHT,INGRESS_PAGES=4,IDLE_TIMEOUT=100000000
)(
 input wire app_clk,mem_clk,pixel_clk,rst,memory_enable,
 input wire sdr_init_done,sdr_busy,sdr_refresh,input wire [20:0] scratch_base,
 input wire row_begin,row_start,pixel_write,row_commit,row_reject,
 input wire [15:0] row_frame,row_sequence,pixel_data,crc_seed,crc_expected,
 input wire [8:0] row_index,input wire [9:0] pixel_index,
 output wire video_missing,output wire memory_active,memory_idle,
 output wire source_ready,output reg [15:0] credit_sequence,output reg credit_event,
 output wire session_live,output reg ready_event,output reg [15:0] ready_sequence,ready_frame,
 output wire [7:0] free_rows,output wire [31:0] accepted_rows,rejected_rows,duplicate_rows,
 output reg [95:0] hybrid_stats,output reg [95:0] readback_stats,output reg nack_event,output reg [15:0] nack_sequence,
 input wire frame_start,line_start,line_done,word_pop,input wire [9:0] video_y,
 output wire [31:0] word_data,output wire word_valid,line_available,video_ready,output wire [31:0] underflows,
 output wire app_wr_en,output wire [20:0] app_wr_addr,output wire [31:0] app_wr_data,
 output wire app_rd_en,output wire [20:0] app_rd_addr,input wire sdr_rd_en,input wire [31:0] sdr_rd_data
);
 localparam [15:0] WORDS_U16=WIDTH/2;
 localparam WORDS=WIDTH/2,STRIDE=512,GROUPS=(WINDOW+63)/64;
 localparam QUIET=0,IDLE=1,DESC=2,SESSION=3,Q0=4,Q1=5,Q2=6,FAST_INIT=7,FAST_COPY=8,FAST_DRAIN=9,FAST_CHECK=10,
 W_PREP=11,W_REQ=12,W_WAIT=13,R_PREP=18,R_REQ=19,R_WAIT=20,CRC_CHECK=21,POST=22,HALT=23;
 localparam P_INGRESS=0,P_PREFETCH=1,P_PRIME=2;
 reg [4:0] state;reg [1:0] purpose;reg [9:0] quiet_count;
 wire desc_valid,desc_start,ing_data_valid;wire [15:0] desc_frame,desc_seq,desc_seed,desc_crc;
 wire [8:0] desc_row;wire [31:0] ing_data;wire [31:0] ingress_good,ingress_bad;
 reg desc_pop;wire ing_read;wire [8:0] ing_index;
 video_row_ingress #(.WIDTH(WIDTH),.PAGES(INGRESS_PAGES)) ingress(
 .app_clk(app_clk),.app_rst(rst),.row_begin(row_begin),.row_start(row_start),.pixel_write(pixel_write),.row_commit(row_commit),.row_reject(row_reject),
 .row_frame(row_frame),.row_sequence(row_sequence),.pixel_data(pixel_data),.crc_seed(crc_seed),.crc_expected(crc_expected),.row_index(row_index),.pixel_index(pixel_index),
 .source_ready(source_ready),.accepted(ingress_good),.rejected(ingress_bad),.mem_clk(mem_clk),.mem_rst(rst),.desc_pop(desc_pop),.data_read(ing_read),.data_index(ing_index),
 .desc_valid(desc_valid),.desc_frame(desc_frame),.desc_sequence(desc_seq),.desc_seed(desc_seed),.desc_crc(desc_crc),.desc_row(desc_row),.desc_start(desc_start),.data_out(ing_data),.data_valid(ing_data_valid));
 reg [15:0] job_seq,job_frame,job_seed,job_crc;reg [8:0] job_row;reg job_start;
 reg ready_toggle;reg [15:0] ready_seq_mem,ready_frame_mem;reg [16:0] prime_retry_timer;
 reg active,primed;reg [15:0] session_frame,session_base,epoch,prefetch_seq,last_consumed,highest;
 reg have_highest,head_session;wire [15:0] head_consumed;wire head_write_ready;
 reg head_we,head_publish,head_publish_good;reg [8:0] head_index;reg [31:0] head_data;reg [15:0] head_pub_seq;
 wire video_missing_pixel;reg [1:0] missing_app_sync;assign video_missing=missing_app_sync[1];
 wire [31:0] head_good,head_bad;wire [15:0] read_good,read_bad;wire [47:0] read_last_bad;
 video_head_cache #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.DEPTH(HEAD_ROWS),.B32_GROUPS(1),.READ_CRC_ENABLE(1)) head(
 .mem_clk(mem_clk),.mem_rst(rst),.session_start(head_session),.stream_enable(active),.primed(primed),.session_base(session_base),
 .write_sequence(prefetch_seq),.publish_sequence(head_pub_seq),.write_en(head_we),.write_index(head_index),.write_data(head_data),.publish(head_publish),.publish_good(head_publish_good),.publish_crc_seed(job_seed),.publish_crc_expected(job_crc),
 .write_ready(head_write_ready),.consumed_mem(head_consumed),.credit_event(),.accepted(head_good),.rejected(head_bad),
 .pixel_clk(pixel_clk),.pixel_rst(rst),.frame_start(frame_start),.line_start(line_start),.line_done(line_done),.word_pop(word_pop),.video_y(video_y),
 .word_data(word_data),.word_valid(word_valid),.line_available(line_available),.video_ready(video_ready),.underflows(underflows),.missing_seen(video_missing_pixel),.read_crc_good(read_good),.read_crc_bad(read_bad),.read_crc_last_bad(read_last_bad));
 assign memory_active=active;
 assign memory_idle=(state==IDLE)||(state==QUIET);
 reg [LW:0] occupancy; // unique startup rows only; frozen after priming
 reg meta_reset,mark_valid,mark_invalid;reg [15:0] mark_seq,invalid_seq;
 // Queries and publication are serialized through Q0/Q1 and POST.
 // Reuse the complete tag register until publication; no tag fields are narrowed.
 reg [31:0] consumed_high;reg [63:0] job_tag;wire [63:0] mark_tag=job_tag;
 reg [15:0] query_sequence;reg [14:0] query_epoch;
 reg [31:0] query_reference_high;reg query_wrap;
 wire consume_event=active && state!=SESSION && state!=DESC && head_consumed!=last_consumed;
 wire [8:0] tag_write_address=(state==SESSION)?quiet_count[8:0]:(mark_valid?mark_seq[LW-1:0]:invalid_seq[LW-1:0]);
 wire [95:0] tag_write_data=(state==SESSION||!mark_valid)?96'd0:{job_seed,job_crc,mark_tag};
 wire [95:0] tag_read_data;reg [LW-1:0] query_slot;
 video_row_tags #(.WIDTH(96)) tags(.clk(mem_clk),.write_en(state==SESSION||mark_valid||mark_invalid),.read_en(state==Q0),
  .write_address(tag_write_address),.read_address(query_slot),.write_tag(tag_write_data),.read_tag(tag_read_data));
 always @(posedge mem_clk or posedge rst)begin
  if(rst)occupancy<=0;
  else if(meta_reset)occupancy<=0;
  else if(!primed)case({mark_valid,mark_invalid})
   2'b10:occupancy<=occupancy+1'b1;
   2'b01:if(occupancy!=0)occupancy<=occupancy-1'b1;
   default:;
  endcase
 end
 // Advisory free count is a held mailbox, not an asynchronous binary bus.
 // Actual producer permission remains the absolute consumed sequence/window.
 reg [7:0] advice_timer,advice_data;reg advice_toggle;
 wire [15:0] highest_distance=highest-head_consumed;
 wire [15:0] available_estimate=(!have_highest||highest_distance[15])?WINDOW:
   ((highest_distance>=WINDOW)?16'd0:(WINDOW-highest_distance-1'b1));
 always @(posedge mem_clk or posedge rst)begin
  if(rst)begin advice_timer<=0;advice_data<=255;advice_toggle<=0;end
  else begin
   advice_timer<=advice_timer+1'b1;
   if(advice_timer==255)begin advice_data<=available_estimate>255?8'd255:available_estimate[7:0];advice_toggle<=~advice_toggle;end
  end
 end

 reg [20:0] queue_base,port_address;reg [8:0] port_length,offset,chunk_length,issued,received;

 reg [15:0] crc_state;reg [2:0] drain_count;reg [31:0] idle_age;
 reg last_prefetch;reg [8:0] scan_index;reg query_value;
 wire [15:0] next_scan_sequence=session_base+scan_index+1'b1;
 wire [15:0] job_age=job_seq-head_consumed,prefetch_age=prefetch_seq-head_consumed,highest_ahead=highest-prefetch_seq;
 wire [15:0] initial_head_span=prefetch_seq-session_base;
 wire new_session=!active || (job_start&&job_frame!=session_frame);
 wire [20:0] row_address=queue_base+(job_seq[LW-1:0]*STRIDE);
 // Production scratch banks are 512-word aligned. With the duplicate header
 // removed, payload chunks start at column 0/64/128/192 and never straddle it.
 wire [20:0] payload_address={row_address[20:9],offset};
 wire [9:0] remaining=WORDS-offset;
 wire [8:0] limit64=(remaining<64)?remaining:9'd64;
 wire [8:0] next_chunk=(WORDS%64==0)?9'd64:limit64;
 // All production widths here are divisible by eight, so each chunk and the
 // four-word header obey the SDK controller's natural four-word grouping.
 function [15:0] crc_byte(input [15:0] old,input [7:0] data);
  reg [15:0] x;integer i;begin x=old^{data,8'd0};for(i=0;i<8;i=i+1)x=x[15]?(x<<1)^16'h1021:x<<1;crc_byte=x;end
 endfunction
 function [15:0] crc_word(input [15:0] old,input [31:0] data);
  reg [15:0] x;integer i;begin x=old;for(i=0;i<4;i=i+1)x=crc_byte(x,data[i*8+:8]);crc_word=x;end
 endfunction
 wire [31:0] crc_input_word=(state==FAST_COPY)?ing_data:p_rd_data;
 wire [15:0] crc_next_word=crc_word(crc_state,crc_input_word);
 // Two-word skid queue covers the synchronous ingress RAM read pipeline.
 reg [31:0] skid[0:1];reg skid_wp,skid_rp;reg [1:0] skid_count,outstanding;
 wire p_req_ready,p_wr_ready,p_rd_valid,p_done,p_error;wire [31:0] p_rd_data;
 wire p_req=state==W_REQ||state==R_REQ;
 wire p_write=state==W_REQ;
 wire p_wr_valid=state==W_WAIT&&skid_count!=0;
 wire [31:0] p_wr_data=skid[skid_rp];
 wire skid_pop=state==W_WAIT && skid_count!=0 && p_wr_ready;
 wire skid_push=state==W_WAIT && ing_data_valid;
 wire [2:0] reserved_words={1'b0,skid_count}+{1'b0,outstanding};
 assign ing_read=(state==FAST_COPY&&issued<WORDS) ||
                 (state==W_WAIT&&issued<chunk_length&&(reserved_words<2||skid_pop));
 assign ing_index=(state==FAST_COPY)?issued:(offset+issued);
 video_sdram_port port(.clk(mem_clk),.rst(rst),.init_done(sdr_init_done&&memory_enable),.sdr_busy(sdr_busy),.sdr_refresh(sdr_refresh),.gate_each_beat(1'b0),
 .req_valid(p_req),.req_write(p_write),.req_addr(port_address),.req_len(port_length),.req_ready(p_req_ready),
 .wr_valid(p_wr_valid),.wr_data(p_wr_data),.wr_ready(p_wr_ready),.rd_valid(p_rd_valid),.rd_data(p_rd_data),.done(p_done),.error(p_error),
 .app_wr_en(app_wr_en),.app_wr_addr(app_wr_addr),.app_wr_data(app_wr_data),.app_rd_en(app_rd_en),.app_rd_addr(app_rd_addr),.sdr_rd_en(sdr_rd_en),.sdr_rd_data(sdr_rd_data),
 .max_write_cycles(),.max_read_cycles());
 reg [15:0] spills,prefetches,fasts,crc_bad,tag_bad,port_fault,committed,dropped,duplicates;
 reg nack_toggle;reg [15:0] nack_seq_mem;
 reg [15:0] gray_consumed;
 reg [95:0] gray_stats;reg [15:0] gray_committed,gray_dropped,gray_duplicates;
 function [15:0] ungray16(input [15:0] g);integer i;begin ungray16[15]=g[15];for(i=14;i>=0;i=i-1)ungray16[i]=ungray16[i+1]^g[i];end endfunction
  always @(posedge mem_clk or posedge rst)begin
  if(rst)begin
   ready_toggle<=0;ready_seq_mem<=0;ready_frame_mem<=0;prime_retry_timer<=0;
   state<=QUIET;quiet_count<=512;active<=0;primed<=0;session_frame<=0;session_base<=0;epoch<=0;prefetch_seq<=0;last_consumed<=0;highest<=0;have_highest<=0;
   head_session<=0;head_we<=0;head_publish<=0;head_publish_good<=0;head_index<=0;head_data<=0;head_pub_seq<=0;
   desc_pop<=0;meta_reset<=0;mark_valid<=0;mark_invalid<=0;mark_seq<=0;invalid_seq<=0;
   job_seq<=0;job_frame<=0;job_seed<=0;job_crc<=0;job_row<=0;job_start<=0;queue_base<=0;
   port_address<=0;port_length<=0;offset<=0;chunk_length<=0;issued<=0;received<=0;
   crc_state<=0;drain_count<=0;idle_age<=0;
   last_prefetch<=0;scan_index<=0;query_slot<=0;query_sequence<=0;query_epoch<=0;query_reference_high<=0;query_wrap<=0;query_value<=0;purpose<=0;
   skid_wp<=0;skid_rp<=0;skid_count<=0;outstanding<=0;
   spills<=0;prefetches<=0;fasts<=0;crc_bad<=0;tag_bad<=0;port_fault<=0;committed<=0;dropped<=0;duplicates<=0;nack_toggle<=0;nack_seq_mem<=0;
   consumed_high<=0;job_tag<=0;gray_consumed<=0;gray_stats<=0;gray_committed<=0;gray_dropped<=0;gray_duplicates<=0;
  end else begin
   desc_pop<=0;head_session<=0;head_we<=0;head_publish<=0;meta_reset<=0;mark_valid<=0;mark_invalid<=0;
   gray_consumed<=head_consumed^(head_consumed>>1);
   gray_stats<={port_fault^(port_fault>>1),tag_bad^(tag_bad>>1),crc_bad^(crc_bad>>1),fasts^(fasts>>1),prefetches^(prefetches>>1),spills^(spills>>1)};
   gray_committed<=committed^(committed>>1);gray_dropped<=dropped^(dropped>>1);gray_duplicates<=duplicates^(duplicates>>1);
   if(consume_event)begin last_consumed<=head_consumed;if(head_consumed<last_consumed)consumed_high<=consumed_high+1'b1;end
   if(active)idle_age<=idle_age+1'b1;
   if(!active||primed)prime_retry_timer<=0;else if(prime_retry_timer<99999)prime_retry_timer<=prime_retry_timer+1'b1;
   if(active&&idle_age>=IDLE_TIMEOUT && state==IDLE)begin active<=0;primed<=0;meta_reset<=1;end
   if(state==W_WAIT)begin
    if(ing_read)issued<=issued+1'b1;
    if(skid_push)begin skid[skid_wp]<=ing_data;skid_wp<=!skid_wp;end
    if(skid_pop)skid_rp<=!skid_rp;
    case({skid_push,skid_pop})2'b10:skid_count<=skid_count+1'b1;2'b01:skid_count<=skid_count-1'b1;default:;endcase
    case({ing_read,ing_data_valid})2'b10:outstanding<=outstanding+1'b1;2'b01:outstanding<=outstanding-1'b1;default:;endcase
   end
   case(state)
    QUIET:if(quiet_count!=0)quiet_count<=quiet_count-1'b1;else if(sdr_init_done&&memory_enable)state<=IDLE;
    IDLE:begin
     if(active&&!primed&&(occupancy>=PRIME_ROWS||prime_retry_timer==99999)&&!desc_valid)begin
      scan_index<=0;query_slot<=session_base[LW-1:0];query_sequence<=session_base;query_epoch<=epoch[14:0];query_reference_high<=consumed_high;query_wrap<=session_base<last_consumed;purpose<=P_PRIME;state<=Q0;
     end else if(active&&head_write_ready && prefetch_age<HEAD_ROWS && (!desc_valid||!last_prefetch))begin
      job_seq<=prefetch_seq;query_slot<=prefetch_seq[LW-1:0];query_sequence<=prefetch_seq;query_epoch<=epoch[14:0];query_reference_high<=consumed_high;query_wrap<=prefetch_seq<last_consumed;purpose<=P_PREFETCH;state<=Q0;
     end else if(desc_valid)begin
      job_seq<=desc_seq;job_frame<=desc_frame;job_seed<=desc_seed;job_crc<=desc_crc;job_row<=desc_row;job_start<=desc_start;
      idle_age<=0;state<=DESC;
     end else if(active&&prefetch_age[15])prefetch_seq<=head_consumed;
    end
    DESC:begin
     // Repeated row zero reissues READY if its first feedback was lost.
     if(active&&job_start&&job_frame==session_frame&&job_seq==session_base)begin ready_toggle<=~ready_toggle;ready_seq_mem<=session_base;ready_frame_mem<=session_frame;end
     if(new_session)begin
      if(job_row!=0)begin dropped<=dropped+1'b1;desc_pop<=1;state<=POST;end
      else if(memory_enable)begin
       session_frame<=job_frame;session_base<=job_seq;epoch<=epoch+1'b1;prefetch_seq<=job_seq;last_consumed<=job_seq;queue_base<=scratch_base;
       active<=1;primed<=0;head_session<=1;meta_reset<=1;have_highest<=0;consumed_high<=0;quiet_count<=WINDOW-1;state<=SESSION;
      end
     end else if(job_age>=WINDOW)begin dropped<=dropped+1'b1;desc_pop<=1;state<=POST;end
     else begin query_slot<=job_seq[LW-1:0];query_sequence<=job_seq;query_epoch<=epoch[14:0];query_reference_high<=consumed_high;query_wrap<=job_seq<last_consumed;purpose<=P_INGRESS;state<=Q0;end
    end
    SESSION:if(quiet_count!=0)quiet_count<=quiet_count-1'b1;else begin
     ready_toggle<=~ready_toggle;ready_seq_mem<=session_base;ready_frame_mem<=session_frame;job_tag<={1'b1,epoch[14:0],32'd0,job_seq};state<=FAST_INIT;end
    Q0:begin
     // Reference high/low parts were captured together before this stage.
     // Split the wrap comparator from the high-word increment and tag compare.
     job_tag<={1'b1,query_epoch,(query_reference_high+{31'd0,query_wrap}),query_sequence};state<=Q1;
    end
    Q1:begin
     query_value<=tag_read_data[63:0]==job_tag;
     if(purpose==P_PREFETCH)begin job_seed<=tag_read_data[95:80];job_crc<=tag_read_data[79:64];end
     
     state<=Q2;
    end
    Q2:case(purpose)
     P_PRIME:begin
      if(!query_value)begin
       if(prime_retry_timer==99999)begin nack_seq_mem<=query_sequence;nack_toggle<=~nack_toggle;prime_retry_timer<=0;end
       last_prefetch<=1;state<=IDLE;end
      else if(scan_index==PRIME_ROWS-1)begin if(initial_head_span>=HEAD_ROWS)primed<=1;prime_retry_timer<=0;state<=IDLE;end
      else begin scan_index<=scan_index+1'b1;query_slot<=next_scan_sequence[LW-1:0];query_sequence<=next_scan_sequence;query_epoch<=epoch[14:0];query_reference_high<=consumed_high;query_wrap<=next_scan_sequence<last_consumed;state<=Q0;end
     end
     P_INGRESS:begin
      if(job_age>=WINDOW)begin dropped<=dropped+1'b1;desc_pop<=1;state<=POST;end
      else if(query_value)begin duplicates<=duplicates+1'b1;dropped<=dropped+1'b1;desc_pop<=1;state<=POST;end
      else if(job_seq==prefetch_seq && head_write_ready)state<=FAST_INIT;
      else begin offset<=0;last_prefetch<=0;state<=W_PREP;end
     end
     default:begin
      last_prefetch<=1;
      if(prefetch_age[15])begin prefetch_seq<=head_consumed;state<=IDLE;end
      else if(prefetch_age>=HEAD_ROWS||!head_write_ready)state<=IDLE;
      else if(query_value)begin crc_state<=job_seed;offset<=0;state<=R_PREP;end
      else begin
       if(primed&&have_highest&&highest_ahead!=0&&!highest_ahead[15])prefetch_seq<=prefetch_seq+1'b1;
       state<=IDLE;
      end
     end
    endcase
    FAST_INIT:if(head_write_ready)begin crc_state<=job_seed;issued<=0;received<=0;state<=FAST_COPY;end
    FAST_COPY:begin
     if(ing_read)issued<=issued+1'b1;
     if(ing_data_valid)begin
      head_we<=1;head_index<=received;head_data<=ing_data;crc_state<=crc_next_word;received<=received+1'b1;
      if(received==WORDS-1)begin drain_count<=3;state<=FAST_DRAIN;end
     end
    end
    FAST_DRAIN:if(drain_count!=0)drain_count<=drain_count-1'b1;else state<=FAST_CHECK;
    FAST_CHECK:begin
     head_publish<=1;head_pub_seq<=job_seq;head_publish_good<=crc_state==job_crc&&job_age<HEAD_ROWS;
     if(crc_state==job_crc&&job_age<HEAD_ROWS)begin
      fasts<=fasts+1'b1;committed<=committed+1'b1;mark_valid<=1;mark_seq<=job_seq;prefetch_seq<=prefetch_seq+1'b1;
      if(!have_highest || ((job_seq-highest)!=0 && !((job_seq-highest)&16'h8000)))begin highest<=job_seq;have_highest<=1;end
     end else begin
      crc_bad<=crc_bad+1'b1;dropped<=dropped+1'b1;nack_seq_mem<=job_seq;nack_toggle<=~nack_toggle;
      if(primed)prefetch_seq<=prefetch_seq+1'b1;
     end
     desc_pop<=1;last_prefetch<=0;state<=POST;
    end
    W_PREP:begin port_address<=payload_address;port_length<=next_chunk;chunk_length<=next_chunk;state<=W_REQ;end
    W_REQ:if(p_req_ready)begin issued<=0;skid_count<=0;outstanding<=0;skid_wp<=0;skid_rp<=0;state<=W_WAIT;end
    W_WAIT:if(p_done)begin
     if(p_error)begin port_fault<=port_fault+1'b1;dropped<=dropped+1'b1;active<=0;primed<=0;meta_reset<=1;state<=HALT;end
     else if(offset+chunk_length==WORDS)begin
      // Publish metadata only after the final payload write has drained.
      // The RAM table holds seed/CRC as well as the full session/row identity;
      // duplicating another four-word header in SDRAM served no extra reader.
      if(job_age>=WINDOW)begin dropped<=dropped+1'b1;desc_pop<=1;state<=POST;end
      else begin
       spills<=spills+1'b1;committed<=committed+1'b1;mark_valid<=1;mark_seq<=job_seq;
       if(!have_highest || ((job_seq-highest)!=0 && !((job_seq-highest)&16'h8000)))begin highest<=job_seq;have_highest<=1;end
       desc_pop<=1;last_prefetch<=0;state<=POST;
      end
     end else begin offset<=offset+chunk_length;state<=W_PREP;end
    end
    R_PREP:begin port_address<=payload_address;port_length<=next_chunk;chunk_length<=next_chunk;state<=R_REQ;end
    R_REQ:if(p_req_ready)begin received<=0;state<=R_WAIT;end
    R_WAIT:begin
     if(p_rd_valid)begin
      head_we<=1;head_index<=offset+received;head_data<=p_rd_data;crc_state<=crc_next_word;received<=received+1'b1;
     end
     if(p_done)begin
      if(p_error)begin port_fault<=port_fault+1'b1;dropped<=dropped+1'b1;active<=0;primed<=0;meta_reset<=1;state<=HALT;end
      else if(offset+chunk_length==WORDS)state<=CRC_CHECK;
      else begin offset<=offset+chunk_length;state<=R_PREP;end
     end
    end
    CRC_CHECK:begin
     head_publish<=1;head_pub_seq<=job_seq;head_publish_good<=crc_state==job_crc&&job_age<HEAD_ROWS;
     if(crc_state==job_crc&&job_age<HEAD_ROWS)begin prefetches<=prefetches+1'b1;prefetch_seq<=prefetch_seq+1'b1;end
     else begin
      crc_bad<=crc_bad+1'b1;dropped<=dropped+1'b1;mark_invalid<=1;invalid_seq<=job_seq;nack_seq_mem<=job_seq;nack_toggle<=~nack_toggle;
      if(primed)prefetch_seq<=prefetch_seq+1'b1;
     end
     state<=POST;
    end
    POST:state<=IDLE;
    default:state<=state;
   endcase
  end
 end
 reg [15:0] cg1,cg2,gg1,gg2,bg1,bg2,dg1,dg2;reg [2:0] advice_sync;reg advice_seen;reg [7:0] ad1,ad2,free_q;reg [95:0] sg1,sg2;
 reg [15:0] rg1,rg2,rb1,rb2;reg [47:0] rbad1,rbad2;
 reg [15:0] rg_src,rb_src;
 always @(posedge pixel_clk or posedge rst)if(rst)begin rg_src<=0;rb_src<=0;end else begin rg_src<=read_good^(read_good>>1);rb_src<=read_bad^(read_bad>>1);end
 reg [1:0] active_app_sync;assign session_live=active_app_sync[1];
 reg [2:0] ready_sync;reg ready_seen;reg [31:0] ready_meta,ready_data;
 reg [2:0] nsync;reg nseen;reg [15:0] nq1,nq2;
 assign free_rows=free_q;
 assign accepted_rows={16'd0,ungray16(gg2)};
 assign rejected_rows={16'd0,ungray16(bg2)}+ingress_bad;
 assign duplicate_rows={16'd0,ungray16(dg2)};
 integer f;
 always @(posedge app_clk or posedge rst)begin
  if(rst)begin cg1<=0;cg2<=0;gg1<=0;gg2<=0;bg1<=0;bg2<=0;dg1<=0;dg2<=0;advice_sync<=0;advice_seen<=0;ad1<=255;ad2<=255;free_q<=255;sg1<=0;sg2<=0;
   rg1<=0;rg2<=0;rb1<=0;rb2<=0;rbad1<=0;rbad2<=0;readback_stats<=0;
   missing_app_sync<=0;active_app_sync<=0;ready_sync<=0;ready_seen<=0;ready_meta<=0;ready_data<=0;ready_event<=0;ready_sequence<=0;ready_frame<=0;
   credit_sequence<=0;credit_event<=0;hybrid_stats<=0;nsync<=0;nseen<=0;nq1<=0;nq2<=0;nack_event<=0;nack_sequence<=0;
  end else begin
   missing_app_sync<={missing_app_sync[0],video_missing_pixel};active_app_sync<={active_app_sync[0],active};ready_sync<={ready_sync[1:0],ready_toggle};ready_meta<={ready_frame_mem,ready_seq_mem};ready_data<=ready_meta;ready_event<=0;
   if(ready_sync[2]!=ready_seen)begin ready_seen<=ready_sync[2];ready_sequence<=ready_data[15:0];ready_frame<=ready_data[31:16];ready_event<=1;end
   rg1<=rg_src;rg2<=rg1;rb1<=rb_src;rb2<=rb1;rbad1<=read_last_bad;rbad2<=rbad1;
   readback_stats<={16'd0,rbad2,ungray16(rb2),ungray16(rg2)};
   cg1<=gray_consumed;cg2<=cg1;gg1<=gray_committed;gg2<=gg1;bg1<=gray_dropped;bg2<=bg1;dg1<=gray_duplicates;dg2<=dg1;
   advice_sync<={advice_sync[1:0],advice_toggle};ad1<=advice_data;ad2<=ad1;
   if(advice_sync[2]!=advice_seen)begin advice_seen<=advice_sync[2];free_q<=ad2;end
   sg1<=gray_stats;sg2<=sg1;
   credit_event<=credit_sequence!=ungray16(cg2);credit_sequence<=ungray16(cg2);
   for(f=0;f<6;f=f+1)hybrid_stats[f*16+:16]<=ungray16(sg2[f*16+:16]);
   nsync<={nsync[1:0],nack_toggle};nq1<=nack_seq_mem;nq2<=nq1;nack_event<=0;
   if(nsync[2]!=nseen)begin nseen<=nsync[2];nack_sequence<=nq2;nack_event<=1;end
  end
 end
`ifdef VERILATOR
 initial begin
  if((WINDOW&(WINDOW-1))!=0||WINDOW>512||WINDOW<HEIGHT||WIDTH%8!=0||WORDS+4>STRIDE)$fatal(1,"hybrid configuration invalid");
 end
 always @(posedge mem_clk)if(!rst)begin
  if(state==DESC&&new_session&&scratch_base[8:0]!=0)$fatal(1,"video scratch requires 512-word alignment");
  if(occupancy>WINDOW)$fatal(1,"hybrid occupancy overflow %0d",occupancy);
  if(state==W_WAIT&&p_done&&(skid_count!=0||outstanding!=0))$fatal(1,"write chunk finished with reserved ingress words");
  if(consume_event&&(head_consumed-last_consumed)!=16'd1)$fatal(1,"hybrid consumer pointer skipped");
 end
`endif
endmodule
