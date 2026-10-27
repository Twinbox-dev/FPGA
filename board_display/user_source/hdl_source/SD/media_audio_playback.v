`timescale 1ns/1ps

// Plays the V1 24 kHz, unsigned 8-bit mono PCM representation stored in
// SDRAM BUF2/BUF3. Samples are converted to signed 24-bit and duplicated at
// the 48 kHz HDMI audio tick, matching the single-board playback behavior.
module media_audio_playback #(parameter PAUSE_ENABLED=0)(
    input  wire        clk,
    input  wire        rst,
    input wire pause,
    input  wire        source_toggle,
    input  wire        pair_on,
    input  wire [1:0]  source_buffer,
    input  wire [20:0] source_length,
    input  wire [31:0] source_samples,
    output reg         read_req,
    input  wire        read_req_ack_async,
    output reg  [1:0]  read_index,
    output reg  [20:0] read_length,
    output reg         read_en,
    input  wire [31:0] read_data,
    input  wire [9:0]  read_fifo_words,
    output reg         audio_tick,
    output reg         audio_valid,
    output reg  [23:0] audio_left,
    output reg  [23:0] audio_right,
    output reg         audio_underrun
);
    reg [2:0] source_sync, ack_sync;
    reg [1:0] div25;
    reg [9:0] tick_count;
    reg [31:0] samples_remaining;
    reg [31:0] active_samples;
    reg [31:0] cur_word, next_word;
    reg have_cur, have_next;
    reg read_pending, read_capture_pending, read_target_cur;
    reg [1:0] byte_pos;
    reg duplicate_phase;
    reg request_waiting, read_ready;
    reg restart_pending;
    reg [1:0] request_delay;
    wire source_event = source_sync[2] ^ source_sync[1];
    wire ack_event_level = ack_sync[2];
    wire [7:0] sample_byte = byte_pos == 2'd0 ? cur_word[7:0] :
                             byte_pos == 2'd1 ? cur_word[15:8] :
                             byte_pos == 2'd2 ? cur_word[23:16] : cur_word[31:24];
    wire signed [23:0] sample_value = ($signed({16'd0, sample_byte}) - 24'sd128) <<< 16;
    wire tick_due = (div25 == 2'd0) && (tick_count == 10'd520);
    wire read_current = read_ready && !read_pending && !have_cur &&
                        !read_capture_pending &&
                        (read_fifo_words != 0);
    wire read_next = read_ready && !read_pending && have_cur && !have_next &&
                     !read_capture_pending &&
                     (read_fifo_words != 0);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            source_sync <= 3'b000; ack_sync <= 3'b000;
            div25 <= 2'd0; tick_count <= 10'd0;
            samples_remaining <= 32'd0; active_samples <= 32'd0;
            cur_word <= 32'd0; next_word <= 32'd0;
            have_cur <= 1'b0; have_next <= 1'b0;
            read_pending <= 1'b0; read_capture_pending <= 1'b0; read_target_cur <= 1'b0;
            byte_pos <= 2'd0; duplicate_phase <= 1'b0;
            request_waiting <= 1'b0; read_ready <= 1'b0; restart_pending <= 1'b0;
            request_delay <= 2'd0;
            read_req <= 1'b0; read_index <= 2'd2; read_length <= 21'd0;
            read_en <= 1'b0; audio_tick <= 1'b0; audio_valid <= 1'b0;
            audio_left <= 24'd0; audio_right <= 24'd0; audio_underrun <= 1'b0;
        end else begin
            source_sync <= {source_sync[1:0], source_toggle};
            ack_sync <= {ack_sync[1:0], read_req_ack_async};
            div25 <= div25 + 2'd1;
            if (div25 == 2'd0)
                tick_count <= tick_due ? 10'd0 : tick_count + 10'd1;

            read_en <= 1'b0;
            audio_tick <= 1'b0;
            audio_valid <= 1'b0;
            audio_underrun <= 1'b0;

            if (source_event) begin
                read_req <= 1'b0;
                read_index <= source_buffer;
                read_length <= source_length;
                active_samples <= source_samples;
                samples_remaining <= source_samples;
                have_cur <= 1'b0; have_next <= 1'b0;
                read_pending <= 1'b0; read_capture_pending <= 1'b0; read_ready <= 1'b0;
                // Audio source changes only with a committed single-layout image.
                // Layout changes leave source_toggle unchanged, so playback runs on.
                request_waiting <= 1'b0; restart_pending <= source_samples != 0;
                request_delay <= 2'd3;
                byte_pos <= 2'd0; duplicate_phase <= 1'b0;
            end else if(!PAUSE_ENABLED||!pause)begin
                if (restart_pending && pair_on && active_samples != 0) begin
                    if (request_delay != 0)
                        request_delay <= request_delay - 2'd1;
                    else begin
                        read_req <= 1'b1;
                        request_waiting <= 1'b1;
                        restart_pending <= 1'b0;
                        read_ready <= 1'b0;
                        have_cur <= 1'b0; have_next <= 1'b0;
                        read_pending <= 1'b0; read_capture_pending <= 1'b0;
                    end
                end

                if (request_waiting && ack_event_level) begin
                    read_req <= 1'b0;
                    request_waiting <= 1'b0;
                    read_ready <= 1'b1;
                end

                if (read_current || read_next) begin
                    read_en <= 1'b1;
                    read_pending <= 1'b1;
                    read_target_cur <= read_current;
                end else if (read_pending) begin
                    read_pending <= 1'b0;
                    read_capture_pending <= 1'b1;
                end else if (read_capture_pending) begin
                    read_capture_pending <= 1'b0;
                    if (read_target_cur) begin
                        cur_word <= read_data;
                        have_cur <= 1'b1;
                    end else begin
                        next_word <= read_data;
                        have_next <= 1'b1;
                    end
                end

                if (tick_due) begin
                    audio_tick <= 1'b1;
                    audio_valid <= 1'b1;
                    if (pair_on && active_samples != 0 && have_cur && samples_remaining != 0) begin
                        audio_left <= sample_value;
                        audio_right <= sample_value;
                        if (duplicate_phase) begin
                            duplicate_phase <= 1'b0;
                            samples_remaining <= samples_remaining - 32'd1;
                            if (samples_remaining == 32'd1) begin
                                samples_remaining <= active_samples;
                                restart_pending <= 1'b1;
                                request_delay <= 2'd3;
                                read_ready <= 1'b0;
                                read_req <= 1'b0;
                                have_cur <= 1'b0; have_next <= 1'b0;
                                read_pending <= 1'b0; read_capture_pending <= 1'b0;
                                byte_pos <= 2'd0;
                            end else if (byte_pos == 2'd3) begin
                                byte_pos <= 2'd0;
                                cur_word <= next_word;
                                have_cur <= have_next;
                                have_next <= 1'b0;
                            end else begin
                                byte_pos <= byte_pos + 2'd1;
                            end
                        end else begin
                            duplicate_phase <= 1'b1;
                        end
                    end else begin
                        audio_left <= 24'd0;
                        audio_right <= 24'd0;
                        if (pair_on && active_samples != 0)
                            audio_underrun <= 1'b1;
                    end
                end
            end
        end
    end
endmodule
