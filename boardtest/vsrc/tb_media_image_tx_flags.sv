`timescale 1ns/1ps

module tb_media_image_tx_flags;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg mounted=1, source_busy=0, source_error=0;
    reg [5:0] first_bmp=6'd3;
    reg [191:0] bmp_next=0, bmp_prev=0;
    reg [7:0] cmd=0;
    reg cmd_pending=0, auto_next=0, auto_status=1;
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
    reg [7:0] got [0:15];
    reg [7:0] ready_bytes [0:8];
    integer i;
    reg old_start;

    media_image_tx #(.CLK_HZ(1000), .FRAME_WORDS(1)) dut (
        .clk(clk), .rst(rst),
        .mounted(mounted), .source_busy(source_busy), .source_error(source_error),
        .first_bmp(first_bmp), .bmp_next(bmp_next), .bmp_prev(bmp_prev),
        .cmd(cmd), .cmd_pending(cmd_pending), .auto_next(auto_next), .auto_status(auto_status),
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
        if (tx_length!=16) $fatal(1,"BEGIN packet length");
        @(negedge clk); tx_ack=1;
        @(negedge clk); tx_ack=0;
        for (i=0;i<16;i=i+1) begin
            if (!tx_valid) $fatal(1,"BEGIN packet ended early at byte %0d",i);
            got[i]=tx_data;
            @(negedge clk);
        end
        if ({got[0],got[1],got[2],got[3]} !== 32'haabbccdd) $fatal(1,"bad app header");
        if (got[4]!=8'h21 || got[5]!=0 || got[6]!=8'd8 || got[7]!=0)
            $fatal(1,"bad BEGIN type/length");
        if (got[10]!=8'd3) $fatal(1,"image index not preserved");
        if (!got[11][4] || !got[11][3] || got[11][0])
            $fatal(1,"BEGIN flags mismatch: %02x",got[11]);
        if ({got[15],got[14],got[13],got[12]}!=32'd1)
            $fatal(1,"bad frame word count");
        $display("PASS: BEGIN carries auto-on bit4 and paired-WAV bit3");
        $finish;
    end

    initial begin #200000; $fatal(1,"timeout"); end
endmodule
