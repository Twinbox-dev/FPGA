`timescale 1ns/1ps
// Bounded native application-port client. This is not a frame buffer engine.
// At most one read/write transaction; no simultaneous application commands.
module video_sdram_port #(parameter GUARD_CYCLES=16,TIMEOUT_CYCLES=100000)(
 input wire clk,rst,init_done,sdr_busy,sdr_refresh,gate_each_beat,
 input wire req_valid,req_write,input wire [20:0] req_addr,input wire [8:0] req_len,
 output wire req_ready,input wire wr_valid,input wire [31:0] wr_data,output wire wr_ready,
 output wire rd_valid,output wire [31:0] rd_data,output reg done,error,
 output reg [31:0] max_write_cycles,max_read_cycles,
 output wire app_wr_en,output wire [20:0] app_wr_addr,output wire [31:0] app_wr_data,
 output wire app_rd_en,output wire [20:0] app_rd_addr,input wire sdr_rd_en,input wire [31:0] sdr_rd_data
);
 localparam IDLE=0,WRITE=1,READ=2,DRAIN=3;
 reg [1:0] state;reg [20:0] base;reg [8:0] count,returned,length;
 localparam AGE_BITS=$clog2(TIMEOUT_CYCLES+1);
 reg [AGE_BITS-1:0] age;reg [$clog2(GUARD_CYCLES+1)-1:0] guard;
 wire allow_beat=!sdr_refresh && (!gate_each_beat || !sdr_busy);
 wire [9:0] column_end={2'd0,req_addr[7:0]}+{1'b0,req_len};
 assign req_ready=state==IDLE && init_done && !sdr_busy && !sdr_refresh;
 assign wr_ready=state==WRITE && allow_beat;
 assign app_wr_en=wr_ready&&wr_valid;
 // Admission rejects any request crossing a 256-word column boundary.
 // Consequently an issued beat never carries into the upper address bits.
 wire [7:0] beat_column=base[7:0]+count[7:0];
 assign app_wr_addr={base[20:8],beat_column};assign app_wr_data=wr_data;
 assign app_rd_en=state==READ && count<length && allow_beat;
 assign app_rd_addr={base[20:8],beat_column};
 assign rd_valid=state==READ&&sdr_rd_en;assign rd_data=sdr_rd_data;
 always @(posedge clk or posedge rst)begin
  if(rst)begin state<=IDLE;base<=0;count<=0;returned<=0;length<=0;age<=0;guard<=0;done<=0;error<=0;max_write_cycles<=0;max_read_cycles<=0;end
  else begin
   done<=0;
   case(state)
    IDLE:if(req_valid && req_ready)begin
     base<=req_addr;length<=req_len;count<=0;returned<=0;age<=0;error<=0;
     if(req_len==0 || req_len>128 || column_end>256)begin done<=1;error<=1;end
     else state<=req_write?WRITE:READ;
    end
    WRITE,READ:begin
     age<=age+1'b1;
     if(app_wr_en || app_rd_en)count<=count+1'b1;
     if(rd_valid)returned<=returned+1'b1;
     if((state==WRITE && app_wr_en && count==length-1) ||
        (state==READ && rd_valid && returned==length-1))begin
         state<=DRAIN;guard<=GUARD_CYCLES;
         if(state==WRITE && age+GUARD_CYCLES+1>max_write_cycles)max_write_cycles<=age+GUARD_CYCLES+1;
         if(state==READ && age+GUARD_CYCLES+1>max_read_cycles)max_read_cycles<=age+GUARD_CYCLES+1;
        end
     else if(age==TIMEOUT_CYCLES-1)begin state<=DRAIN;guard<=GUARD_CYCLES;error<=1;end
    end
    DRAIN:if(guard!=0)guard<=guard-1'b1;else begin state<=IDLE;done<=1;end
    default:state<=IDLE;
   endcase
  end
 end
`ifdef VERILATOR
 always @(posedge clk)if(!rst && app_wr_en && app_rd_en)$fatal(1,"SDRAM simultaneous read/write");
 always @(posedge clk)if(!rst && (app_wr_en||app_rd_en) && ({1'b0,base[7:0]}+count)>=256)$fatal(1,"SDRAM beat crossed admitted column boundary");
`endif
endmodule
