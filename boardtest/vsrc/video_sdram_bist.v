`timescale 1ns/1ps
// Before video integration, measure and validate the native SDRAM interface.
// An error halts safely and keeps its address/expected/actual words available.
module video_sdram_bist #(parameter RANGE_WORDS=65536,CHUNK_WORDS=64,BASE=0,WALK_BASE=0,ALTERNATE_SHORT=0)(
 input wire clk,rst,init_done,input wire req_ready,wr_ready,rd_valid,port_done,port_error,
 input wire [31:0] rd_data,output wire req_valid,req_write,wr_valid,
 output wire [20:0] req_addr,output wire [8:0] req_len,output wire [31:0] wr_data,
 output reg [95:0] metrics,bad_words,output reg snapshot_toggle,output wire [1:0] kind,output reg [31:0] max_request_wait
);
 localparam WAIT_INIT=0,W_REQ=1,W_DATA=2,R_REQ=3,R_DATA=4,HALT=5;
 reg [2:0] state;reg [20:0] address,page_base;reg [16:0] request_wait;reg [8:0] tx_index,rx_index;
 reg [31:0] seed,cycles,write_cycles,errors,rounds;
 reg [20:0] bad_addr;reg [31:0] bad_expected,bad_actual;reg timed_out;
 function [31:0] pattern(input [20:0] a,input [31:0] salt);
  reg [31:0] x;begin x={11'd0,a};pattern=x^(x<<11)^((x<<22)|(x>>10))^salt;end
 endfunction
 wire [8:0] transfer_chunk=(ALTERNATE_SHORT&&rounds[0])?9'd4:CHUNK_WORDS;
 assign req_valid=state==W_REQ || state==R_REQ;assign req_write=state==W_REQ;
 assign req_addr=BASE+page_base+address;assign req_len=transfer_chunk;
 assign wr_valid=state==W_DATA;assign wr_data=pattern(req_addr+tx_index,seed);
 assign kind=(state==HALT)?(timed_out?2'd2:2'd1):2'd0;
 wire [20:0] expected_addr=req_addr+rx_index;
 wire [31:0] expected=pattern(expected_addr,seed);
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   state<=WAIT_INIT;address<=0;page_base<=0;request_wait<=0;max_request_wait<=0;tx_index<=0;rx_index<=0;seed<=32'ha5c31f07;
   cycles<=0;write_cycles<=0;errors<=0;rounds<=0;metrics<=0;bad_words<=0;snapshot_toggle<=0;
   bad_addr<=0;bad_expected<=0;bad_actual<=0;timed_out<=0;
  end else begin
   if(state!=WAIT_INIT && state!=HALT)cycles<=cycles+1'b1;
   if(req_valid && !req_ready)begin
    request_wait<=request_wait+1'b1;
    if(request_wait+1'b1>max_request_wait)max_request_wait<=request_wait+1'b1;
   end else request_wait<=0;
   case(state)
    WAIT_INIT:if(init_done)begin state<=W_REQ;cycles<=0;end
    W_REQ:if(req_ready)begin tx_index<=0;state<=W_DATA;end
    W_DATA:begin
     if(wr_valid&&wr_ready)tx_index<=tx_index+1'b1;
     if(port_done)begin
      if(port_error)begin state<=HALT;timed_out<=1;errors<=errors+1'b1;
       bad_words<={32'hffffffff,32'h00000000,{11'd0,req_addr}};snapshot_toggle<=~snapshot_toggle;end
      else if(address+transfer_chunk==RANGE_WORDS)begin address<=0;state<=R_REQ;write_cycles<=cycles;cycles<=0;end
      else begin address<=address+transfer_chunk;state<=W_REQ;end
     end
    end
    R_REQ:if(req_ready)begin rx_index<=0;state<=R_DATA;end
    R_DATA:begin
     if(rd_valid)begin
      rx_index<=rx_index+1'b1;
      if(rd_data!=expected)begin errors<=errors+1'b1;bad_addr<=expected_addr;bad_expected<=expected;bad_actual<=rd_data;end
     end
     if(port_done)begin
      if(port_error)begin state<=HALT;timed_out<=1;errors<=errors+1'b1;
       bad_words<={32'hffffffff,expected,{11'd0,expected_addr}};snapshot_toggle<=~snapshot_toggle;end
      else if(address+transfer_chunk==RANGE_WORDS)begin
       rounds<=rounds+1'b1;
       metrics<={cycles,write_cycles,errors[15:0],rounds[15:0]+16'd1};snapshot_toggle<=~snapshot_toggle;
       if(errors!=0)begin state<=HALT;bad_words<={bad_actual,bad_expected,{11'd0,bad_addr}};end
       else begin state<=W_REQ;address<=0;page_base<=page_base+(WALK_BASE?RANGE_WORDS:0);seed<=seed+32'h01030507;cycles<=0;end
      end else begin address<=address+transfer_chunk;state<=R_REQ;end
     end
    end
    default:state<=state;
   endcase
  end
 end
`ifdef VERILATOR
 initial if(RANGE_WORDS%CHUNK_WORDS!=0 || CHUNK_WORDS>128 || CHUNK_WORDS<1)$fatal(1,"BIST configuration invalid");
`endif
endmodule
