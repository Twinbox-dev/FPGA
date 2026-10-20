`timescale 1ns/1ps

module tb_media_transaction_writer;
    reg udp_clk = 0;
    reg write_clk = 0;
    always #4 udp_clk = ~udp_clk;
    always #5 write_clk = ~write_clk;

    reg udp_rst = 1, write_rst = 1;
    reg frame_begin_valid = 0;
    reg [15:0] frame_id = 16'h1234;
    reg [4:0] image_index = 5'd3;
    reg [7:0] image_flags = 8'h08;
    reg [20:0] image_total_words = 21'd3;
    reg stream_start = 0, stream_is_audio = 0;
    reg [8:0] stream_word_count = 0;
    reg [31:0] stream_word_data = 0;
    reg stream_word_valid = 0;
    wire stream_word_ready;
    reg stream_done = 0;
    reg frame_end_valid = 0, frame_end_ok = 0;
    reg [15:0] frame_end_id = 0;
    reg audio_begin_valid = 0;
    reg [15:0] audio_frame_id = 0;
    reg [31:0] audio_sample_count = 0;
    reg audio_end_valid = 0, audio_end_ok = 0;
    reg [15:0] audio_end_id = 0;
    reg [1:0] effect_mode = 0;
    reg transition_done_toggle = 0;
    wire display_valid;
    wire [4:0] image_index_out;
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

    media_transaction_writer #(.FRAME_WORDS(21'd3)) dut (
        .udp_clk(udp_clk), .udp_rst(udp_rst),
        .frame_begin_valid(frame_begin_valid), .frame_id(frame_id),
        .image_index(image_index), .image_flags(image_flags), .image_total_words(image_total_words),
        .stream_start(stream_start), .stream_is_audio(stream_is_audio),
        .stream_word_count(stream_word_count), .stream_word_data(stream_word_data),
        .stream_word_valid(stream_word_valid), .stream_word_ready(stream_word_ready),
        .stream_done(stream_done), .frame_end_valid(frame_end_valid), .frame_end_ok(frame_end_ok),
        .frame_end_id(frame_end_id), .audio_begin_valid(audio_begin_valid),
        .audio_frame_id(audio_frame_id), .audio_sample_count(audio_sample_count),
        .audio_end_valid(audio_end_valid), .audio_end_ok(audio_end_ok), .audio_end_id(audio_end_id),
        .write_clk(write_clk), .write_rst(write_rst), .frame_finish_toggle(finish_toggle),
        .effect_mode(effect_mode), .transition_done_toggle(transition_done_toggle),
        .display_valid(display_valid), .image_index_out(image_index_out),
        .image_has_wav(image_has_wav), .auto_play_status(auto_play_status),
        .display_buffer_index(display_buffer_index), .transition_start_toggle(transition_start_toggle),
        .transition_target_buf(transition_target_buf), .transition_mode_latched(transition_mode_latched),
        .transition_prev_latched(transition_prev_latched), .frame_commit_pulse(frame_commit_pulse),
        .write_req(write_req), .write_req_ack(write_req), .write_buffer_index(write_buffer_index),
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
    always @(posedge udp_clk) begin
        if (image_result_valid && image_result_code == 8'd0) got_image_accept <= 1;
        if (audio_result_valid && audio_result_code == 8'd0) got_audio_accept <= 1;
        if (image_result_valid && image_result_code == 8'd2) got_image_commit <= 1;
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
            !audio_pair_on || audio_buffer_index != 2'd2 ||
            audio_buffer_length != 21'd256 || audio_sample_count_out != 32'd5)
            $fatal(1, "commit metadata mismatch");
        if (first_frame_word != 32'h11223344 || first_audio_word != 32'h20ff0080 ||
            second_audio_word != 32'h8080807f || request_buffer != 2'd2 ||
            request_len != 21'd256)
            $fatal(1, "SDRAM write stream mismatch");
        $display("PASS: image and aligned PCM writes complete before display commit");
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1, "timeout");
    end
endmodule
