`timescale 1ns/1ps
module tb_video_memory_lease;
 reg mc=0,pc=0,rst=1;always #5 mc=~mc;always #6.667 pc=~pc;
 reg req=0,tx_busy=0;reg [1:0] audio_bank=2;
 reg fs=0,rd=0,wr=0,rv=0,rb=0,wb=0,lb=0,busy=0,refresh=0,active=0,idle=1;
 wire hold_old,grant,video,done,fault;wire [20:0] base;
 video_memory_lease dut(.mem_clk(mc),.pixel_clk(pc),.rst(rst),.request_async(req),.transaction_busy_async(tx_busy),
 .audio_buffer_async(audio_bank),.frame_start(fs),.old_rd_en(rd),.old_wr_en(wr),.old_rd_valid(rv),.old_rd_busy(rb),.old_wr_busy(wb),.old_line_busy(lb),
 .sdr_busy(busy),.sdr_refresh(refresh),.stream_active(active),.stream_idle(idle),.hold_old(hold_old),.memory_grant(grant),.scratch_base(base),
 .video_mode(video),.release_toggle(done),.accounting_error(fault));
 initial begin forever begin repeat(100)@(negedge pc);fs=1;@(negedge pc);fs=0;end end
 task memcycles(input integer n);repeat(n)@(negedge mc);endtask
 task run(input [1:0] bank,input [20:0] expect_base);
  reg old_done;
  begin
   audio_bank=bank;tx_busy=1;req=1;old_done=done;memcycles(80);
   if(grant||hold_old||video)$fatal(1,"lease interrupted in-flight image transaction");
   tx_busy=0;memcycles(5);rd=1;memcycles(6);rd=0;rb=1;
   wait(hold_old);memcycles(50);if(grant)$fatal(1,"lease granted with pending response");
   rb=0;rv=1;memcycles(6);rv=0;refresh=1;memcycles(40);
   if(grant)$fatal(1,"grant overlapped refresh");refresh=0;
   wait(grant);memcycles(3);
   if(base!==expect_base||!video||fault)$fatal(1,"wrong lease base or pixel handoff");
   active=1;idle=0;memcycles(200);active=0;memcycles(50);
   if(!grant)$fatal(1,"released while pipeline not quiescent");
   idle=1;wait(!grant);wait(done!=old_done);
   if(video||hold_old)$fatal(1,"old picture not restored at release");
   // App domain deliberately observes DONE late; do not grant twice.
   memcycles(300);if(grant||video||hold_old)$fatal(1,"level request retriggered lease");
   req=0;memcycles(20);
  end
 endtask
 initial begin
  memcycles(8);rst=0;run(2,21'd1509376);run(3,21'd921600);
  $display("PASS SDRAM lease: existing transaction, response drain, refresh, VS handoff, inactive audio bank and release");$finish;
 end
 initial begin #200000;$fatal(1,"lease timeout");end
endmodule
