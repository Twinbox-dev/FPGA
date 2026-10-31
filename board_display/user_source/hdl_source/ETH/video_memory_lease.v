`timescale 1ns/1ps
// Exclusive, drain-before-switch lease of the existing SDRAM application port.
// Pixel scanout remains on the small BRAM head. No frame buffer is allocated.
module video_memory_lease #(
 parameter [20:0] AUDIO2=21'd921600,AUDIO3=21'd1509376,
 parameter QUIET_CYCLES=32
)(
 input wire mem_clk,pixel_clk,rst,
 input wire request_async,transaction_busy_async,
 input wire [1:0] audio_buffer_async,
 input wire frame_start,
 input wire old_rd_en,old_wr_en,old_rd_valid,old_rd_busy,old_wr_busy,old_line_busy,
 input wire sdr_busy,sdr_refresh,
 input wire stream_active,stream_idle,
 output wire hold_old,output reg memory_grant,
 output reg [20:0] scratch_base,
 output reg video_mode,
 output reg release_toggle,
 output reg accounting_error
);
 localparam IDLE=0,WAIT_TX=1,WAIT_PIXEL=2,DRAIN=3,ACTIVE=4,RELEASE=5,WAIT_STILL=6,WAIT_CLEAR=7;
 reg [2:0] state;
 reg [1:0] req_sync,tx_sync;
 reg [1:0] audio_meta,audio_sync;
 reg want_video;reg [1:0] want_sync,video_ack;
 reg [12:0] pending_reads;
 reg [5:0] quiet;reg seen_stream;
 reg [26:0] startup_timer;
 assign hold_old=(state==DRAIN)||(state==ACTIVE)||(state==RELEASE);
 wire quiet_now=!old_rd_en&&!old_wr_en&&!old_rd_valid&&!old_rd_busy&&!old_wr_busy&&!old_line_busy&&!sdr_busy&&!sdr_refresh&&pending_reads==0;
 always @(posedge pixel_clk or posedge rst)begin
  if(rst)begin want_sync<=0;video_mode<=0;end
  else begin want_sync<={want_sync[0],want_video};if(frame_start)video_mode<=want_sync[1];end
 end
 always @(posedge mem_clk or posedge rst)begin
  if(rst)begin
   state<=IDLE;req_sync<=0;tx_sync<=0;audio_meta<=0;audio_sync<=0;want_video<=0;video_ack<=0;
   pending_reads<=0;quiet<=0;seen_stream<=0;memory_grant<=0;scratch_base<=AUDIO3;
   release_toggle<=0;accounting_error<=0;startup_timer<=0;
  end else begin
   req_sync<={req_sync[0],request_async};tx_sync<={tx_sync[0],transaction_busy_async};
   audio_meta<=audio_buffer_async;audio_sync<=audio_meta;video_ack<={video_ack[0],video_mode};
   if(!memory_grant)begin
    case({old_rd_en,old_rd_valid})
     2'b10:pending_reads<=pending_reads+1'b1;
     2'b01:if(pending_reads!=0)pending_reads<=pending_reads-1'b1;else accounting_error<=1;
     default:;
    endcase
   end
   case(state)
    IDLE:if(req_sync[1])begin state<=WAIT_TX;quiet<=0;end
    WAIT_TX:if(tx_sync[1])quiet<=0;else if(quiet==QUIET_CYCLES-1)begin want_video<=1;quiet<=0;state<=WAIT_PIXEL;end else quiet<=quiet+1'b1;
    WAIT_PIXEL:if(video_ack[1])begin quiet<=0;state<=DRAIN;end
    DRAIN:if(!quiet_now)quiet<=0;else if(quiet==QUIET_CYCLES-1&&!accounting_error)begin
     // Preserve the current audio bank; only the inactive bank is scratch.
     scratch_base<=audio_sync==3?AUDIO2:AUDIO3;memory_grant<=1;seen_stream<=0;startup_timer<=0;state<=ACTIVE;
    end else quiet<=quiet+1'b1;
    ACTIVE:begin
     if(stream_active)seen_stream<=1;
     if(!seen_stream)startup_timer<=startup_timer+1'b1;
     if((seen_stream&&!stream_active&&stream_idle)||(!seen_stream&&startup_timer==100000000))begin quiet<=0;state<=RELEASE;end
    end
    RELEASE:if(!stream_idle||sdr_busy||sdr_refresh)quiet<=0;else if(quiet==QUIET_CYCLES-1)begin
     memory_grant<=0;want_video<=0;quiet<=0;state<=WAIT_STILL;
    end else quiet<=quiet+1'b1;
    WAIT_STILL:if(!video_ack[1])begin release_toggle<=~release_toggle;state<=WAIT_CLEAR;end
    WAIT_CLEAR:if(!req_sync[1])state<=IDLE;
    default:state<=IDLE;
   endcase
  end
 end
`ifdef VERILATOR
 always @(posedge mem_clk)if(!rst&&memory_grant&&(old_rd_en||old_wr_en))$fatal(1,"old client issued a request during video lease");
 always @(posedge mem_clk)if(!rst&&memory_grant&&pending_reads!=0)$fatal(1,"old responses not drained before grant");
`endif
endmodule
