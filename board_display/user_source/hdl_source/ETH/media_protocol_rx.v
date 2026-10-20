`timescale 1ns/1ps

// Receiver for the committed 0x0020..0x0024 image and 0x0030..0x0033 audio
// protocol. The UDP application stream is packet-contiguous; a low rx_valid
// after a packet closes and validates that packet. DATA payloads are staged in
// one 253-word BRAM-sized buffer, then drained through ready/valid before the
// next packet is accepted.
module media_protocol_rx #(
    parameter [20:0] FRAME_WORDS = 21'd460800,
    parameter [31:0] MAX_AUDIO_SAMPLES = 32'd2351104
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,

    output reg         ready_request,
    output reg         frame_begin_valid,
    output reg  [15:0] frame_id,
    output reg  [4:0]  image_index,
    output reg  [7:0]  image_flags,
    output reg  [20:0] image_total_words,

    output reg         stream_start,
    output reg         stream_is_audio,
    output reg  [8:0]  stream_word_count,
    output reg  [31:0] stream_word_data,
    output reg         stream_word_valid,
    input  wire        stream_word_ready,
    output reg         stream_done,

    output reg         frame_end_valid,
    output reg         frame_end_ok,
    output reg  [3:0]  frame_end_reason,
    output reg  [15:0] frame_end_id,
    output reg         audio_begin_valid,
    output reg  [15:0] audio_frame_id,
    output reg  [31:0] audio_sample_count,
    output reg         audio_end_valid,
    output reg         audio_end_ok,
    output reg  [15:0] audio_end_id,
    output reg         protocol_error_toggle
);
    localparam [7:0] TYPE_READY       = 8'h20;
    localparam [7:0] TYPE_IMAGE_BEGIN = 8'h21;
    localparam [7:0] TYPE_IMAGE_DATA  = 8'h22;
    localparam [7:0] TYPE_IMAGE_END   = 8'h23;
    localparam [7:0] TYPE_AUDIO_BEGIN = 8'h30;
    localparam [7:0] TYPE_AUDIO_DATA  = 8'h31;
    localparam [7:0] TYPE_AUDIO_END   = 8'h32;

    reg [31:0] packet_words [0:252];
    reg [10:0] rx_pos;
    reg was_valid;
    reg magic_ok;
    reg packet_dropped;
    reg [7:0] type_lo, type_hi;
    reg [15:0] payload_length;
    reg [15:0] packet_frame_id, packet_sequence;
    reg [7:0] packet_image_index, packet_image_flags;
    reg [31:0] packet_total_words, packet_sample_count;
    reg [31:0] packet_checksum;
    reg [15:0] packet_reserved;
    reg [31:0] word_assembly;
    reg [8:0] packet_word_index;
    reg [9:0] packet_sample_index;
    reg [31:0] packet_word_sum, packet_audio_sum;

    reg frame_active, frame_context_valid, frame_bad;
    reg [15:0] active_frame_id, expected_image_sequence;
    reg [20:0] received_image_words;
    reg [31:0] image_sum;
    reg frame_end_accepted;

    reg audio_active, audio_bad;
    reg [15:0] active_audio_frame_id, expected_audio_sequence;
    reg [31:0] expected_audio_samples, received_audio_samples, audio_sum;

    reg stream_active;
    reg [8:0] stream_read_index;
    reg [8:0] stream_read_count;
    wire [10:0] image_byte_offset = rx_pos - 11'd12;
    wire [7:0] incoming_word_index = image_byte_offset[9:2];
    wire [9:0] packet_audio_word_count = (packet_sample_index + 10'd3) >> 2;

    always @(posedge clk) begin
        if (rx_valid && !packet_dropped && rx_pos >= 11'd12) begin
            if (type_lo == TYPE_IMAGE_DATA && type_hi == 8'h00 &&
                incoming_word_index < 8'd253) begin
                if (image_byte_offset[1:0] == 2'd3)
                    packet_words[incoming_word_index] <= {rx_data, word_assembly[23:0]};
            end else if (type_lo == TYPE_AUDIO_DATA && type_hi == 8'h00 &&
                         incoming_word_index < 8'd253) begin
                if (image_byte_offset[1:0] == 2'd3)
                    packet_words[incoming_word_index] <= {rx_data, word_assembly[23:0]};
            end
        end else if (!rx_valid && was_valid && !packet_dropped &&
                     type_lo == TYPE_AUDIO_DATA && type_hi == 8'h00 &&
                     packet_sample_index[1:0] != 2'd0 && packet_word_index < 9'd253) begin
            case (packet_sample_index[1:0])
                2'd1: packet_words[packet_word_index[7:0]] <= {24'h808080, word_assembly[7:0]};
                2'd2: packet_words[packet_word_index[7:0]] <= {16'h8080, word_assembly[15:0]};
                2'd3: packet_words[packet_word_index[7:0]] <= {8'h80, word_assembly[23:0]};
                default: ;
            endcase
        end

        if (stream_active && !stream_word_valid)
            stream_word_data <= packet_words[stream_read_index[7:0]];
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_pos <= 11'd0;
            was_valid <= 1'b0;
            magic_ok <= 1'b0;
            packet_dropped <= 1'b0;
            type_lo <= 8'd0; type_hi <= 8'd0; payload_length <= 16'd0;
            packet_frame_id <= 16'd0; packet_sequence <= 16'd0;
            packet_image_index <= 8'd0; packet_image_flags <= 8'd0;
            packet_total_words <= 32'd0; packet_sample_count <= 32'd0;
            packet_checksum <= 32'd0; packet_reserved <= 16'd0;
            word_assembly <= 32'd0; packet_word_index <= 9'd0;
            packet_sample_index <= 10'd0;
            packet_word_sum <= 32'd0; packet_audio_sum <= 32'd0;
            frame_active <= 1'b0; frame_context_valid <= 1'b0; frame_bad <= 1'b0;
            active_frame_id <= 16'd0; expected_image_sequence <= 16'd0;
            received_image_words <= 21'd0; image_sum <= 32'd0;
            frame_end_accepted <= 1'b0;
            audio_active <= 1'b0; audio_bad <= 1'b0;
            active_audio_frame_id <= 16'd0; expected_audio_sequence <= 16'd0;
            expected_audio_samples <= 32'd0; received_audio_samples <= 32'd0;
            audio_sum <= 32'd0;
            stream_active <= 1'b0; stream_read_index <= 9'd0;
            stream_read_count <= 9'd0; stream_is_audio <= 1'b0;
            stream_start <= 1'b0; stream_word_valid <= 1'b0; stream_done <= 1'b0;
            stream_word_count <= 9'd0;
            ready_request <= 1'b0; frame_begin_valid <= 1'b0;
            frame_id <= 16'd0; image_index <= 5'd0; image_flags <= 8'd0;
            image_total_words <= 21'd0;
            frame_end_valid <= 1'b0; frame_end_ok <= 1'b0; frame_end_id <= 16'd0;
            frame_end_reason <= 4'd0;
            audio_begin_valid <= 1'b0; audio_frame_id <= 16'd0;
            audio_sample_count <= 32'd0;
            audio_end_valid <= 1'b0; audio_end_ok <= 1'b0; audio_end_id <= 16'd0;
            protocol_error_toggle <= 1'b0;
        end else begin
            ready_request <= 1'b0;
            frame_begin_valid <= 1'b0;
            stream_start <= 1'b0;
            stream_done <= 1'b0;
            frame_end_valid <= 1'b0;
            audio_begin_valid <= 1'b0;
            audio_end_valid <= 1'b0;
            was_valid <= rx_valid;

            if (rx_valid) begin
                if (rx_pos == 11'd0) begin
                    magic_ok <= (rx_data == 8'haa) && !stream_active;
                    packet_dropped <= stream_active;
                    packet_word_index <= 9'd0;
                    packet_sample_index <= 10'd0;
                    packet_word_sum <= 32'd0;
                    packet_audio_sum <= 32'd0;
                    word_assembly <= 32'h80808080;
                    packet_frame_id <= 16'd0; packet_sequence <= 16'd0;
                    packet_image_index <= 8'd0; packet_image_flags <= 8'd0;
                    packet_total_words <= 32'd0; packet_sample_count <= 32'd0;
                    packet_checksum <= 32'd0; packet_reserved <= 16'd0;
                end else if (rx_pos == 11'd1) magic_ok <= magic_ok && (rx_data == 8'hbb);
                else if (rx_pos == 11'd2) magic_ok <= magic_ok && (rx_data == 8'hcc);
                else if (rx_pos == 11'd3) magic_ok <= magic_ok && (rx_data == 8'hdd);

                if (rx_pos >= 11'd12 && !packet_dropped &&
                    (type_lo == TYPE_IMAGE_DATA || type_lo == TYPE_AUDIO_DATA) &&
                    type_hi == 8'h00) begin
                    case (image_byte_offset[1:0])
                        2'd0: word_assembly[7:0]   <= rx_data;
                        2'd1: word_assembly[15:8]  <= rx_data;
                        2'd2: word_assembly[23:16] <= rx_data;
                        default: ;
                    endcase
                    if (image_byte_offset[1:0] == 2'd3) begin
                        packet_word_index <= packet_word_index + 9'd1;
                        if (type_lo == TYPE_IMAGE_DATA)
                            packet_word_sum <= packet_word_sum + {rx_data, word_assembly[23:0]};
                    end
                    if (type_lo == TYPE_AUDIO_DATA) begin
                        packet_audio_sum <= packet_audio_sum + {24'd0, rx_data};
                        packet_sample_index <= packet_sample_index + 10'd1;
                    end
                end

                case (rx_pos)
                    11'd4: type_lo <= rx_data;
                    11'd5: type_hi <= rx_data;
                    11'd6: payload_length[7:0] <= rx_data;
                    11'd7: payload_length[15:8] <= rx_data;
                    11'd8: packet_frame_id[7:0] <= rx_data;
                    11'd9: packet_frame_id[15:8] <= rx_data;
                    11'd10: packet_sequence[7:0] <= rx_data;
                    11'd11: packet_sequence[15:8] <= rx_data;
                    default: ;
                endcase

                if (type_lo == TYPE_IMAGE_BEGIN && type_hi == 8'h00) begin
                    case (rx_pos)
                        11'd10: packet_image_index <= rx_data;
                        11'd11: packet_image_flags <= rx_data;
                        11'd12: packet_total_words[7:0] <= rx_data;
                        11'd13: packet_total_words[15:8] <= rx_data;
                        11'd14: packet_total_words[23:16] <= rx_data;
                        11'd15: packet_total_words[31:24] <= rx_data;
                        default: ;
                    endcase
                end else if (type_lo == TYPE_IMAGE_END && type_hi == 8'h00) begin
                    case (rx_pos)
                        11'd10: packet_checksum[7:0] <= rx_data;
                        11'd11: packet_checksum[15:8] <= rx_data;
                        11'd12: packet_checksum[23:16] <= rx_data;
                        11'd13: packet_checksum[31:24] <= rx_data;
                        11'd14: packet_reserved[7:0] <= rx_data;
                        11'd15: packet_reserved[15:8] <= rx_data;
                        default: ;
                    endcase
                end else if (type_lo == TYPE_AUDIO_BEGIN && type_hi == 8'h00) begin
                    case (rx_pos)
                        11'd10: packet_sample_count[7:0] <= rx_data;
                        11'd11: packet_sample_count[15:8] <= rx_data;
                        11'd12: packet_sample_count[23:16] <= rx_data;
                        11'd13: packet_sample_count[31:24] <= rx_data;
                        11'd14: packet_reserved[7:0] <= rx_data;
                        11'd15: packet_reserved[15:8] <= rx_data;
                        default: ;
                    endcase
                end else if (type_lo == TYPE_AUDIO_END && type_hi == 8'h00) begin
                    case (rx_pos)
                        11'd10: packet_checksum[7:0] <= rx_data;
                        11'd11: packet_checksum[15:8] <= rx_data;
                        11'd12: packet_checksum[23:16] <= rx_data;
                        11'd13: packet_checksum[31:24] <= rx_data;
                        11'd14: packet_reserved[7:0] <= rx_data;
                        11'd15: packet_reserved[15:8] <= rx_data;
                        default: ;
                    endcase
                end

                if (rx_pos != 11'd2047)
                    rx_pos <= rx_pos + 11'd1;
                else
                    protocol_error_toggle <= ~protocol_error_toggle;
            end else if (was_valid) begin
                if (packet_dropped || !magic_ok || type_hi != 8'h00 ||
                    {6'd0, rx_pos} != (17'd8 + {1'b0, payload_length})) begin
                    protocol_error_toggle <= ~protocol_error_toggle;
                    if (frame_active && type_lo == TYPE_IMAGE_DATA) frame_bad <= 1'b1;
                    if (audio_active && type_lo == TYPE_AUDIO_DATA) audio_bad <= 1'b1;
                end else begin
                    case (type_lo)
                        TYPE_READY: begin
                            if (payload_length == 16'd0) ready_request <= 1'b1;
                            else protocol_error_toggle <= ~protocol_error_toggle;
                        end
                        TYPE_IMAGE_BEGIN: begin
                            if (payload_length == 16'd8 && !frame_active &&
                                packet_total_words == {11'd0, FRAME_WORDS} &&
                                packet_image_index < 8'd32 &&
                                (packet_image_flags & 8'he6) == 8'd0) begin
                                frame_id <= packet_frame_id;
                                image_index <= packet_image_index[4:0];
                                image_flags <= packet_image_flags;
                                image_total_words <= FRAME_WORDS;
                                active_frame_id <= packet_frame_id;
                                frame_context_valid <= 1'b1;
                                frame_active <= 1'b1;
                                frame_bad <= 1'b0;
                                frame_end_accepted <= 1'b0;
                                expected_image_sequence <= 16'd0;
                                received_image_words <= 21'd0;
                                image_sum <= 32'd0;
                                frame_begin_valid <= 1'b1;
                            end else begin
                                protocol_error_toggle <= ~protocol_error_toggle;
                                frame_bad <= 1'b1;
                            end
                        end
                        TYPE_IMAGE_DATA: begin
                            if (frame_active && packet_frame_id == active_frame_id &&
                                packet_sequence == expected_image_sequence &&
                                payload_length >= 16'd8 && payload_length <= 16'd1016 &&
                                payload_length[1:0] == 2'd0 && packet_word_index != 0 &&
                                packet_word_index <= 9'd253 &&
                                {1'b0, received_image_words} + {13'd0, packet_word_index} <=
                                    {1'b0, image_total_words} && !frame_bad) begin
                                expected_image_sequence <= expected_image_sequence + 16'd1;
                                received_image_words <= received_image_words + {12'd0, packet_word_index};
                                image_sum <= image_sum + packet_word_sum;
                                stream_is_audio <= 1'b0;
                                stream_word_count <= packet_word_index;
                                stream_read_count <= packet_word_index;
                                stream_read_index <= 9'd0;
                                stream_active <= 1'b1;
                                stream_start <= 1'b1;
                            end else begin
                                frame_bad <= 1'b1;
                                protocol_error_toggle <= ~protocol_error_toggle;
                            end
                        end
                        TYPE_IMAGE_END: begin
                            frame_end_id <= packet_frame_id;
                            frame_end_valid <= 1'b1;
                            frame_end_reason <=
                                (!frame_active || packet_frame_id != active_frame_id) ? 4'd1 :
                                ((payload_length != 16'd8 || packet_reserved != 16'd0) ? 4'd2 :
                                ((received_image_words != image_total_words) ? 4'd3 :
                                ((image_sum != packet_checksum) ? 4'd4 :
                                (frame_bad ? 4'd5 : (stream_active ? 4'd6 : 4'd0)))));
                            frame_end_ok <= frame_active && packet_frame_id == active_frame_id &&
                                payload_length == 16'd8 && packet_reserved == 16'd0 &&
                                received_image_words == image_total_words &&
                                image_sum == packet_checksum && !frame_bad && !stream_active;
                            frame_end_accepted <= frame_active && packet_frame_id == active_frame_id &&
                                payload_length == 16'd8 && packet_reserved == 16'd0 &&
                                received_image_words == image_total_words &&
                                image_sum == packet_checksum && !frame_bad && !stream_active;
                            frame_active <= 1'b0;
                            if (!frame_active || packet_frame_id != active_frame_id ||
                                payload_length != 16'd8 || packet_reserved != 16'd0 ||
                                received_image_words != image_total_words ||
                                image_sum != packet_checksum || frame_bad || stream_active)
                                protocol_error_toggle <= ~protocol_error_toggle;
                        end
                        TYPE_AUDIO_BEGIN: begin
                            if (frame_context_valid && frame_end_accepted && !audio_active &&
                                packet_frame_id == active_frame_id && payload_length == 16'd8 &&
                                packet_reserved == 16'd0 && packet_sample_count <= MAX_AUDIO_SAMPLES) begin
                                audio_frame_id <= packet_frame_id;
                                audio_sample_count <= packet_sample_count;
                                active_audio_frame_id <= packet_frame_id;
                                expected_audio_samples <= packet_sample_count;
                                received_audio_samples <= 32'd0;
                                expected_audio_sequence <= 16'd0;
                                audio_sum <= 32'd0;
                                audio_bad <= 1'b0;
                                audio_active <= 1'b1;
                                audio_begin_valid <= 1'b1;
                            end else begin
                                protocol_error_toggle <= ~protocol_error_toggle;
                                audio_bad <= 1'b1;
                            end
                        end
                        TYPE_AUDIO_DATA: begin
                            if (audio_active && packet_frame_id == active_audio_frame_id &&
                                packet_sequence == expected_audio_sequence &&
                                payload_length >= 16'd5 && payload_length <= 16'd1016 &&
                                packet_sample_index != 0 && packet_sample_index <= 10'd1012 &&
                                {1'b0, received_audio_samples} + {22'd0, packet_sample_index} <=
                                    {1'b0, expected_audio_samples} && !audio_bad) begin
                                expected_audio_sequence <= expected_audio_sequence + 16'd1;
                                received_audio_samples <= received_audio_samples + {22'd0, packet_sample_index};
                                audio_sum <= audio_sum + packet_audio_sum;
                                stream_is_audio <= 1'b1;
                                stream_word_count <= {1'b0, packet_audio_word_count[7:0]};
                                stream_read_count <= {1'b0, packet_audio_word_count[7:0]};
                                stream_read_index <= 9'd0;
                                stream_active <= 1'b1;
                                stream_start <= 1'b1;
                            end else begin
                                audio_bad <= 1'b1;
                                protocol_error_toggle <= ~protocol_error_toggle;
                            end
                        end
                        TYPE_AUDIO_END: begin
                            audio_end_id <= packet_frame_id;
                            audio_end_valid <= 1'b1;
                            audio_end_ok <= audio_active && packet_frame_id == active_audio_frame_id &&
                                payload_length == 16'd8 && packet_reserved == 16'd0 &&
                                received_audio_samples == expected_audio_samples &&
                                audio_sum == packet_checksum && !audio_bad && !stream_active;
                            if (!audio_active || packet_frame_id != active_audio_frame_id ||
                                payload_length != 16'd8 || packet_reserved != 16'd0 ||
                                received_audio_samples != expected_audio_samples ||
                                audio_sum != packet_checksum || audio_bad || stream_active)
                                protocol_error_toggle <= ~protocol_error_toggle;
                            audio_active <= 1'b0;
                        end
                        default: ;
                    endcase
                end
                rx_pos <= 11'd0;
                packet_dropped <= 1'b0;
            end

            if (stream_active) begin
                if (!stream_word_valid) begin
                    stream_word_valid <= 1'b1;
                end else if (stream_word_ready) begin
                    stream_word_valid <= 1'b0;
                    if (stream_read_index + 9'd1 >= stream_read_count) begin
                        stream_active <= 1'b0;
                        stream_done <= 1'b1;
                    end else begin
                        stream_read_index <= stream_read_index + 9'd1;
                    end
                end
            end
        end
    end
endmodule
