`timescale 1ns/1ps

// Receive one media chunk from the UDP stack's application byte stream.
// Complete payload is buffered and CRC-checked before any word is released.
// The transport owner must send an ACK only after chunk_done, so a following
// packet cannot overwrite this single-packet buffer while it is draining.
// Unknown application types are ignored; malformed type 0x0010 packets pulse
// packet_error.  Sequence/session acceptance is handled by the caller.
module media_chunk_rx (
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  rx_byte,
    input  wire        rx_valid,
    output reg         chunk_valid,
    output reg  [15:0] chunk_session,
    output reg  [15:0] chunk_sequence,
    output reg  [7:0]  chunk_count,
    output reg  [7:0]  chunk_flags,
    output reg         packet_error,
    output wire        busy,
    output reg  [31:0] word_data,
    output reg         word_valid,
    input  wire        word_ready,
    output reg         chunk_done
);
    reg [31:0] words [0:252];
    reg [10:0] rx_pos;
    reg was_valid, candidate, malformed;
    reg [15:0] length_in, session_in, sequence_in, crc_in, crc_calc;
    reg [7:0] count_in, flags_in;
    reg [23:0] assembling;
    reg draining;
    reg [7:0] read_index;

    function [15:0] crc_next;
        input [15:0] prior;
        input [7:0] value;
        reg [15:0] c;
        integer bit_idx;
        begin
            c = prior ^ {value, 8'h00};
            for (bit_idx=0; bit_idx<8; bit_idx=bit_idx+1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc_next = c;
        end
    endfunction

    assign busy = draining;
    wire [15:0] expected_payload = 16'd8 + {6'd0, count_in, 2'b00};
    wire [10:0] expected_total = 11'd16 + {1'd0, count_in, 2'b00};
    wire [10:0] byte_offset = rx_pos - 11'd16;
    wire [7:0] incoming_word_index = byte_offset[9:2];

    // A full-word write on the fourth byte keeps the packet store compatible
    // with a synchronous block RAM inference on EG4.
    always @(posedge clk) begin
        if (rx_valid && candidate && !draining && rx_pos >= 11'd16 &&
            rx_pos < 11'd1028 && incoming_word_index < count_in) begin
            case (byte_offset[1:0])
                2'd0: assembling[7:0]   <= rx_byte;
                2'd1: assembling[15:8]  <= rx_byte;
                2'd2: assembling[23:16] <= rx_byte;
                2'd3: words[incoming_word_index] <= {rx_byte, assembling};
            endcase
        end
        if (draining && !word_valid)
            word_data <= words[read_index];
    end

    always @(posedge clk) begin
        if (rst) begin
            rx_pos <= 0; was_valid <= 0; candidate <= 0; malformed <= 0;
            length_in <= 0; session_in <= 0; sequence_in <= 0;
            count_in <= 0; flags_in <= 0;
            crc_in <= 0; crc_calc <= 16'hffff;
            chunk_valid <= 0; packet_error <= 0; chunk_done <= 0;
            chunk_session <= 0; chunk_sequence <= 0;
            chunk_count <= 0; chunk_flags <= 0;
            draining <= 0; read_index <= 0; word_valid <= 0;
        end else begin
            chunk_valid <= 0;
            packet_error <= 0;
            chunk_done <= 0;
            was_valid <= rx_valid;

            if (rx_valid) begin
                if (rx_pos != 11'd2047)
                    rx_pos <= rx_pos + 11'd1;
                else
                    malformed <= 1;
                case (rx_pos)
                    11'd0: if (rx_byte != 8'haa) malformed <= 1;
                    11'd1: if (rx_byte != 8'hbb) malformed <= 1;
                    11'd2: if (rx_byte != 8'hcc) malformed <= 1;
                    11'd3: if (rx_byte != 8'hdd) malformed <= 1;
                    11'd4: if (rx_byte != 8'h00) malformed <= 1;
                    11'd5: candidate <= !malformed && (rx_byte == 8'h10);
                    11'd6: length_in[15:8] <= rx_byte;
                    11'd7: length_in[7:0] <= rx_byte;
                    11'd8: session_in[7:0] <= rx_byte;
                    11'd9: session_in[15:8] <= rx_byte;
                    11'd10: sequence_in[7:0] <= rx_byte;
                    11'd11: sequence_in[15:8] <= rx_byte;
                    11'd12: count_in <= rx_byte;
                    11'd13: flags_in <= rx_byte;
                    11'd14: crc_in[7:0] <= rx_byte;
                    11'd15: crc_in[15:8] <= rx_byte;
                    default: if (rx_pos >= 11'd1028 ||
                                 incoming_word_index >= count_in)
                                 malformed <= 1;
                endcase
                if ((rx_pos >= 11'd8 && rx_pos <= 11'd13) ||
                    (rx_pos >= 11'd16 && rx_pos < 11'd1028))
                    crc_calc <= crc_next(crc_calc, rx_byte);
            end else if (was_valid) begin
                if (candidate) begin
                    if (!malformed && !draining && count_in != 0 &&
                        count_in <= 8'd253 && length_in == expected_payload &&
                        rx_pos == expected_total && crc_calc == crc_in) begin
                        chunk_session <= session_in;
                        chunk_sequence <= sequence_in;
                        chunk_count <= count_in;
                        chunk_flags <= flags_in;
                        chunk_valid <= 1;
                        draining <= 1;
                        read_index <= 0;
                    end else
                        packet_error <= 1;
                end
                rx_pos <= 0;
                candidate <= 0;
                malformed <= 0;
                crc_calc <= 16'hffff;
            end

            if (draining) begin
                if (!word_valid)
                    word_valid <= 1;
                else if (word_ready) begin
                    word_valid <= 0;
                    if (read_index + 8'd1 == chunk_count) begin
                        draining <= 0;
                        chunk_done <= 1;
                    end else
                        read_index <= read_index + 8'd1;
                end
            end
        end
    end
endmodule
