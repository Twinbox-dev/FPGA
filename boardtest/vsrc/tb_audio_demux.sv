`timescale 1ns/1ps
module tb_audio_demux;
 reg clk=0,rst=1;always #4 clk=~clk;
 reg valid=0,start=0,finish=0;reg[7:0] data=0;
 wire av,vv;wire[7:0] ad,vd;integer na=0,nv=0;
 direct_video_packet_demux #(.DROP_AUDIO(1)) dut(.clk(clk),.rst(rst),.rx_valid(valid),.rx_data(data),.rx_length(16'd4),.rx_packet_start(start),.rx_packet_end(finish),
 .app_valid(av),.app_data(ad),.video_valid(vv),.video_data(vd));
 always @(posedge clk)begin
  #1;
  if(av)begin if(ad!==(8'h11+na*17))$fatal(1,"audio leaked into controls %h",ad);na++;end
  if(vv)begin if(vd!==(nv==0?8'h56:nv==1?8'h44:8'(nv)))$fatal(1,"video demux wrong");nv++;end
 end
 task send(input[31:0] word);
  begin
   for(integer n=0;n<4;n++)begin @(negedge clk);valid=1;start=n==0;finish=n==3;data=word[n*8+:8];end
   @(negedge clk);valid=0;start=0;finish=0;repeat(4)@(negedge clk);
  end
 endtask
 initial begin repeat(6)@(negedge clk);rst=0;send(32'hccbb4441);send(32'h44332211);send(32'h03024456);repeat(5)@(negedge clk);
  if(na!=4||nv!=4)$fatal(1,"packet dropped unexpectedly");$display("PASS AD packet isolation from product controls; VD and control remain intact");$finish;end
endmodule
