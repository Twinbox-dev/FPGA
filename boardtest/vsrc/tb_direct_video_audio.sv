`timescale 1ns/1ps
module tb_direct_video_audio #(parameter N=8,HALF=4,DELAY=2);
 localparam FRAME_CYCLES=N*(2*HALF+1);
 reg ac=0,pc=0,rst=1;always #4 ac=~ac;always #6.667 pc=~pc;
 reg live=1;reg rv=0,ps=0,pe=0,se=0,vr=0,fs=0;reg[7:0] data=0;reg[15:0] sf=65534;
 wire av;wire[23:0] ad;wire[95:0] stats;
 direct_video_audio #(.SAMPLES(N),.HALF_BASE(HALF),.START_DELAY(DELAY)) dut(.app_clk(ac),.pixel_clk(pc),.rst(rst),
 .rx_valid(rv),.packet_start(ps),.packet_end(pe),.rx_data(data),.packet_length(16'(N+10)),.session_live(live),.session_event(se),.session_frame(sf),
 .video_ready(vr),.frame_start(fs),.missing_seen(),.audio_valid(av),.audio_data(ad),.audio_stats(stats));
 function [7:0] sample(input [15:0] f,input integer x);sample=8'(f+x*17);endfunction
 function [15:0] crc(input[15:0] c,input[7:0] d);reg[15:0] v;begin v=c^{d,8'd0};for(integer n=0;n<8;n++)v=v[15]?(v<<1)^16'h1021:v<<1;return v;end endfunction
 task packet(input [15:0] f,input bit corrupt);
  reg[15:0] c;reg[7:0] b;
  begin
   c=16'hffff;
   for(integer n=0;n<N+10;n++)begin
    case(n)0:b=8'h41;1:b=8'h44;2:b=1;3:b=0;4:b=f[7:0];5:b=f[15:8];6:b=N%256;7:b=N/256;
     N+8:b=c[7:0];N+9:b=c[15:8]^(corrupt?1:0);default:b=sample(f,n-8);endcase
    if(n<N+8)c=crc(c,b);
    @(negedge ac);ps=n==0;pe=n==N+9;rv=1;data=b;
   end
   @(negedge ac);ps=0;pe=0;rv=0;repeat(4)@(negedge ac);
  end
 endtask
 integer seen=0;reg checking=0;reg[15:0] expect_frame;reg expect_silence;
 always @(posedge pc)begin
  #1;
  if(checking&&av)begin
   if(ad!==(expect_silence?24'd0:{sample(expect_frame,seen/2)^8'h80,16'd0}))$fatal(1,"PCM mismatch frame%0d output%0d got%h",expect_frame,seen,ad);
   seen++;
  end
 end
 task check_frame(input[15:0] f,input bit silence,input bit first_frame);
  begin
   @(negedge pc);expect_frame=f;expect_silence=silence;seen=0;checking=1;
   if(first_frame)vr=1;else fs=1;
   @(negedge pc);fs=0;repeat(FRAME_CYCLES-1)@(negedge pc);checking=0;
   if(seen!=2*N)$fatal(1,"incorrect 48k repeated sample count %0d",seen);
  end
 endtask
 initial begin
  repeat(8)@(negedge ac);rst=0;se=1;@(negedge ac);se=0;repeat(20)@(negedge pc);
  packet(65534,0);packet(65535,1);packet(0,0);repeat(8)@(negedge pc);
  check_frame(65534,0,1);check_frame(65535,1,0);check_frame(0,0,0);check_frame(1,1,0);
  vr=0;live=0;repeat(20)@(negedge ac);
  if(stats[15:0]!=2||stats[31:16]!=1||stats[47:32]!=2||stats[63:48]!=2||stats[79:64]!=0)$fatal(1,"audio stats wrong %h",stats);
  live=1;sf=65534;se=1;@(negedge ac);se=0;repeat(20)@(negedge pc);packet(65534,0);repeat(8)@(negedge pc);check_frame(65534,0,1);
  vr=0;repeat(20)@(negedge ac);if(stats[15:0]!=3||stats[47:32]!=3||stats[79:64]!=0)$fatal(1,"restart integrity failed");
  // Exercise every aligned BRAM slot with a distinct full block.
  live=0;repeat(20)@(negedge ac);live=1;sf=8;se=1;@(negedge ac);se=0;repeat(20)@(negedge pc);
  packet(8,0);packet(9,0);packet(10,0);packet(11,0);repeat(8)@(negedge pc);
  check_frame(8,0,1);check_frame(9,0,0);check_frame(10,0,0);check_frame(11,0,0);
  $display("PASS audio PCM: exact samples duplicated, frame wrap, CRC bad/missing silence, restart and output CRC");$finish;
 end
 initial begin #150000000;$fatal(1,"audio test timeout");end
endmodule
