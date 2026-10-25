`timescale 1ns/1ps

module tb_media_transaction_writer;
    parameter integer DIRECT_STREAM = 0;
    reg udp_clk = 0;
    reg slow_write_clk = 0;
    wire write_clk=DIRECT_STREAM ? udp_clk : slow_write_clk;
    always #4 udp_clk = ~udp_clk;
    always #5 slow_write_clk = ~slow_write_clk;

    reg udp_rst = 1, write_rst = 1;
    reg frame_begin_valid = 0;
    reg [15:0] frame_id = 16'h1234;
    reg [4:0] image_index = 5'd3;
    reg [7:0] image_flags = 8'h08;
    reg [20:0] image_total_words = 21'd3;
    reg [11:0] image_width=12'd2,image_height=12'd3;
    reg stream_start = 0, stream_is_audio = 0;
    reg [8:0] stream_word_count = 0;
    reg [31:0] stream_word_data = 0;
    reg stream_word_valid = 0;
    wire stream_word_ready;
    reg stream_done = 0;
    reg frame_end_valid = 0, frame_end_ok = 0;
    reg [3:0] frame_end_reason = 0;
    reg [15:0] frame_end_id = 0;
    reg audio_begin_valid = 0;
    reg [15:0] audio_frame_id = 0;
    reg [31:0] audio_sample_count = 0;
    reg audio_end_valid = 0, audio_end_ok = 0;
    reg [3:0] audio_end_reason = 0;
    reg [15:0] audio_end_id = 0;
    reg [1:0] effect_mode = 0;
    reg audio_commit_enable = 1;
    reg transition_done_toggle = 0;
    wire display_valid;
    wire [4:0] image_index_out;
    wire [11:0] image_width_out,image_height_out;
    wire image_has_wav, auto_play_status;
    wire [1:0] display_buffer_index;
    wire transition_start_toggle, transition_target_buf;
    wire [1:0] transition_mode_latched;
    wire transition_prev_latched, frame_commit_pulse;
    wire write_req;
    wire [1:0] write_buffer_index;
    wire [20:0] write_length;
    wire [19:0] write_row_offset;
    wire write_en;
    wire [31:0] write_data;
    wire image_result_valid;
    wire [7:0] image_result_code;
    wire audio_result_valid;
    wire [7:0] audio_result_code;
    wire audio_pair_on;
    wire [1:0] audio_buffer_index;
    wire [20:0] audio_buffer_length;
    wire [31:0] audio_sample_count_out;
    wire audio_source_toggle;

    reg finish_toggle = 0;
    reg [20:0] request_len = 0;
    reg [20:0] written = 0;
    reg request_d = 0;
    reg [1:0] request_buffer = 0;
    reg [31:0] first_frame_word = 0, first_audio_word = 0, second_audio_word = 0;

    media_transaction_writer #(.DIRECT_STREAM(DIRECT_STREAM),.FRAME_WORDS(21'd3)) dut (
        .image_layout(2'd0),.image_window(2'd0),.view_target_buffer(1'b0),.write_layout(),.write_window(),
        .udp_clk(udp_clk), .udp_rst(udp_rst),
        .frame_begin_valid(frame_begin_valid), .frame_id(frame_id),
        .image_index(image_index), .image_flags(image_flags), .image_total_words(image_total_words),
        .image_width(image_width),.image_height(image_height),
        .stream_start(stream_start), .stream_is_audio(stream_is_audio),
        .stream_word_count(stream_word_count), .stream_word_data(stream_word_data),
        .stream_word_valid(stream_word_valid), .stream_word_ready(stream_word_ready),
        .stream_done(stream_done), .frame_end_valid(frame_end_valid), .frame_end_ok(frame_end_ok),
        .frame_end_reason(frame_end_reason), .frame_end_id(frame_end_id),
        .audio_begin_valid(audio_begin_valid),
        .audio_frame_id(audio_frame_id), .audio_sample_count(audio_sample_count),
        .audio_end_valid(audio_end_valid), .audio_end_ok(audio_end_ok),
        .audio_end_reason(audio_end_reason), .audio_end_id(audio_end_id),
        .write_clk(write_clk), .write_rst(write_rst), .frame_finish_toggle(finish_toggle),
        .effect_mode(effect_mode), .audio_commit_enable(audio_commit_enable),
        .transition_done_toggle(transition_done_toggle),
        .display_valid(display_valid), .image_index_out(image_index_out),
        .image_width_out(image_width_out),.image_height_out(image_height_out),
        .image_has_wav(image_has_wav), .auto_play_status(auto_play_status),
        .display_buffer_index(display_buffer_index), .transition_start_toggle(transition_start_toggle),
        .transition_target_buf(transition_target_buf), .transition_mode_latched(transition_mode_latched),
        .transition_prev_latched(transition_prev_latched), .frame_commit_pulse(frame_commit_pulse),
        .write_req(write_req), .write_req_ack(write_req), .write_ready(1'b1), .write_buffer_index(write_buffer_index),
        .write_length(write_length), .write_row_offset(write_row_offset),
        .write_en(write_en), .write_data(write_data),
        .image_result_valid(image_result_valid), .image_result_code(image_result_code),
        .audio_result_valid(audio_result_valid), .audio_result_code(audio_result_code),
        .audio_pair_on(audio_pair_on), .audio_buffer_index(audio_buffer_index),
        .audio_buffer_length(audio_buffer_length), .audio_sample_count_out(audio_sample_count_out),
        .audio_source_toggle(audio_source_toggle)
    );

    always @(posedge write_clk) begin
        request_d <= write_req;
        if (write_req && !request_d) begin
            request_len <= write_length;
            request_buffer <= write_buffer_index;
            written <= 0;
        end
        if (write_en) begin
            if (request_buffer == 2'd0 && written == 0) first_frame_word <= write_data;
            if (request_buffer == 2'd2 && written == 0) first_audio_word <= write_data;
            if (request_buffer == 2'd2 && written == 1) second_audio_word <= write_data;
            written <= written + 21'd1;
            if (written + 21'd1 == request_len)
                finish_toggle <= ~finish_toggle;
        end
    end

    reg got_image_accept = 0, got_audio_accept = 0, got_image_commit = 0;
    integer image_accept_count=0,audio_accept_count=0,image_commit_count=0;
    always @(posedge udp_clk) begin
        if (image_result_valid && image_result_code == 8'd0) begin
            got_image_accept <= 1;image_accept_count<=image_accept_count+1;
        end
        if (audio_result_valid && audio_result_code == 8'd0) begin
            got_audio_accept <= 1;audio_accept_count<=audio_accept_count+1;
        end
        if (image_result_valid && image_result_code == 8'd2) begin
            got_image_commit <= 1;image_commit_count<=image_commit_count+1;
        end
    end

    task automatic send_word(input [31:0] value, input is_audio);
        begin
            @(negedge udp_clk);
            stream_is_audio = is_audio;
            stream_word_data = value;
            stream_word_valid = 1;
            while (!stream_word_ready) @(negedge udp_clk);
            @(negedge udp_clk);
            stream_word_valid = 0;
        end
    endtask

    task automatic commit_silent_image(input [15:0] id,input [4:0] index_value);
        integer old_accept,old_audio,old_commit;
        begin
            old_accept=image_accept_count;old_audio=audio_accept_count;old_commit=image_commit_count;
            @(negedge udp_clk);
            frame_id=id;image_index=index_value;image_flags=0;frame_begin_valid=1;
            @(negedge udp_clk);frame_begin_valid=0;
            send_word(32'h01020304,1'b0);
            send_word(32'h05060708,1'b0);
            send_word(32'h090a0b0c,1'b0);
            repeat(5)@(negedge udp_clk);
            frame_end_id=id;frame_end_ok=1;frame_end_valid=1;
            @(negedge udp_clk);frame_end_valid=0;
            wait(image_accept_count>old_accept);

            @(negedge udp_clk);audio_frame_id=id;audio_sample_count=0;audio_begin_valid=1;
            @(negedge udp_clk);audio_begin_valid=0;
            repeat(5)@(negedge udp_clk);
            audio_end_id=id;audio_end_ok=1;audio_end_valid=1;
            @(negedge udp_clk);audio_end_valid=0;
            wait(audio_accept_count>old_audio);
            wait(image_commit_count>old_commit);
        end
    endtask

    initial begin
        repeat (5) @(negedge udp_clk);
        udp_rst = 0; write_rst = 0;
        @(negedge udp_clk); frame_begin_valid = 1;
        @(negedge udp_clk); frame_begin_valid = 0;
        send_word(32'h11223344, 1'b0);
        send_word(32'h55667788, 1'b0);
        send_word(32'hdeadbeef, 1'b0);
        repeat (5) @(negedge udp_clk);
        frame_end_id = 16'h1234; frame_end_ok = 1; frame_end_valid = 1;
        @(negedge udp_clk); frame_end_valid = 0;
        wait (got_image_accept);

        @(negedge udp_clk); audio_frame_id = 16'h1234; audio_sample_count = 5;
        audio_begin_valid = 1;
        @(negedge udp_clk); audio_begin_valid = 0;
        send_word(32'h20ff0080, 1'b1);
        send_word(32'h8080807f, 1'b1);
        repeat (5) @(negedge udp_clk);
        audio_end_id = 16'h1234; audio_end_ok = 1; audio_end_valid = 1;
        @(negedge udp_clk); audio_end_valid = 0;
        wait (got_audio_accept && got_image_commit);
        if (!display_valid || image_index_out != 5'd3 || !image_has_wav ||
            image_width_out != 12'd2 || image_height_out != 12'd3 ||
            !audio_pair_on || audio_buffer_index != 2'd2 ||
            audio_buffer_length != 21'd256 || audio_sample_count_out != 32'd5)
            $fatal(1, "commit metadata mismatch");
        if (first_frame_word != 32'h11223344 || first_audio_word != 32'h20ff0080 ||
            second_audio_word != 32'h8080807f || request_buffer != 2'd2 ||
            request_len != 21'd256)
            $fatal(1, "SDRAM write stream mismatch");

        // Layout changes must keep the currently playing source and sample
        // position metadata. A later single-layout image without a WAV silences it.
        begin : audio_layout_policy
            reg held_toggle;
            reg [1:0] held_playback_buffer;
            held_toggle=audio_source_toggle;held_playback_buffer=dut.committed_audio_buffer;
            audio_commit_enable=0;
            commit_silent_image(16'h1235,5'd4);
            if(!audio_pair_on || !image_has_wav || audio_source_toggle!=held_toggle ||
               dut.committed_audio_buffer!=held_playback_buffer || !dut.committed_audio_pair ||
               dut.audio_target_index!=3)
                $fatal(1,"layout-only image commit disturbed the active audio source");

            audio_commit_enable=1;
            commit_silent_image(16'h1236,5'd5);
            if(audio_pair_on || image_has_wav || audio_sample_count_out!=0 ||
               audio_buffer_length!=0 || audio_source_toggle==held_toggle)
                $fatal(1,"single-layout image without WAV did not commit silence");
        end
        $display("PASS: image/PCM commit and layout-only audio-source retention");
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1, "timeout");
    end
endmodule
