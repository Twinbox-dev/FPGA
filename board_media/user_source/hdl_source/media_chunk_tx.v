`timescale 1ns/1ps

// One reliable-transfer building block: assemble a bounded image/audio chunk
// before asking the UDP stack to transmit it.  The caller supplies words with
// data_valid/data_ready; it waits for a later application ACK before starting
// the next chunk.  Ethernet/IP routing and ACK policy live outside this module.
//
// Wire bytes: AA BB CC DD 00 10 LEN_H LEN_L |
//             SESSION_L SESSION_H SEQ_L SEQ_H COUNT FLAGS CRC_L CRC_H |
//             COUNT little-endian 32-bit words.
// LEN = 8 + 4*COUNT (bytes following the application header).
// CRC16-CCITT-FALSE covers SESSION through FLAGS, then all word bytes.
module media_chunk_tx (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [15:0] session,
    input  wire [15:0] sequence_id,
    input  wire [7:0]  count,
    input  wire [7:0]  flags,
    input  wire [31:0] data_word,
    input  wire        data_valid,
    output wire        data_ready,
    input  wire        tx_ack,
    output wire        tx_request,
    output wire        tx_valid,
    output reg  [7:0]  tx_byte,
    output wire [15:0] tx_length,
    output wire        busy,
    output reg         done
);
    localparam IDLE=3'd0, META=3'd1, LOAD=3'd2,
               CRC_WORD=3'd3, REQUEST=3'd4, SEND=3'd5;
    reg [2:0] state;
    reg [15:0] session_r, sequence_r, crc;
    reg [7:0] count_r, flags_r, loaded;
    reg [2:0] meta_idx;
    reg [1:0] crc_byte_idx;
    reg [31:0] held_word, read_word;
    reg [10:0] send_idx;
    reg [31:0] words [0:252];

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

    function [7:0] metadata_byte;
        input [2:0] index;
        input [15:0] sid, seq;
        input [7:0] n, f;
        begin
            case (index)
                3'd0: metadata_byte = sid[7:0];
                3'd1: metadata_byte = sid[15:8];
                3'd2: metadata_byte = seq[7:0];
                3'd3: metadata_byte = seq[15:8];
                3'd4: metadata_byte = n;
                default: metadata_byte = f;
            endcase
        end
    endfunction

    wire [15:0] payload_length = 16'd8 + {6'd0, count_r, 2'b00};
    wire [10:0] frame_length = 11'd16 + {1'b0, count_r, 2'b00};
    wire [7:0] next_word_index = send_idx[9:2] - 8'd3;
    assign tx_length = {5'd0, frame_length};
    assign data_ready = (state == LOAD);
    assign tx_request = (state == REQUEST);
    assign tx_valid = (state == SEND);
    assign busy = (state != IDLE);

    // Full-word write and registered read allow a single 253 x 32 RAM.
    always @(posedge clk) begin
        if (state == LOAD && data_valid)
            words[loaded] <= data_word;
        if (state == REQUEST && tx_ack)
            read_word <= words[0];
        else if (state == SEND && send_idx >= 11'd16 &&
                 send_idx[1:0] == 2'd3 && send_idx+11'd1 < frame_length)
            read_word <= words[next_word_index];
    end

    always @* begin
        case (send_idx)
            11'd0:  tx_byte=8'haa;
            11'd1:  tx_byte=8'hbb;
            11'd2:  tx_byte=8'hcc;
            11'd3:  tx_byte=8'hdd;
            11'd4:  tx_byte=8'h00;
            11'd5:  tx_byte=8'h10;
            11'd6:  tx_byte=payload_length[15:8];
            11'd7:  tx_byte=payload_length[7:0];
            11'd8:  tx_byte=session_r[7:0];
            11'd9:  tx_byte=session_r[15:8];
            11'd10: tx_byte=sequence_r[7:0];
            11'd11: tx_byte=sequence_r[15:8];
            11'd12: tx_byte=count_r;
            11'd13: tx_byte=flags_r;
            11'd14: tx_byte=crc[7:0];
            11'd15: tx_byte=crc[15:8];
            default: tx_byte=read_word[8*send_idx[1:0] +: 8];
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            session_r <= 0; sequence_r <= 0;
            count_r <= 0; flags_r <= 0;
            loaded <= 0; meta_idx <= 0; crc_byte_idx <= 0;
            held_word <= 0; crc <= 16'hffff;
            send_idx <= 0; done <= 0;
        end else begin
            done <= 0;
            case (state)
                IDLE: if (start && count != 0 && count <= 8'd253) begin
                    session_r <= session;
                    sequence_r <= sequence_id;
                    count_r <= count;
                    flags_r <= flags;
                    loaded <= 0;
                    meta_idx <= 0;
                    crc <= 16'hffff;
                    state <= META;
                end
                META: begin
                    crc <= crc_next(crc, metadata_byte(meta_idx, session_r,
                                                        sequence_r, count_r, flags_r));
                    if (meta_idx == 3'd5)
                        state <= LOAD;
                    else
                        meta_idx <= meta_idx + 3'd1;
                end
                LOAD: if (data_valid) begin
                    held_word <= data_word;
                    crc_byte_idx <= 0;
                    state <= CRC_WORD;
                end
                CRC_WORD: begin
                    crc <= crc_next(crc, held_word[8*crc_byte_idx +: 8]);
                    if (crc_byte_idx == 2'd3) begin
                        loaded <= loaded + 8'd1;
                        state <= (loaded + 8'd1 == count_r) ? REQUEST : LOAD;
                    end else
                        crc_byte_idx <= crc_byte_idx + 2'd1;
                end
                REQUEST: if (tx_ack) begin
                    send_idx <= 0;
                    state <= SEND;
                end
                SEND: if (send_idx == frame_length - 11'd1) begin
                    state <= IDLE;
                    done <= 1;
                end else
                    send_idx <= send_idx + 11'd1;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
