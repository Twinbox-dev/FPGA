`timescale 1ns/1ps

// Receives validated image/PCM words from media_protocol_rx, stages the two
// streams through small async BRAM FIFOs, and writes the V1 four-region SDRAM
// layout. Image and audio writes are serialized on frame_read_write's single
// write port. A new image is committed only after image and optional audio
// END checks pass and the new audio buffer has been written.
module media_transaction_writer #(
    parameter [20:0] FRAME_WORDS = 21'd460800,
    parameter [20:0] AUDIO_REGION_WORDS = 21'd587776
)(
    input  wire        udp_clk,
    input  wire        udp_rst,
    input  wire        frame_begin_valid,
    input  wire [15:0] frame_id,
    input  wire [4:0]  image_index,
    input  wire [7:0]  image_flags,
    input  wire [20:0] image_total_words,
    input  wire        stream_start,
    input  wire        stream_is_audio,
    input  wire [8:0]  stream_word_count,
    input  wire [31:0] stream_word_data,
    input  wire        stream_word_valid,
    output wire        stream_word_ready,
    input  wire        stream_done,
    input  wire        frame_end_valid,
    input  wire        frame_end_ok,
    input  wire [3:0]  frame_end_reason,
    input  wire [15:0] frame_end_id,
    input  wire        audio_begin_valid,
    input  wire [15:0] audio_frame_id,
    input  wire [31:0] audio_sample_count,
    input  wire        audio_end_valid,
    input  wire        audio_end_ok,
    input  wire [15:0] audio_end_id,

    input  wire        write_clk,
    input  wire        write_rst,
    input  wire        frame_finish_toggle,
    input  wire [1:0]  effect_mode,
    input  wire        transition_done_toggle,
    output reg         display_valid,
    output reg  [4:0]  image_index_out,
    output reg         image_has_wav,
    output reg         auto_play_status,
    output reg  [1:0]  display_buffer_index,
    output reg         transition_start_toggle,
    output reg         transition_target_buf,
    output reg  [1:0]  transition_mode_latched,
    output reg         transition_prev_latched,
    output reg         frame_commit_pulse,

    output reg         write_req,
    input  wire        write_req_ack,
    output wire [1:0]  write_buffer_index,
    output wire [20:0] write_length,
    output wire [19:0] write_row_offset,
    output reg         write_en,
    output reg  [31:0] write_data,

    output reg         image_result_valid,
    output reg  [7:0]  image_result_code,
    output reg         audio_result_valid,
    output reg  [7:0]  audio_result_code,
    output wire        audio_pair_on,
    output reg  [1:0]  audio_buffer_index,
    output reg  [20:0] audio_buffer_length,
    output reg  [31:0] audio_sample_count_out,
    output reg         audio_source_toggle
);
    localparam [1:0] W_IDLE=2'd0, W_REQ=2'd1, W_ACTIVE=2'd2;

    reg [31:0] image_meta_udp;
    reg [15:0] image_id_udp, image_end_id_udp, audio_id_udp, audio_end_id_udp;
    reg image_end_good_udp, audio_end_good_udp;
    reg [3:0] image_end_reason_udp;
    reg [31:0] audio_samples_udp;
    reg image_begin_toggle_udp, image_end_toggle_udp;
    reg audio_begin_toggle_udp, audio_end_toggle_udp;
    reg [2:0] image_begin_sync, image_end_sync, audio_begin_sync, audio_end_sync;
    reg [2:0] finish_sync, transition_sync;
    reg [2:0] image_result_sync, audio_result_sync;
    reg image_result_toggle_w, audio_result_toggle_w;
    reg [7:0] image_result_code_w, audio_result_code_w;
    wire image_begin_event = image_begin_sync[2] ^ image_begin_sync[1];
    wire image_end_event = image_end_sync[2] ^ image_end_sync[1];
    wire audio_begin_event = audio_begin_sync[2] ^ audio_begin_sync[1];
    wire audio_end_event = audio_end_sync[2] ^ audio_end_sync[1];
    wire finish_event = finish_sync[2] ^ finish_sync[1];
    wire transition_event = transition_sync[2] ^ transition_sync[1];

    reg [1:0] writer_state;
    reg write_audio_mode;
    reg [1:0] frame_target_index, audio_target_index;
    reg [20:0] audio_target_length;
    reg [20:0] audio_data_words;
    reg [20:0] frame_words_issued, audio_words_popped, audio_words_written;
    reg frame_read_pending, audio_read_pending;
    reg frame_write_done, audio_write_done;
    reg frame_active_w, frame_end_seen_w, frame_end_good_w, frame_result_sent_w;
    reg [3:0] frame_end_reason_w;
    reg audio_active_w, audio_end_seen_w, audio_end_good_w, audio_result_sent_w;
    reg audio_retry_pending_w, audio_no_data_w;
    reg commit_pending_w, transition_pending_w, transition_done_seen_w;
    reg [15:0] pending_frame_id_w;
    reg [4:0] pending_image_index_w;
    reg pending_wav_w, pending_prev_w, pending_auto_w;
    reg [1:0] pending_frame_buffer_w;
    reg [1:0] pending_audio_buffer_w;
    reg [20:0] pending_audio_length_w;
    reg [31:0] pending_audio_samples_w;
    reg [4:0] transition_image_index_w;
    reg transition_image_wav_w, transition_image_auto_w;
    reg [1:0] transition_image_buffer_w, transition_audio_buffer_w;
    reg [20:0] transition_audio_length_w;
    reg [31:0] transition_audio_samples_w;

    wire frame_fifo_full, frame_fifo_empty;
    wire [31:0] frame_fifo_data;
    wire [9:0] frame_fifo_avail;
    wire audio_fifo_full, audio_fifo_empty;
    wire [31:0] audio_fifo_data;
    wire [9:0] audio_fifo_avail;
    wire frame_fifo_pop = (writer_state == W_ACTIVE) && !write_audio_mode &&
                          !frame_fifo_empty && frame_words_issued < FRAME_WORDS;
    wire audio_fifo_pop = (writer_state == W_ACTIVE) && write_audio_mode &&
                          !audio_fifo_empty && audio_words_popped < audio_data_words;
    wire frame_fifo_push = stream_word_valid && stream_word_ready && !stream_is_audio;
    wire audio_fifo_push = stream_word_valid && stream_word_ready && stream_is_audio;
    wire frame_pad = (writer_state == W_ACTIVE) && !write_audio_mode &&
                     frame_end_seen_w && !frame_end_good_w && frame_fifo_empty &&
                     !frame_read_pending && frame_words_issued < FRAME_WORDS;
    wire audio_pad = (writer_state == W_ACTIVE) && write_audio_mode && audio_end_seen_w &&
                     audio_fifo_empty && !audio_read_pending &&
                     audio_words_written < audio_target_length;

    assign stream_word_ready = stream_is_audio ? !audio_fifo_full : !frame_fifo_full;
    assign write_buffer_index = write_audio_mode ? audio_target_index : frame_target_index;
    assign write_length = write_audio_mode ? audio_target_length : FRAME_WORDS;
    assign write_row_offset = 20'd0;
    assign audio_pair_on = display_valid && image_has_wav && audio_buffer_length != 0;

    tap_afifo #(.AW(9), .DW(32)) u_frame_rx_fifo (
        .wr_clk(udp_clk), .wr_rst(udp_rst), .wr_en(frame_fifo_push),
        .wr_data(stream_word_data), .wr_full(frame_fifo_full),
        .rd_clk(write_clk), .rd_rst(write_rst), .rd_en(frame_fifo_pop),
        .rd_data(frame_fifo_data), .rd_empty(frame_fifo_empty), .rd_avail(frame_fifo_avail)
    );
    tap_afifo #(.AW(9), .DW(32)) u_audio_rx_fifo (
        .wr_clk(udp_clk), .wr_rst(udp_rst), .wr_en(audio_fifo_push),
        .wr_data(stream_word_data), .wr_full(audio_fifo_full),
        .rd_clk(write_clk), .rd_rst(write_rst), .rd_en(audio_fifo_pop),
        .rd_data(audio_fifo_data), .rd_empty(audio_fifo_empty), .rd_avail(audio_fifo_avail)
    );

    function [20:0] aligned_audio_words;
        input [31:0] samples;
        reg [21:0] rounded_samples;
        reg [20:0] words;
        begin
            rounded_samples = samples[21:0] + 22'd3;
            words = {1'b0, rounded_samples[21:2]};
            aligned_audio_words = (words + 21'd255) & 21'h1fff00;
        end
    endfunction

    function [20:0] audio_data_word_count;
        input [31:0] samples;
        reg [21:0] rounded_samples;
        begin
            rounded_samples = samples[21:0] + 22'd3;
            audio_data_word_count = {1'b0, rounded_samples[21:2]};
        end
    endfunction

    always @(posedge udp_clk or posedge udp_rst) begin
        if (udp_rst) begin
            image_meta_udp <= 32'd0; image_id_udp <= 16'd0;
            image_end_id_udp <= 16'd0; audio_id_udp <= 16'd0; audio_end_id_udp <= 16'd0;
            image_end_good_udp <= 1'b0; audio_end_good_udp <= 1'b0;
            image_end_reason_udp <= 4'd0;
            audio_samples_udp <= 32'd0;
            image_begin_toggle_udp <= 1'b0; image_end_toggle_udp <= 1'b0;
            audio_begin_toggle_udp <= 1'b0; audio_end_toggle_udp <= 1'b0;
            image_result_sync <= 3'b000; audio_result_sync <= 3'b000;
            image_result_valid <= 1'b0; audio_result_valid <= 1'b0;
            image_result_code <= 8'd0; audio_result_code <= 8'd0;
        end else begin
            image_result_sync <= {image_result_sync[1:0], image_result_toggle_w};
            audio_result_sync <= {audio_result_sync[1:0], audio_result_toggle_w};
            image_result_valid <= 1'b0;
            audio_result_valid <= 1'b0;
            if (image_result_sync[2] ^ image_result_sync[1]) begin
                image_result_valid <= 1'b1;
                image_result_code <= image_result_code_w;
            end
            if (audio_result_sync[2] ^ audio_result_sync[1]) begin
                audio_result_valid <= 1'b1;
                audio_result_code <= audio_result_code_w;
            end
            if (frame_begin_valid) begin
                image_meta_udp <= {16'd0, image_flags, 3'd0, image_index};
                image_id_udp <= frame_id;
                image_begin_toggle_udp <= ~image_begin_toggle_udp;
            end
            if (frame_end_valid) begin
                image_end_id_udp <= frame_end_id;
                image_end_good_udp <= frame_end_ok;
                image_end_reason_udp <= frame_end_reason;
                image_end_toggle_udp <= ~image_end_toggle_udp;
            end
            if (audio_begin_valid) begin
                audio_id_udp <= audio_frame_id;
                audio_samples_udp <= audio_sample_count;
                audio_begin_toggle_udp <= ~audio_begin_toggle_udp;
            end
            if (audio_end_valid) begin
                audio_end_id_udp <= audio_end_id;
                audio_end_good_udp <= audio_end_ok;
                audio_end_toggle_udp <= ~audio_end_toggle_udp;
            end
        end
    end

    always @(posedge write_clk or posedge write_rst) begin
        if (write_rst) begin
            image_begin_sync <= 3'b000; image_end_sync <= 3'b000;
            audio_begin_sync <= 3'b000; audio_end_sync <= 3'b000;
            finish_sync <= 3'b000; transition_sync <= 3'b000;
            writer_state <= W_IDLE; write_audio_mode <= 1'b0; write_req <= 1'b0;
            write_en <= 1'b0; write_data <= 32'd0;
            frame_target_index <= 2'd0; audio_target_index <= 2'd3;
            audio_target_length <= 21'd0;
            audio_data_words <= 21'd0; frame_words_issued <= 21'd0;
            audio_words_popped <= 21'd0; audio_words_written <= 21'd0;
            frame_read_pending <= 1'b0; audio_read_pending <= 1'b0;
            frame_write_done <= 1'b0; audio_write_done <= 1'b0;
            frame_active_w <= 1'b0; frame_end_seen_w <= 1'b0;
            frame_end_good_w <= 1'b0; frame_result_sent_w <= 1'b0;
            frame_end_reason_w <= 4'd0;
            audio_active_w <= 1'b0; audio_end_seen_w <= 1'b0;
            audio_end_good_w <= 1'b0; audio_result_sent_w <= 1'b0;
            audio_retry_pending_w <= 1'b0; audio_no_data_w <= 1'b0;
            commit_pending_w <= 1'b0; transition_pending_w <= 1'b0;
            transition_done_seen_w <= 1'b0;
            pending_frame_id_w <= 16'd0; pending_image_index_w <= 5'd0;
            pending_wav_w <= 1'b0; pending_prev_w <= 1'b0; pending_auto_w <= 1'b0;
            pending_frame_buffer_w <= 2'd0; pending_audio_buffer_w <= 2'd2;
            pending_audio_length_w <= 21'd0; pending_audio_samples_w <= 32'd0;
            transition_image_index_w <= 5'd0; transition_image_wav_w <= 1'b0;
            transition_image_auto_w <= 1'b0; transition_image_buffer_w <= 2'd0;
            transition_audio_buffer_w <= 2'd2; transition_audio_length_w <= 21'd0;
            transition_audio_samples_w <= 32'd0;
            display_valid <= 1'b0; image_index_out <= 5'd0;
            image_has_wav <= 1'b0; auto_play_status <= 1'b0;
            display_buffer_index <= 2'd0; audio_buffer_index <= 2'd2;
            audio_buffer_length <= 21'd0;
            audio_sample_count_out <= 32'd0; audio_source_toggle <= 1'b0;
            transition_start_toggle <= 1'b0; transition_target_buf <= 1'b0;
            transition_mode_latched <= 2'd0; transition_prev_latched <= 1'b0;
            frame_commit_pulse <= 1'b0;
            image_result_toggle_w <= 1'b0; audio_result_toggle_w <= 1'b0;
            image_result_code_w <= 8'd0; audio_result_code_w <= 8'd0;
        end else begin
            image_begin_sync <= {image_begin_sync[1:0], image_begin_toggle_udp};
            image_end_sync <= {image_end_sync[1:0], image_end_toggle_udp};
            audio_begin_sync <= {audio_begin_sync[1:0], audio_begin_toggle_udp};
            audio_end_sync <= {audio_end_sync[1:0], audio_end_toggle_udp};
            finish_sync <= {finish_sync[1:0], frame_finish_toggle};
            transition_sync <= {transition_sync[1:0], transition_done_toggle};
            frame_read_pending <= frame_fifo_pop;
            audio_read_pending <= audio_fifo_pop;
            write_en <= 1'b0;
            frame_commit_pulse <= 1'b0;

            if (frame_fifo_pop)
                frame_words_issued <= frame_words_issued + 21'd1;
            if (audio_fifo_pop)
                audio_words_popped <= audio_words_popped + 21'd1;
            if (frame_read_pending) begin
                write_en <= 1'b1;
                write_data <= frame_fifo_data;
            end else if (frame_pad) begin
                write_en <= 1'b1;
                write_data <= 32'd0;
                frame_words_issued <= frame_words_issued + 21'd1;
            end else if (audio_read_pending) begin
                write_en <= 1'b1;
                write_data <= audio_fifo_data;
                audio_words_written <= audio_words_written + 21'd1;
            end else if (audio_pad) begin
                write_en <= 1'b1;
                write_data <= 32'h80808080;
                audio_words_written <= audio_words_written + 21'd1;
            end

            if (image_begin_event) begin
                pending_frame_id_w <= image_id_udp;
                pending_image_index_w <= image_meta_udp[4:0];
                pending_wav_w <= image_meta_udp[11];
                pending_prev_w <= image_meta_udp[8];
                pending_auto_w <= image_meta_udp[12];
                pending_frame_buffer_w <= display_valid ?
                    (display_buffer_index[0] ? 2'd0 : 2'd1) : 2'd0;
                frame_target_index <= display_valid ?
                    (display_buffer_index[0] ? 2'd0 : 2'd1) : 2'd0;
                frame_words_issued <= 21'd0;
                frame_write_done <= 1'b0;
                frame_active_w <= 1'b1;
                frame_end_seen_w <= 1'b0;
                frame_end_good_w <= 1'b0;
                frame_result_sent_w <= 1'b0;
                write_audio_mode <= 1'b0;
                write_req <= 1'b1;
                writer_state <= W_REQ;
            end

            if (image_end_event && image_end_id_udp == pending_frame_id_w) begin
                frame_end_seen_w <= 1'b1;
                frame_end_good_w <= image_end_good_udp;
                frame_end_reason_w <= image_end_reason_udp;
            end

            if (audio_begin_event && audio_id_udp == pending_frame_id_w && audio_active_w == 1'b0) begin
                audio_active_w <= 1'b1;
                audio_end_seen_w <= 1'b0;
                audio_end_good_w <= 1'b0;
                audio_result_sent_w <= 1'b0;
                audio_words_popped <= 21'd0;
                audio_words_written <= 21'd0;
                audio_data_words <= audio_data_word_count(audio_samples_udp);
                audio_target_length <= aligned_audio_words(audio_samples_udp);
                if (!audio_retry_pending_w)
                    audio_target_index <= display_valid && image_has_wav ?
                        (audio_buffer_index == 2'd2 ? 2'd3 : 2'd2) : 2'd2;
                if (audio_samples_udp == 0) begin
                    audio_no_data_w <= 1'b1;
                    pending_audio_buffer_w <= audio_target_index;
                    pending_audio_length_w <= 21'd0;
                    pending_audio_samples_w <= 32'd0;
                end else begin
                    audio_no_data_w <= 1'b0;
                    audio_write_done <= 1'b0;
                    write_audio_mode <= 1'b1;
                    write_req <= 1'b1;
                    writer_state <= W_REQ;
                end
            end

            if (audio_end_event && audio_end_id_udp == pending_frame_id_w) begin
                audio_end_seen_w <= 1'b1;
                audio_end_good_w <= audio_end_good_udp;
            end

            if (writer_state == W_REQ && write_req_ack) begin
                write_req <= 1'b0;
                writer_state <= W_ACTIVE;
            end
            if (finish_event && writer_state == W_ACTIVE) begin
                writer_state <= W_IDLE;
                if (write_audio_mode) audio_write_done <= 1'b1;
                else frame_write_done <= 1'b1;
            end

            if (frame_active_w && frame_end_seen_w && frame_write_done && !frame_result_sent_w) begin
                // RESULT 0x10..0x16 means reject/retry plus a four-bit cause.
                image_result_code_w <= frame_end_good_w ? 8'd0 : {4'h1,frame_end_reason_w};
                image_result_toggle_w <= ~image_result_toggle_w;
                frame_result_sent_w <= 1'b1;
                if (frame_end_good_w) begin
                    pending_audio_buffer_w <= audio_buffer_index;
                    pending_audio_length_w <= 21'd0;
                    pending_audio_samples_w <= 32'd0;
                end else begin
                    frame_active_w <= 1'b0;
                    audio_retry_pending_w <= 1'b0;
                end
            end

            if (audio_active_w && audio_end_seen_w && !audio_result_sent_w &&
                (audio_no_data_w || (audio_write_done && writer_state == W_IDLE))) begin
                audio_result_code_w <= audio_end_good_w ? 8'd0 : 8'd1;
                audio_result_toggle_w <= ~audio_result_toggle_w;
                audio_result_sent_w <= 1'b1;
                audio_active_w <= 1'b0;
                if (audio_end_good_w) begin
                    audio_retry_pending_w <= 1'b0;
                    if (!audio_no_data_w) begin
                        pending_audio_buffer_w <= audio_target_index;
                        pending_audio_length_w <= audio_target_length;
                        pending_audio_samples_w <= audio_samples_udp;
                    end
                    commit_pending_w <= 1'b1;
                end else begin
                    audio_retry_pending_w <= 1'b1;
                end
            end

            if (commit_pending_w && !transition_pending_w) begin
                commit_pending_w <= 1'b0;
                if (effect_mode == 2'd0 || !display_valid) begin
                    display_buffer_index <= pending_frame_buffer_w;
                    image_index_out <= pending_image_index_w;
                    image_has_wav <= pending_wav_w && pending_audio_samples_w != 0;
                    auto_play_status <= pending_auto_w;
                    display_valid <= 1'b1;
                    audio_buffer_index <= pending_audio_buffer_w;
                    audio_buffer_length <= pending_audio_length_w;
                    audio_sample_count_out <= pending_audio_samples_w;
                    audio_source_toggle <= ~audio_source_toggle;
                    frame_commit_pulse <= 1'b1;
                    image_result_code_w <= 8'd2;
                    image_result_toggle_w <= ~image_result_toggle_w;
                    frame_active_w <= 1'b0;
                end else begin
                    transition_target_buf <= pending_frame_buffer_w[0];
                    transition_mode_latched <= effect_mode;
                    transition_prev_latched <= pending_prev_w;
                    transition_image_index_w <= pending_image_index_w;
                    transition_image_wav_w <= pending_wav_w && pending_audio_samples_w != 0;
                    transition_image_auto_w <= pending_auto_w;
                    transition_image_buffer_w <= pending_frame_buffer_w;
                    transition_audio_buffer_w <= pending_audio_buffer_w;
                    transition_audio_length_w <= pending_audio_length_w;
                    transition_audio_samples_w <= pending_audio_samples_w;
                    transition_start_toggle <= ~transition_start_toggle;
                    transition_pending_w <= 1'b1;
                    transition_done_seen_w <= 1'b0;
                end
            end

            if (transition_event) transition_done_seen_w <= 1'b1;
            if (transition_pending_w && (transition_done_seen_w || transition_event)) begin
                transition_pending_w <= 1'b0;
                transition_done_seen_w <= 1'b0;
                display_buffer_index <= transition_image_buffer_w;
                image_index_out <= transition_image_index_w;
                image_has_wav <= transition_image_wav_w;
                auto_play_status <= transition_image_auto_w;
                display_valid <= 1'b1;
                audio_buffer_index <= transition_audio_buffer_w;
                audio_buffer_length <= transition_audio_length_w;
                audio_sample_count_out <= transition_audio_samples_w;
                audio_source_toggle <= ~audio_source_toggle;
                frame_commit_pulse <= 1'b1;
                image_result_code_w <= 8'd2;
                image_result_toggle_w <= ~image_result_toggle_w;
                frame_active_w <= 1'b0;
            end
        end
    end
endmodule
