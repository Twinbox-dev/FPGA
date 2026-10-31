`timescale 1ns/1ps
module tb_media_audio_pause;
 reg clk=0,rst=1,pause=0,toggle=0;always #5 clk=~clk;
 reg[1:0] bank=2;wire req,ren,tick,valid;wire[1:0] index;wire[23:0] left;
 media_audio_playback #(.PAUSE_ENABLED(1)) dut(.clk(clk),.rst(rst),.pause(pause),.source_toggle(toggle),.pair_on(1'b1),
 .source_buffer(bank),.source_length(21'd256),.source_samples(32'd512),.read_req(req),.read_req_ack_async(req),.read_index(index),
 .read_length(),.read_en(ren),.read_data(32'h83828180),.read_fifo_words(10'd512),.audio_tick(tick),.audio_valid(valid),.audio_left(left),.audio_right(),.audio_underrun());
 integer seen=0;always @(posedge clk)if(valid)seen++;
 reg[31:0] remaining;reg[1:0] pos;reg phase;
 initial begin
  repeat(6)@(negedge clk);rst=0;toggle=1;wait(seen==4);@(negedge clk);pause=1;repeat(3)@(negedge clk);
  remaining=dut.samples_remaining;pos=dut.byte_pos;phase=dut.duplicate_phase;
  repeat(7000)begin @(negedge clk);if(ren||valid||tick)$fatal(1,"paused WAV consumed/emitted data");end
  if(dut.samples_remaining!=remaining||dut.byte_pos!=pos||dut.duplicate_phase!=phase)$fatal(1,"paused WAV position changed");
  pause=0;wait(seen>=6);@(negedge clk);pause=1;repeat(4)@(negedge clk);
  bank=3;toggle=0;repeat(10)@(negedge clk);
  if(index!=3||!dut.restart_pending||dut.active_samples!=512)$fatal(1,"source change lost while paused");
  pause=0;wait(seen>=8);$display("PASS WAV pause preserves position, resumes and retains source changes");$finish;
 end
 initial begin #1000000;$fatal(1,"pause timeout");end
endmodule
