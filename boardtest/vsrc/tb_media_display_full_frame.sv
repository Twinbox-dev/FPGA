`timescale 1ns/1ps

// Full 1280x720 image transaction through the real variable-frame parser,
// display pad, SDRAM transaction writer, and display UDP result transmitter.
module tb_media_display_full_frame;
    parameter integer DIRECT_STREAM = 0;
    parameter integer IMAGE_WIDTH = 1280;
    parameter integer IMAGE_HEIGHT = 720;
    parameter integer TOTAL_WORDS = (IMAGE_WIDTH * IMAGE_HEIGHT + 1) / 2;
    localparam [11:0] IMAGE_WIDTH_12 = IMAGE_WIDTH[11:0];
    localparam [11:0] IMAGE_HEIGHT_12 = IMAGE_HEIGHT[11:0];
    localparam integer CANVAS_WORDS = 460800;
    localparam [31:0] PIXEL_WORD = 32'h01234567;
    localparam [31:0] FRAME_SUM = PIXEL_WORD * TOTAL_WORDS;

    reg udp_clk = 0, slow_write_clk = 0;
    wire write_clk=DIRECT_STREAM ? udp_clk : slow_write_clk;
    always #4 udp_clk = ~udp_clk;
    always #5 slow_write_clk = ~slow_write_clk;
    reg rst = 1;
    reg [7:0] rx_data = 0;
    reg rx_valid = 0;

    wire ready_request, frame_begin_valid;
    wire [15:0] frame_id, frame_end_id;
    wire [4:0] image_index;
    wire [7:0] image_flags;
    wire [20:0] image_total_words;
    wire [11:0] image_width, image_height;
    wire stream_start, stream_is_audio, stream_word_valid, stream_done;
    wire [8:0] stream_word_count;
    wire [31:0] stream_word_data;
    wire raw_stream_ready;
    wire padded_stream_start, padded_stream_audio, padded_stream_valid, padded_stream_ready, padded_stream_done;
    wire [8:0] padded_stream_count;
    wire [31:0] padded_stream_data;
    wire pad_frame_done;
    wire frame_end_valid, frame_end_ok;
    wire [3:0] frame_end_reason;
    wire audio_begin_valid, audio_end_valid, audio_end_ok;
    wire [15:0] audio_frame_id, audio_end_id;
    wire [31:0] audio_sample_count;
    wire [3:0] audio_end_reason;
    wire protocol_error_toggle;

    wire display_valid, image_has_wav, auto_play_status;
    wire [4:0] image_index_out;
    wire [11:0] image_width_out, image_height_out;
    wire [1:0] display_buffer_index;
    wire transition_start_toggle, transition_target_buf, transition_prev_latched;
    wire [1:0] transition_mode_latched;
    wire frame_commit_pulse, write_req, write_en;
    wire [1:0] write_buffer_index;
    wire [20:0] write_length;
    wire [19:0] write_row_offset;
    wire [31:0] write_data;
    wire image_result_valid, audio_result_valid;
    wire [7:0] image_result_code, audio_result_code;
    wire audio_pair_on;
    wire [1:0] audio_buffer_index;
    wire [20:0] audio_buffer_length;
    wire [31:0] audio_sample_count_out;
    wire audio_source_toggle;

    reg finish_toggle = 0;
    reg request_d = 0;
    reg [20:0] requested_words = 0, written_words = 0;
    reg [1:0] requested_buffer = 0;
    reg [31:0] stream_done_count = 0;
    reg [31:0] frame_end_count = 0;
    reg frame_end_good_last = 0;
    reg [3:0] frame_end_reason_last = 0;
    integer written_mismatch_count = 0;

    media_protocol_rx u_rx (
        .clk(udp_clk), .rst(rst), .rx_data(rx_data), .rx_valid(rx_valid),
        .ready_request(ready_request), .frame_begin_valid(frame_begin_valid),
        .frame_id(frame_id), .image_index(image_index), .image_flags(image_flags),
        .image_total_words(image_total_words), .image_width(image_width), .image_height(image_height),
        .image_layout(), .image_window(), .image_generation(),
        .stream_start(stream_start), .stream_is_audio(stream_is_audio),
        .stream_word_count(stream_word_count), .stream_word_data(stream_word_data),
        .stream_word_valid(stream_word_valid), .stream_word_ready(raw_stream_ready),
        .stream_done(stream_done), .frame_end_valid(frame_end_valid),
        .frame_end_ok(frame_end_ok), .frame_end_reason(frame_end_reason), .frame_end_id(frame_end_id),
        .audio_begin_valid(audio_begin_valid), .audio_frame_id(audio_frame_id),
        .audio_sample_count(audio_sample_count), .audio_end_valid(audio_end_valid),
        .audio_end_ok(audio_end_ok), .audio_end_reason(audio_end_reason), .audio_end_id(audio_end_id),
        .protocol_error_toggle(protocol_error_toggle)
    );

    media_frame_pad u_pad (
        .layout(2'd0),
        .clk(udp_clk), .rst(rst), .frame_begin(frame_begin_valid),
        .image_width(image_width), .image_height(image_height), .frame_end(frame_end_valid),
        .in_is_audio(stream_is_audio), .in_start(stream_start), .in_count(stream_word_count),
        .in_data(stream_word_data), .in_valid(stream_word_valid), .in_ready(raw_stream_ready),
        .in_done(stream_done), .out_start(padded_stream_start), .out_is_audio(padded_stream_audio),
        .out_count(padded_stream_count), .out_data(padded_stream_data), .out_valid(padded_stream_valid),
        .out_ready(padded_stream_ready), .out_done(padded_stream_done), .frame_done(pad_frame_done)
    );

    media_transaction_writer #(.DIRECT_STREAM(DIRECT_STREAM)) u_writer (
        .image_layout(2'd0),.image_window(2'd0),.view_target_buffer(1'b0),.write_layout(),.write_window(),
        .udp_clk(udp_clk), .udp_rst(rst), .frame_begin_valid(frame_begin_valid),
        .frame_id(frame_id), .image_index(image_index), .image_flags(image_flags),
        .image_total_words(image_total_words), .image_width(image_width), .image_height(image_height),
        .stream_start(padded_stream_start), .stream_is_audio(padded_stream_audio),
        .stream_word_count(padded_stream_count), .stream_word_data(padded_stream_data),
        .stream_word_valid(padded_stream_valid), .stream_word_ready(padded_stream_ready),
        .stream_done(padded_stream_done), .frame_end_valid(frame_end_valid),
        .frame_end_ok(frame_end_ok), .frame_end_reason(frame_end_reason), .frame_end_id(frame_end_id),
        .audio_begin_valid(audio_begin_valid), .audio_frame_id(audio_frame_id),
        .audio_sample_count(audio_sample_count), .audio_end_valid(audio_end_valid),
        .audio_end_ok(audio_end_ok), .audio_end_reason(audio_end_reason), .audio_end_id(audio_end_id),
        .write_clk(write_clk), .write_rst(rst), .frame_finish_toggle(finish_toggle),
        .effect_mode(2'd0), .audio_commit_enable(1'b1), .transition_done_toggle(1'b0),
        .display_valid(display_valid), .image_index_out(image_index_out),
        .image_width_out(image_width_out), .image_height_out(image_height_out),
        .image_has_wav(image_has_wav), .auto_play_status(auto_play_status),
        .display_buffer_index(display_buffer_index), .transition_start_toggle(transition_start_toggle),
        .transition_target_buf(transition_target_buf), .transition_mode_latched(transition_mode_latched),
        .transition_prev_latched(transition_prev_latched), .frame_commit_pulse(frame_commit_pulse),
        .write_req(write_req), .write_req_ack(write_req), .write_ready(1'b1), .write_buffer_index(write_buffer_index),
        .write_length(write_length), .write_row_offset(write_row_offset), .write_en(write_en),
        .write_data(write_data), .image_result_valid(image_result_valid),
        .image_result_code(image_result_code), .audio_result_valid(audio_result_valid),
        .audio_result_code(audio_result_code), .audio_pair_on(audio_pair_on),
        .audio_buffer_index(audio_buffer_index), .audio_buffer_length(audio_buffer_length),
        .audio_sample_count_out(audio_sample_count_out), .audio_source_toggle(audio_source_toggle)
    );

    wire tx_request, tx_valid, tx_ack;
    wire [7:0] tx_data;
    wire [15:0] tx_length;
    reg [7:0] packet_type [0:7];
    reg [7:0] packet_first_payload [0:7];
    reg [7:0] packet_result [0:7];
    integer tx_packet_count = 0, tx_byte_count = 0;
    reg tx_in_packet = 0;

    media_display_tx #(.TX_GAP_CYCLES(4)) u_display_tx (
        .view_busy(1'b0),.view_prepare_valid(1'b0),.view_prepare_body(64'd0),.view_status_valid(1'b0),.view_status_body(128'd0),
        .clk(udp_clk), .rst(rst), .local_cmd_toggle_async(1'b0), .local_cmd_async(8'd0),
        .ready_valid(ready_request), .image_result_valid(image_result_valid),
        .image_result_code(image_result_code), .image_result_frame(frame_id),
        .audio_result_valid(audio_result_valid), .audio_result_code(audio_result_code),
        .audio_result_frame(frame_id), .control_ack_valid(1'b0), .control_ack_sequence(8'd0),
        .control_ack_op(8'd0), .control_ack_status(8'd0), .control_ack_value(8'd0),
        .status_valid(1'b0), .status_payload(64'd0), .tx_request(tx_request), .tx_valid(tx_valid),
        .tx_data(tx_data), .tx_length(tx_length), .tx_to_source(), .tx_to_owner(),
        .tx_ready(1'b1), .tx_ack(tx_ack)
    );
    assign tx_ack = tx_request;

    always @(posedge udp_clk) begin
        if (stream_done) stream_done_count = stream_done_count + 1;
        if (frame_end_valid) begin
            frame_end_count = frame_end_count + 1;
            frame_end_good_last = frame_end_ok;
            frame_end_reason_last = frame_end_reason;
        end
        if (tx_valid) begin
            if (tx_byte_count == 4) packet_type[tx_packet_count] = tx_data;
            if (tx_byte_count == 8) packet_first_payload[tx_packet_count] = tx_data;
            if (tx_byte_count == 10) packet_result[tx_packet_count] = tx_data;
            tx_byte_count = tx_byte_count + 1;
            tx_in_packet = 1;
        end else if (tx_in_packet) begin
            tx_packet_count = tx_packet_count + 1;
            tx_byte_count = 0;
            tx_in_packet = 0;
        end
    end

    always @(posedge write_clk) begin
        request_d <= write_req;
        if (write_req && !request_d) begin
            requested_words <= write_length;
            requested_buffer <= write_buffer_index;
            written_words <= 0;
        end
        if (write_en) begin
            if (IMAGE_WIDTH == 1280 && written_words < 8 && write_data != PIXEL_WORD)
                written_mismatch_count <= written_mismatch_count + 1;
            if (IMAGE_WIDTH == 504 && written_words < 8 && write_data != 0)
                written_mismatch_count <= written_mismatch_count + 1;
            if (IMAGE_WIDTH == 504 && written_words == 194 && write_data != PIXEL_WORD)
                written_mismatch_count <= written_mismatch_count + 1;
            written_words <= written_words + 1;
            if (written_words + 1 == requested_words)
                finish_toggle <= ~finish_toggle;
        end
    end

    task automatic send_byte(input [7:0] value);
        begin @(negedge udp_clk); rx_data = value; rx_valid = 1'b1; end
    endtask
    task automatic close_packet;
        begin @(negedge udp_clk); rx_valid = 1'b0; rx_data = 0; repeat(4) @(negedge udp_clk); end
    endtask
    task automatic send_header(input [7:0] kind, input [15:0] payload_len);
        begin
            send_byte(8'haa); send_byte(8'hbb); send_byte(8'hcc); send_byte(8'hdd);
            send_byte(kind); send_byte(0); send_byte(payload_len[7:0]); send_byte(payload_len[15:8]);
        end
    endtask

    integer seq, words_left, words_this_packet, k, watchdog, packet_watchdog;
    reg [31:0] done_count_before;
    initial begin
        repeat(5) @(negedge udp_clk);
        rst = 0;
        send_header(8'h20, 0);
        close_packet();
        wait(tx_packet_count >= 1);
        if (packet_type[0] != 8'h20 || packet_first_payload[0] != 1)
            $fatal(1, "display READY response mismatch");

        send_header(8'h21, 16);
        send_byte(8'h34); send_byte(8'h12);       // frame_id = 0x1234
        send_byte(8'd3); send_byte(0);            // image index, flags
        send_byte(TOTAL_WORDS[7:0]); send_byte(TOTAL_WORDS[15:8]);
        send_byte(TOTAL_WORDS[23:16]); send_byte(TOTAL_WORDS[31:24]);
        send_byte(IMAGE_WIDTH_12[7:0]); send_byte({4'd0,IMAGE_WIDTH_12[11:8]});
        send_byte(IMAGE_HEIGHT_12[7:0]); send_byte({4'd0,IMAGE_HEIGHT_12[11:8]});
        send_byte(0); send_byte(0);               // layout, window
        send_byte(0); send_byte(0);               // generation
        close_packet();

        words_left = TOTAL_WORDS;
        seq = 0;
        while (words_left > 0) begin
            words_this_packet = (words_left > 253) ? 253 : words_left;
            done_count_before = stream_done_count;
            send_header(8'h22, 16'(4 + words_this_packet * 4));
            send_byte(8'h34); send_byte(8'h12);
            send_byte(seq[7:0]); send_byte(seq[15:8]);
            for (k = 0; k < words_this_packet; k = k + 1) begin
                send_byte(PIXEL_WORD[7:0]); send_byte(PIXEL_WORD[15:8]);
                send_byte(PIXEL_WORD[23:16]); send_byte(PIXEL_WORD[31:24]);
            end
            close_packet();
            packet_watchdog = 0;
            while (stream_done_count == done_count_before && packet_watchdog < 10000) begin
                @(negedge udp_clk);
                packet_watchdog = packet_watchdog + 1;
            end
            if (stream_done_count == done_count_before)
                $fatal(1, "DATA seq=%0d did not drain: rx_active=%0d bad=%0d rx_words=%0d/%0d pad_active=%0d pad_xy=%0d,%0d source_word_valid=%0d",
                       seq, u_rx.frame_active, u_rx.frame_bad, u_rx.received_image_words,
                       u_rx.image_total_words, u_pad.frame_active, u_pad.x, u_pad.y,
                       u_pad.source_word_valid);
            words_left = words_left - words_this_packet;
            seq = seq + 1;
        end

        send_header(8'h23, 8);
        send_byte(8'h34); send_byte(8'h12);
        send_byte(FRAME_SUM[7:0]); send_byte(FRAME_SUM[15:8]);
        send_byte(FRAME_SUM[23:16]); send_byte(FRAME_SUM[31:24]);
        send_byte(0); send_byte(0);
        close_packet();

        // The production media sender waits for image RESULT=0 before starting
        // the audio/silence half of the transaction.
        wait(tx_packet_count >= 2);
        if (packet_type[1] != 8'h24 || packet_result[1] != 0)
            $fatal(1, "display did not accept the full image before audio: type=%02x result=%02x",
                   packet_type[1], packet_result[1]);

        // The production sender always closes an audio transaction after the
        // image: zero samples is the explicit silent/no-WAV case.
        send_header(8'h30, 8);
        send_byte(8'h34); send_byte(8'h12);
        send_byte(0); send_byte(0); send_byte(0); send_byte(0);
        send_byte(0); send_byte(0);
        close_packet();
        send_header(8'h32, 8);
        send_byte(8'h34); send_byte(8'h12);
        send_byte(0); send_byte(0); send_byte(0); send_byte(0);
        send_byte(0); send_byte(0);
        close_packet();

        watchdog = 0;
        while ((tx_packet_count < 4 || !display_valid || written_words != CANVAS_WORDS) && watchdog < 12000000) begin
            @(negedge udp_clk);
            watchdog = watchdog + 1;
        end
        if (watchdog >= 12000000)
            $fatal(1, "timeout: end_ok=%0d reason=%0d words=%0d/%0d written=%0d packets=%0d",
                   frame_end_good_last, frame_end_reason_last, u_rx.received_image_words,
                   image_total_words, written_words, tx_packet_count);
        if (frame_end_count != 1 || !frame_end_good_last || frame_end_reason_last != 0)
            $fatal(1, "frame END rejected: count=%0d good=%0d reason=%0d",
                   frame_end_count, frame_end_good_last, frame_end_reason_last);
        if (tx_packet_count < 4 || packet_type[1] != 8'h24 || packet_result[1] != 0 ||
            packet_type[2] != 8'h33 || packet_result[2] != 0 ||
            packet_type[3] != 8'h24 || packet_result[3] != 2)
            $fatal(1, "image/audio result order mismatch: pkts=%0d types=%h/%h/%h results=%h/%h/%h",
                   tx_packet_count, packet_type[1], packet_type[2], packet_type[3],
                   packet_result[1], packet_result[2], packet_result[3]);
        if (!display_valid || image_index_out != 3 || image_width_out != IMAGE_WIDTH_12 || image_height_out != IMAGE_HEIGHT_12)
            $fatal(1, "committed display metadata mismatch: valid=%0d idx=%0d size=%0dx%0d",
                   display_valid, image_index_out, image_width_out, image_height_out);
        if (written_words != CANVAS_WORDS || written_mismatch_count != 0)
            $fatal(1, "SDRAM writes/padding mismatch: words=%0d expected=%0d mismatches=%0d",
                   written_words, CANVAS_WORDS, written_mismatch_count);

        $display("PASS: %0dx%0d BEGIN/DATA/END validates, writes %0d canvas words, replies RESULT 0 then RESULT 2",
                 IMAGE_WIDTH, IMAGE_HEIGHT, written_words);
        $finish;
    end

    initial begin
        #100000000;
        $fatal(1, "full-frame display path timeout: begin=%0d end=%0d end_good=%0d rx_active=%0d rx_bad=%0d rx_words=%0d/%0d pad_active=%0d pad_xy=%0d,%0d done=%0d writer=%0d issued=%0d written=%0d result=%0d/%0d packets=%0d",
               frame_begin_valid, frame_end_count, frame_end_good_last, u_rx.frame_active,
               u_rx.frame_bad, u_rx.received_image_words, u_rx.image_total_words,
               u_pad.frame_active, u_pad.x, u_pad.y, stream_done_count, u_writer.writer_state,
               u_writer.frame_words_issued, written_words, image_result_valid, image_result_code,
               tx_packet_count);
    end
endmodule
