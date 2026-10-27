`timescale 1ns/1ps
module tb_video_sdram_port #(parameter INJECT_BAD=0,DROP_READ=0,WALK=0,BASE=0,ALT=0);
 reg clk=0,rst=1;always #5 clk=~clk;reg [15:0] phase=0;
 always @(posedge clk)phase<=phase+1'b1;
 wire busy=phase%29>=19 && phase%29<23;
 wire refresh=phase%43>=33 && phase%43<36;
 wire req,write,request_ready,wvalid,wready,rvalid,pdone,perror,we,re;wire [20:0] addr,wa,ra;
 wire [8:0] len;wire [31:0] wd,rd,app_wdata;wire [95:0] metrics,bad;wire toggle;wire [1:0] kind;
 reg [31:0] mem[0:(WALK?2097151:511)];reg [2:0] response_valid=0;reg [31:0] response_data[0:2];
 video_sdram_port #(.GUARD_CYCLES(4),.TIMEOUT_CYCLES(200)) port(
 .clk(clk),.rst(rst),.init_done(!rst),.sdr_busy(busy),.sdr_refresh(refresh),.gate_each_beat(1'b1),
 .req_valid(req),.req_write(write),.req_addr(addr),.req_len(len),.req_ready(request_ready),
 .wr_valid(wvalid),.wr_data(wd),.wr_ready(wready),.rd_valid(rvalid),.rd_data(rd),.done(pdone),.error(perror),
 .app_wr_en(we),.app_wr_addr(wa),.app_wr_data(app_wdata),.app_rd_en(re),.app_rd_addr(ra),
 .sdr_rd_en(response_valid[2]),.sdr_rd_data(response_data[2]));
 video_sdram_bist #(.RANGE_WORDS(512),.CHUNK_WORDS(64),.WALK_BASE(WALK),.BASE(BASE),.ALTERNATE_SHORT(ALT)) bist(.clk(clk),.rst(rst),.init_done(!rst),
 .req_ready(request_ready),.wr_ready(wready),.rd_valid(rvalid),.rd_data(rd),.port_done(pdone),.port_error(perror),
 .req_valid(req),.req_write(write),.req_addr(addr),.req_len(len),.wr_valid(wvalid),.wr_data(wd),
 .metrics(metrics),.bad_words(bad),.snapshot_toggle(toggle),.kind(kind));
 reg [20:0] expected_address;
 always @(posedge clk)begin
  if(req && request_ready)expected_address<=addr;
  if(we||re)begin
   if((we?wa:ra)!==expected_address)$fatal(1,"native burst address differs from accepted base/beat");
   expected_address<=expected_address+1'b1;
  end
  response_valid<={response_valid[1:0],re && !(DROP_READ && ra==128)};
  if(re)response_data[0]<=mem[ra] ^ ((INJECT_BAD && ra==129)?32'd1:32'd0);
  response_data[1]<=response_data[0];response_data[2]<=response_data[1];
  if(we)mem[wa]<=app_wdata;
  if(!rst && (we||re) && (busy||refresh))$fatal(1,"request issued while gated memory unavailable");
 end
 initial begin
  repeat(5)@(negedge clk);rst=0;
  if(INJECT_BAD || DROP_READ)begin
   wait(kind!=0);repeat(5)@(negedge clk);
   if(INJECT_BAD && (kind!=1 || bad[31:0]!=129 || (bad[95:64]^bad[63:32])!=1))$fatal(1,"bad-word evidence invalid %h",bad);
   if(DROP_READ && kind!=2)$fatal(1,"missing response did not time out");
   if(req||we||re)$fatal(1,"failed BIST did not halt safely");
  end else begin
   wait(metrics[15:0]>=3);if(metrics[31:16]!=0 || kind!=0)$fatal(1,"clean BIST failed");
  end
  $display("PASS SDRAM client/BIST: corrupt=%0d missing=%0d; gated bursts, delayed data, golden, bounded failure",INJECT_BAD,DROP_READ);$finish;
 end
 initial begin #2000000;$fatal(1,"SDRAM BIST timeout");end
endmodule
