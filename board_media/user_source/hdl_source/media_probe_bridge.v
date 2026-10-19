`timescale 1ns / 1ps
// ETH mailbox bridge: D reloads, N selects next BMP, P selects previous BMP.
module media_probe_bridge #(parameter DIAG_ENABLE=0) (
 input wire clk, input wire rst, input wire [7:0] cmd, input wire cmd_pending,
 input wire [23:0] media_status,
 input wire sd_init_done, input wire fat_mounted, input wire fat_error,
 input wire [5:0] file_count, input wire [5:0] bmp_count, input wire [5:0] wav_count,
 input wire [5:0] first_bmp, input wire [7:0] fat_state, input wire bmp_busy,
 output reg bmp_req, output reg bmp_next_req, output reg bmp_prev_req,
 output reg cmd_ack_t, output reg tx_tog, output reg [63:0] tx_pkt
);
 reg pending_s0, pending_s1, consumed;
 wire [7:0] fat_flags={4'b0,bmp_busy,fat_error,fat_mounted,sd_init_done};
 always @(posedge clk) begin
  if (rst) begin
   pending_s0<=0; pending_s1<=0; consumed<=0;
   bmp_req<=0; bmp_next_req<=0; bmp_prev_req<=0;
   cmd_ack_t<=0; tx_tog<=0; tx_pkt<=0;
  end else begin
   pending_s0<=cmd_pending; pending_s1<=pending_s0;
   bmp_req<=0; bmp_next_req<=0; bmp_prev_req<=0;
   if (!pending_s1) consumed<=0;
   else if (!consumed) begin
    consumed<=1; cmd_ack_t<=~cmd_ack_t;
    if (cmd==8'h44) bmp_req<=1;
    if (cmd==8'h4e) bmp_next_req<=1;
    if (cmd==8'h50) bmp_prev_req<=1;
    if(DIAG_ENABLE && cmd==8'h53)
     tx_pkt<={fat_state,media_status,2'b00,file_count,fat_flags,cmd,8'hE3};
    else tx_pkt<={fat_state,2'b00,first_bmp,2'b00,wav_count,
             2'b00,bmp_count,2'b00,file_count,fat_flags,cmd,8'hE3};
    tx_tog<=~tx_tog;
   end
  end
 end
endmodule
