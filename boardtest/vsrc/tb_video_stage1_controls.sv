`timescale 1ns/1ps
module tb_video_stage1_controls;
 reg clk=0,rst=1,valid=0;reg[7:0] data=0;always #4 clk=~clk;
 wire changed,ack;wire[7:0] op,value,status;
 media_display_control_rx #(.CV_ENABLED(0),.SPECTRUM_ENABLED(0)) dut(
  .clk(clk),.rst(rst),.rx_valid(valid),.rx_data(data),.set_toggle(changed),.set_op(op),.set_value(value),
  .control_ack_valid(ack),.control_ack_status(status));
 integer acks=0;reg[7:0] last_status;reg[7:0] sequence_id=0;
 always @(posedge clk)if(ack)begin acks<=acks+1;last_status<=status;end
 task send_byte(input[7:0] x);begin @(negedge clk);valid=1;data=x;end endtask
 task set_value(input[7:0] opcode,input[7:0] v,input[7:0] expected_status);
  reg previous;integer count;
  begin
   previous=changed;count=acks;sequence_id=sequence_id+1'b1;
   send_byte(8'haa);send_byte(8'hbb);send_byte(8'hcc);send_byte(8'hdd);
   send_byte(0);send_byte(8'h40);send_byte(0);send_byte(4);
   send_byte(sequence_id);send_byte(opcode);send_byte(v);send_byte(0);
   @(negedge clk);valid=0;repeat(5)@(negedge clk);
   if(acks!=count+1||last_status!=expected_status)$fatal(1,"missing/wrong capability ACK");
   if((changed!=previous)!=(expected_status==0))$fatal(1,"rejected operation changed control state");
  end
 endtask
 initial begin
  repeat(6)@(negedge clk);rst=0;
  set_value(1,5,0);set_value(6,0,0);set_value(6,1,1);set_value(9,0,0);
  for(integer mode=1;mode<=5;mode++)set_value(9,8'(mode),1);
  set_value(7,3,0);set_value(3,6,0);set_value(1,2,0);
  $display("PASS first-stage capabilities: CV/spectrum enable rejected, raw/off/normal settings accepted; parser recovers");$finish;
 end
 initial begin #200000;$fatal(1,"capability test timeout");end
endmodule
