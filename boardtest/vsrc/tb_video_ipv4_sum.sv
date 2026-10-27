`timescale 1ns/1ps
module tb_video_ipv4_sum;
 reg clk=0,rst=1;
 display_udp_lite dut(.clk(clk),.reset(rst),.app_tx_request(1'b0),.app_tx_data_valid(1'b0),
  .app_tx_data(8'd0),.app_tx_data_length(16'd0),.app_tx_dst_port(16'd0),
  .ip_tx_dst_address(32'd0),.ip_tx_dst_mac(48'd0),.temac_rx_valid(1'b0),
  .temac_rx_data(8'd0),.temac_rx_sof(1'b1),.temac_rx_eof(1'b1),.temac_tx_ready(1'b0));
 reg [31:0] folded;
 initial begin
  // Exhaust every possible sum of the ten IPv4 16-bit header words.
  for(integer n=0;n<=10*65535;n=n+1)begin
   folded=n;
   folded={16'd0,folded[15:0]}+{16'd0,folded[31:16]};
   folded={16'd0,folded[15:0]}+{16'd0,folded[31:16]};
   if(dut.ip_checksum_ok(n[19:0]) !== (folded[15:0]==16'hffff))
    $fatal(1,"IPv4 sum equivalence failed at %0d",n);
  end
  $display("PASS bounded IPv4 sum: all 655351 values match end-around carry reference");$finish;
 end
endmodule
