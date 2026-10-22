`timescale 1ns/1ps
module tb_media_image_tx_gap;
    reg clk=0; always #4 clk=~clk;
    reg rst=1;
    wire start_toggle,audio_start_toggle,fifo_read,tx_request,tx_valid,busy,committed_valid,committed_wav,media_to_pc;
    wire [4:0] source_index,audio_file_index,committed_index;
    wire [7:0] tx_data,error_code;
    wire [15:0] tx_length;
    wire [3:0] state_code;

    media_image_tx #(.CLK_HZ(125000000),.FRAME_WORDS(2)) dut (
        .clk(clk),.rst(rst),.mounted(1'b0),.source_busy(1'b0),.source_error(1'b0),
        .first_bmp(6'd0),.bmp_next(192'd0),.bmp_prev(192'd0),
        .image_width(12'd1280),.image_height(12'd720),
        .cmd(8'd0),.cmd_pending(1'b0),.auto_next(1'b0),.auto_status(1'b0),
        .pc_snapshot_request(1'b0),.local_next(1'b0),.local_prev(1'b0),
        .prepared_toggle(1'b0),.done_toggle(1'b0),.source_has_wav_async(1'b0),
        .source_wav_index_async(5'd0),.audio_prepared_toggle(1'b0),
        .audio_done_toggle(1'b0),.audio_sample_count_async(32'd0),
        .audio_source_error_async(1'b0),.start_toggle(start_toggle),
        .source_index(source_index),.audio_start_toggle(audio_start_toggle),
        .audio_file_index(audio_file_index),.fifo_empty(1'b1),.fifo_data(32'd0),
        .fifo_read(fifo_read),.rx_data(8'd0),.rx_valid(1'b0),
        .tx_request(tx_request),.tx_valid(tx_valid),.tx_data(tx_data),
        .tx_length(tx_length),.tx_ack(1'b0),.busy(busy),
        .committed_index(committed_index),.committed_valid(committed_valid),
        .committed_wav(committed_wav),.error_code(error_code),
        .state_code(state_code),.media_to_pc(media_to_pc)
    );

    integer cycles=0;
    initial begin
        repeat(4) @(negedge clk);
        rst=0;
        // Enter the end of a one-word DATA packet in a two-word frame. The
        // next chunk must wait before the receiver's single packet RAM is reused.
        @(negedge clk);
        dut.state=4'd4;
        dut.kind=8'h22;
        dut.byte_index=0;
        dut.tx_length=16;
        dut.total_words=1;
        dut.packet_words=1;
        dut.frame_total_words=2;
        dut.return_state=4'd2;
        dut.wait_count=0;
        while(dut.state==4'd4) @(negedge clk);
        if(dut.state!=4'd15) $fatal(1,"DATA packet did not enter IMAGE_PACKET_GAP");
        while(dut.state==4'd15) begin
            @(negedge clk);
            cycles=cycles+1;
        end
        if(dut.state!=4'd2 || cycles<12499 || cycles>12501)
            $fatal(1,"packet gap state=%0d cycles=%0d",dut.state,cycles);
        $display("PASS: image packet sender waits %0d cycles (100 us) for receiver drain",cycles);

        // Audio DATA uses the same one-buffer receiver. A non-final audio
        // packet must wait before the next packet is requested as well.
        @(negedge clk);
        dut.state=4'd4;
        dut.kind=8'h31;
        dut.byte_index=0;
        dut.tx_length=16;
        dut.audio_samples_remaining=2024;
        dut.audio_packet_samples=1012;
        dut.return_state=4'd11;
        dut.wait_count=0;
        cycles=0;
        while(dut.state==4'd4) @(negedge clk);
        if(dut.state!=4'd15) $fatal(1,"audio DATA packet did not enter shared gap");
        while(dut.state==4'd15) begin
            @(negedge clk);
            cycles=cycles+1;
        end
        if(dut.state!=4'd11 || cycles<12499 || cycles>12501)
            $fatal(1,"audio packet gap state=%0d cycles=%0d",dut.state,cycles);
        $display("PASS: non-final audio packet also waits %0d cycles (100 us)",cycles);
        dut.width_gap_cycles_r=28'd875000;dut.top_pad_cycles_r=0;dut.bottom_pad_cycles_r=0;
        if (dut.image_packet_gap(9'd253,21'd253) < 28'd875000)
            $fatal(1,"narrow image packet gap is too short");
        dut.width_gap_cycles_r=28'd12500;dut.bottom_pad_cycles_r=28'd574400;
        if (dut.image_end_gap(9'd134,21'd640) < 28'd574400)
            $fatal(1,"short-image trailing canvas gap is too short");
        $display("PASS: narrow and short images receive padding-aware packet/end gaps");
        $finish;
    end
    initial begin #500000;$fatal(1,"timeout");end
endmodule
