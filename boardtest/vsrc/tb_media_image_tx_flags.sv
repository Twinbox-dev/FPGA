`timescale 1ns/1ps

module tb_media_image_tx_flags;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg mounted=1, source_busy=0, source_error=0;
    reg [5:0] first_bmp=6'd3;
    reg [191:0] bmp_next=0, bmp_prev=0;
    reg [11:0] image_width=12'd1, image_height=12'd1;
    reg [7:0] cmd=0;
    reg cmd_pending=0, auto_next=0, auto_status=1;
    reg pc_snapshot_request=0;
    reg local_next=0, local_prev=0;
    reg prepared_toggle=0, done_toggle=0;
    reg source_has_wav_async=1;
    reg [4:0] source_wav_index_async=0;
    reg audio_prepared_toggle=0, audio_done_toggle=0;
    reg [31:0] audio_sample_count_async=0;
    reg audio_source_error_async=0;
    wire start_toggle, audio_start_toggle;
    wire [4:0] source_index, audio_file_index;
    reg fifo_empty=1;
    reg [31:0] fifo_data=0;
    wire fifo_read, tx_request, tx_valid;
    wire [7:0] tx_data;
    wire [15:0] tx_length;
    reg tx_ack=0;
    reg [7:0] rx_data=0;
    reg rx_valid=0;
    wire busy;
    wire [4:0] committed_index;
    wire committed_valid, committed_wav;
    wire [7:0] error_code;
    wire [3:0] state_code;
    wire media_to_pc;
    reg [7:0] got [0:23];
    reg [7:0] ready_bytes [0:8];
    integer i;
    reg old_start;

    media_image_tx #(.CLK_HZ(1000), .FRAME_WORDS(1)) dut (
        .job_start(1'b0),.job_snapshot(1'b0),.job_previous(1'b0),.job_index(5'd0),.job_layout(2'd0),.job_window(2'd0),.job_generation(16'd0),.job_ready(),.job_done(),.job_result(),
        .clk(clk), .rst(rst),
        .mounted(mounted), .source_busy(source_busy), .source_error(source_error),
        .first_bmp(first_bmp), .bmp_next(bmp_next), .bmp_prev(bmp_prev),
        .image_width(image_width), .image_height(image_height),
        .cmd(cmd), .cmd_pending(cmd_pending), .auto_next(auto_next), .auto_status(auto_status),
        .pc_snapshot_request(pc_snapshot_request), .media_to_pc(media_to_pc),
        .local_next(local_next), .local_prev(local_prev),
        .prepared_toggle(prepared_toggle), .done_toggle(done_toggle),
        .source_has_wav_async(source_has_wav_async),
        .source_wav_index_async(source_wav_index_async),
        .audio_prepared_toggle(audio_prepared_toggle), .audio_done_toggle(audio_done_toggle),
        .audio_sample_count_async(audio_sample_count_async),
        .audio_source_error_async(audio_source_error_async),
        .start_toggle(start_toggle), .source_index(source_index),
        .audio_start_toggle(audio_start_toggle), .audio_file_index(audio_file_index),
        .fifo_empty(fifo_empty), .fifo_data(fifo_data), .fifo_read(fifo_read),
        .rx_data(rx_data), .rx_valid(rx_valid),
        .tx_request(tx_request), .tx_valid(tx_valid), .tx_data(tx_data),
        .tx_length(tx_length), .tx_ack(tx_ack), .busy(busy),
        .committed_index(committed_index), .committed_valid(committed_valid),
        .committed_wav(committed_wav), .error_code(error_code), .state_code(state_code)
    );

    initial begin
        ready_bytes[0]=8'haa; ready_bytes[1]=8'hbb; ready_bytes[2]=8'hcc; ready_bytes[3]=8'hdd;
        ready_bytes[4]=8'h20; ready_bytes[5]=8'h00; ready_bytes[6]=8'h01; ready_bytes[7]=8'h00;
        ready_bytes[8]=8'h01;
        repeat(4) @(negedge clk); rst=0;
        for (i=0;i<9;i=i+1) begin
            rx_data=ready_bytes[i]; rx_valid=1;
            @(negedge clk);
        end
        rx_valid=0;
        old_start=start_toggle;
        wait(start_toggle!=old_start);
        // The auto state and paired-WAV indication are stable before the
        // source's prepared toggle reaches the sender's synchronized input.
        @(negedge clk); prepared_toggle=~prepared_toggle;
        wait(tx_request);
        if (tx_length!=24) $fatal(1,"BEGIN packet length");
        @(negedge clk); tx_ack=1;
        @(negedge clk); tx_ack=0;
        for (i=0;i<24;i=i+1) begin
            if (!tx_valid) $fatal(1,"BEGIN packet ended early at byte %0d",i);
            got[i]=tx_data;
            @(negedge clk);
        end
        if ({got[0],got[1],got[2],got[3]} !== 32'haabbccdd) $fatal(1,"bad app header");
        if (got[4]!=8'h21 || got[5]!=0 || got[6]!=8'd16 || got[7]!=0)
            $fatal(1,"bad BEGIN type/length");
        if (got[10]!=8'd3) $fatal(1,"image index not preserved");
        if (!got[11][4] || !got[11][3] || got[11][0])
            $fatal(1,"BEGIN flags mismatch: %02x",got[11]);
        if (media_to_pc) $fatal(1,"normal display transaction routed to PC");
        if ({got[15],got[14],got[13],got[12]}!=32'd1 ||
            {got[17],got[16]}!=16'd1 || {got[19],got[18]}!=16'd1 ||
            got[20]!=0 || got[21]!=0 || got[22]!=0 || got[23]!=0)
            $fatal(1,"bad frame word count");
        $display("PASS: display BEGIN carries auto-on bit4 and paired-WAV bit3");

        // Complete setup enough to make a committed image available, then
        // request D while idle. Hierarchical state setup avoids simulating a
        // full initial image transfer in this focused scheduler test.
        @(negedge clk);
        dut.state=4'd9; dut.receiver_ready=1; dut.committed_valid=1;
        dut.committed_index=5'd4; dut.pc_snapshot_pending=0; dut.pc_snapshot_active=0;
        old_start=start_toggle; pc_snapshot_request=1;
        @(negedge clk); pc_snapshot_request=0;
        wait(start_toggle!=old_start);
        if(!media_to_pc || source_index!=5'd4)
            $fatal(1,"PC snapshot did not select the committed image/PC route");
        @(negedge clk); prepared_toggle=~prepared_toggle;
        wait(tx_request);
        @(negedge clk); tx_ack=1;
        @(negedge clk); tx_ack=0;
        for (i=0;i<16;i=i+1) begin
            if (!tx_valid) $fatal(1,"PC BEGIN packet ended early at byte %0d",i);
            got[i]=tx_data;
            @(negedge clk);
        end
        if(got[10]!=8'd4 || got[11][3] || !media_to_pc)
            $fatal(1,"PC snapshot changed image index, included audio, or lost PC route");
        $display("PASS: D snapshot rereads committed image and suppresses paired audio");

        // The display can attach a reason nibble to RESULT=reject. The sender
        // must still retry, and report checksum reason 4 after its final try.
        @(negedge clk);dut.state=4'd7;dut.frame_id=16'h5678;
        dut.attempts=2'd3;dut.pc_snapshot_active=0;dut.wait_count=0;
        @(negedge clk);rx_data=8'haa;rx_valid=1;
        @(negedge clk);rx_data=8'hbb;
        @(negedge clk);rx_data=8'hcc;
        @(negedge clk);rx_data=8'hdd;
        @(negedge clk);rx_data=8'h24;
        @(negedge clk);rx_data=8'h00;
        @(negedge clk);rx_data=8'h03;
        @(negedge clk);rx_data=8'h00;
        @(negedge clk);rx_data=8'h78;
        @(negedge clk);rx_data=8'h56;
        @(negedge clk);rx_data=8'h14;
        @(negedge clk);rx_valid=0;rx_data=0;
        wait(state_code==4'd9);
        if(error_code!=8'd12)
            $fatal(1,"checksum reject reason was lost: error=%0d",error_code);
        $display("PASS: detailed display reject result is retried and exposed as error 12");

        // An explicit audio RESULT=1 after exhausting retries is distinct from
        // the two-second missing-result timeout (error 6).
        @(negedge clk);dut.state=4'd14;dut.frame_id=16'h1234;
        dut.audio_attempts=2'd3;dut.pc_snapshot_active=0;dut.wait_count=0;
        @(negedge clk);rx_data=8'haa;rx_valid=1;
        @(negedge clk);rx_data=8'hbb;
        @(negedge clk);rx_data=8'hcc;
        @(negedge clk);rx_data=8'hdd;
        @(negedge clk);rx_data=8'h33;
        @(negedge clk);rx_data=8'h00;
        @(negedge clk);rx_data=8'h03;
        @(negedge clk);rx_data=8'h00;
        @(negedge clk);rx_data=8'h34;
        @(negedge clk);rx_data=8'h12;
        @(negedge clk);rx_data=8'h15;
        @(negedge clk);rx_valid=0;rx_data=0;
        wait(state_code==4'd9);
        if(error_code!=8'h75)
            $fatal(1,"audio reject reason was not retained: error=%02x",error_code);
        $display("PASS: exhausted AUDIO_RESULT reason is retained for status");

        // Legacy display firmware uses generic RESULT=1. Keep that path
        // retryable and expose it as reason 0 after exhausting retries.
        @(negedge clk);dut.state=4'd14;dut.frame_id=16'h2234;
        dut.audio_attempts=2'd3;dut.pc_snapshot_active=0;dut.wait_count=0;
        @(negedge clk);rx_data=8'haa;rx_valid=1;
        @(negedge clk);rx_data=8'hbb;
        @(negedge clk);rx_data=8'hcc;
        @(negedge clk);rx_data=8'hdd;
        @(negedge clk);rx_data=8'h33;
        @(negedge clk);rx_data=8'h00;
        @(negedge clk);rx_data=8'h03;
        @(negedge clk);rx_data=8'h00;
        @(negedge clk);rx_data=8'h34;
        @(negedge clk);rx_data=8'h22;
        @(negedge clk);rx_data=8'h01;
        @(negedge clk);rx_valid=0;rx_data=0;
        wait(state_code==4'd9);
        if(error_code!=8'h70)
            $fatal(1,"legacy audio RESULT=1 path failed: error=%02x",error_code);
        $display("PASS: generic legacy audio rejection remains retryable");
        $finish;
    end

    initial begin #200000; $fatal(1,"timeout"); end
endmodule
