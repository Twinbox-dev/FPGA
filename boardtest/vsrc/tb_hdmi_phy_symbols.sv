`timescale 1ps/1ps
// Exact 5:1 clocks, 1.5ns serial phase. Encoder bits settle at 11/12.5ns:
// both are stable at the next pixel edge, but straddle the late load edge.
module tb_hdmi_phy_symbols #(parameter REG=1);
 reg pc=0,sc=0,rst=1;always #6665 pc=~pc;
 initial begin #1500;forever #1333 sc=~sc;end
 reg [9:0] core_word=10'h100;reg odd=0;
 always @(posedge pc)if(!rst)begin odd<=!odd;core_word<=odd?10'h100:10'h3ff;end
 wire [9:0] delayed;wire [4:0] late_high,late_low;
 assign #11000 late_high=core_word[9:5];
 assign #12500 late_low=core_word[4:0];
 assign delayed={late_high,late_low};
 wire serial;
 hdmi_phy_wrapper #(.PIXEL_REGISTER(REG)) dut(.I_pixel_clk(pc),.I_serial_clk(sc),.I_rst(rst),
 .I_tmds_channel_0(delayed),.I_tmds_channel_1(10'h100),.I_tmds_channel_2(10'h100),.I_tmds_channel_clk(10'h3e0),
 .O_tmds_ch0_p(serial),.O_tmds_ch1_p(),.O_tmds_ch2_p(),.O_tmds_clk_p());
 reg [1:0] load_history=0;integer pair_index=-1,words=0,bad=0;reg [9:0] received=0;
 always @(posedge sc)begin
  if(rst)begin load_history<=0;pair_index=-1;end
  else begin
   load_history<={load_history[0],dut.u0_lane_lvds_8_1.S_load_en_2d};
   if(load_history[1])pair_index=0;
   if(dut.u0_lane_lvds_8_1.S_load_en_2d && $time>300000 && $time<390000)$display("LOAD t=%0t pcphase=%0d raw=%h delayed=%h stable=%h",$time,($time-6665)%13330,core_word,delayed,dut.stable_ch0);
   #10;if(pair_index>=0)received[pair_index*2]=serial;
  end
 end
 always @(negedge sc)begin
  #10;
  if(!rst && pair_index>=0)begin
   received[pair_index*2+1]=serial;
   if(pair_index==4)begin
    if($time>300000)begin
     words=words+1;
     if(words<8)$display("WORD %h",received);
     if(received!=10'h100 && received!=10'h3ff)bad=bad+1;
    end
    pair_index=-1;
   end else pair_index=pair_index+1;
  end
 end
 initial begin
  repeat(8)@(negedge pc);rst=0;#15000000;
  if(words<500)$fatal(1,"insufficient serializer words %0d",words);
  if(REG && bad!=0)$fatal(1,"pixel-registered symbols corrupt: %0d/%0d",bad,words);
  if(!REG && bad==0)$fatal(1,"late-bus stimulus failed to reproduce unregistered fault");
  $display("PASS PHY register=%0d: %0d words, %0d corrupted, delayed-bit encoder output",REG,words,bad);$finish;
 end
endmodule
module EG_LOGIC_ODDR(input clk,rst,d0,d1,output wire q);
 reg p,n;
 always @(posedge clk or posedge rst)if(rst)begin p<=0;n<=0;end else begin p<=d0;n<=d1;end
 assign q=clk?p:n;
endmodule
