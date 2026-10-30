`timescale 1ns/1ps
module tb_video_still_equivalence;
 reg clk=0,rst=1,hs=0,vs=0,de=0;reg [31:0] data=0;
 always #6.667 clk=~clk;
 wire [29:0] reference_out,current_out;
 video_delay_before_zoom #(.MIX_PIPELINE(1)) old_path(.video_clk(clk),.rst(rst),.read_data(data),.hs(hs),.vs(vs),.de(de),
 .read_en(reference_out[29]),.hs_r(reference_out[28]),.vs_r(reference_out[27]),.de_r(reference_out[26]),.de_word(reference_out[25]),.vs_word(reference_out[24]),.vout_data(reference_out[23:0]));
 video_delay #(.MIX_PIPELINE(1),.REPEAT_2X_ENABLED(1)) new_path(.video_clk(clk),.rst(rst),.repeat_2x(1'b0),.read_data(data),.hs(hs),.vs(vs),.de(de),
 .read_en(current_out[29]),.hs_r(current_out[28]),.vs_r(current_out[27]),.de_r(current_out[26]),.de_word(current_out[25]),.vs_word(current_out[24]),.vout_data(current_out[23:0]));
 initial begin
  repeat(5)@(negedge clk);rst=0;
  for(integer i=0;i<100000;i++)begin
   @(negedge clk);de=(i%1650)<1280;hs=(i%1650)>40;vs=(i/1650)%750>5;data=$urandom;
   @(posedge clk);#1;if(current_out!==reference_out)$fatal(1,"ordinary mode differs cycle %0d: %h/%h",i,current_out,reference_out);
  end
  $display("PASS ordinary-mode read enable, RGB and timing match pre-zoom unpacker for 100000 clocks");$finish;
 end
endmodule
