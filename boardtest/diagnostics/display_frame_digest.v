`timescale 1ns/1ps
// Temporary board-acceptance probe. Samples the actual SDRAM video return,
// never requests memory access. Not part of the production TD source list.
module display_frame_digest #(
    parameter integer WORDS = 460800,
    parameter [20:0] FIRST_ADDR0 = 21'd460160,
    parameter [20:0] BANK_WORDS = 21'd460800
)(
    input wire mem_clk, app_clk, producer_clk, rst,
    input wire video_ack, video_valid, video_audio,
    input wire [31:0] video_data,
    input wire [1:0] video_bank,
    input wire write_valid,
    input wire [20:0] write_addr,
    input wire [31:0] write_data,
    input wire image_begin,
    input wire producer_start,
    input wire [20:0] source_words,
    input wire raw_valid, padded_valid,
    input wire [31:0] raw_data, padded_data,
    input wire [7:0] rx_data,
    input wire rx_valid,
    output wire tx_request, tx_valid,
    output reg [7:0] tx_data,
    output wire [15:0] tx_length,
    input wire tx_ready, tx_ack
);
    localparam [31:0] WORD_COUNT = WORDS;
    reg ack_d, active;
    reg [18:0] count;
    reg [31:0] sum, hash;
    reg [15:0] frame_number;
    reg [1:0] bank;
    reg [127:0] last_frame, last_write;
    reg [511:0] snapshot_data_mem;
    reg [255:0] aux_snapshot_app;
    reg [127:0] last_raw, last_pad;
    reg raw_active,pad_active;
    reg [20:0] raw_count,pad_count,raw_target;
    reg [31:0] raw_sum,raw_hash,pad_sum,pad_hash;
    reg [15:0] raw_number,pad_number;
    wire [31:0] raw_sum_next=raw_sum+raw_data, pad_sum_next=pad_sum+padded_data;
    wire [31:0] raw_hash_next=((raw_hash<<5)+raw_hash)^raw_data;
    wire [31:0] pad_hash_next=((pad_hash<<5)+pad_hash)^padded_data;
    always @(posedge producer_clk or posedge rst) begin
        if(rst)begin last_raw<=0;raw_active<=0;raw_count<=0;raw_target<=0;
            raw_sum<=0;raw_hash<=0;raw_number<=0;end
        else if(producer_start)begin
            raw_active<=1;raw_target<=source_words;raw_count<=0;raw_sum<=0;raw_hash<=0;
        end else if(raw_active && raw_valid)begin
            raw_count<=raw_count+1'b1;raw_sum<=raw_sum_next;raw_hash<=raw_hash_next;
            if(raw_count+1'b1==raw_target)begin
                raw_active<=0;raw_number<=raw_number+1'b1;
                last_raw<={raw_hash_next,raw_sum_next,11'd0,raw_target,8'd0,8'hdd,raw_number};
            end
        end
    end
    reg wr_active;
    reg [18:0] wr_count;
    reg [31:0] wr_sum, wr_hash;
    reg [15:0] wr_number;
    reg [1:0] wr_bank;
    wire [31:0] wr_sum_next = wr_sum + write_data;
    wire [31:0] wr_hash_next = ((wr_hash << 5) + wr_hash) ^ write_data;
    reg request_toggle, reply_toggle;
    reg [2:0] request_sync, reply_sync;
    wire take_word = active && video_valid && !video_audio;
    wire [31:0] sum_next = sum + video_data;
    // Multiplication by 33 is a shift/add and remains sensitive to row order.
    // A rotate-XOR hash would alias whole 640-word rows (640 % 32 == 0).
    wire [31:0] hash_next = ((hash << 5) + hash) ^ video_data;
    always @(posedge mem_clk or posedge rst) begin
        if(rst) begin
            ack_d<=0;active<=0;count<=0;sum<=0;hash<=0;bank<=0;
            frame_number<=0;last_frame<=0;last_write<=0;snapshot_data_mem<=0;
            wr_active<=0;wr_count<=0;wr_sum<=0;wr_hash<=0;wr_number<=0;wr_bank<=0;
            request_sync<=0;reply_toggle<=0;
        end else begin
            ack_d<=video_ack;
            request_sync<={request_sync[1:0],request_toggle};
            if(request_sync[2]!=reply_toggle) begin
                snapshot_data_mem<={aux_snapshot_app,last_write,last_frame};
                reply_toggle<=request_sync[2];
            end
            if(video_ack && !ack_d) begin
                active<=1;count<=0;sum<=0;hash<=0;bank<=video_bank;
            end else if(take_word) begin
                sum<=sum_next;hash<=hash_next;count<=count+1'b1;
                if(count==WORDS-1) begin
                    active<=0;frame_number<=frame_number+1'b1;
                    last_frame<={hash_next,sum_next,WORD_COUNT,6'd0,bank,8'hd9,frame_number};
                end
            end
            if(write_valid && (write_addr==FIRST_ADDR0 || write_addr==BANK_WORDS+FIRST_ADDR0)) begin
                wr_active<=1;wr_count<=1;wr_sum<=write_data;wr_hash<=write_data;
                wr_bank<=write_addr>=BANK_WORDS ? 2'd1 : 2'd0;
            end else if(write_valid && wr_active && write_addr<(BANK_WORDS<<1)) begin
                wr_count<=wr_count+1'b1;wr_sum<=wr_sum_next;wr_hash<=wr_hash_next;
                if(wr_count==WORDS-1) begin
                    wr_active<=0;wr_number<=wr_number+1'b1;
                    last_write<={wr_hash_next,wr_sum_next,WORD_COUNT,6'd0,wr_bank,8'hda,wr_number};
                end
            end
        end
    end

    reg [10:0] pos;
    reg was_valid, magic_ok, match_type;
    reg [2:0] state;
    reg [6:0] byte_index;
    reg [511:0] payload;
    localparam IDLE=0, SNAPSHOT=1, REQUEST=2, SEND=3, WAIT_READY=4;
    assign tx_request=state==REQUEST;
    assign tx_valid=state==SEND;
    assign tx_length=16'd72;
    always @* begin
        case(byte_index)
            0:tx_data=8'haa;1:tx_data=8'hbb;2:tx_data=8'hcc;3:tx_data=8'hdd;
            4:tx_data=0;5:tx_data=8'h47;6:tx_data=0;7:tx_data=64;
            default:tx_data=payload[8*(byte_index-8)+:8];
        endcase
    end
    always @(posedge app_clk or posedge rst) begin
        if(rst) begin
            pos<=0;was_valid<=0;magic_ok<=0;match_type<=0;
            state<=IDLE;byte_index<=0;payload<=0;request_toggle<=0;reply_sync<=0;
            aux_snapshot_app<=0;last_pad<=0;pad_active<=0;pad_count<=0;
            pad_sum<=0;pad_hash<=0;pad_number<=0;
        end else begin
            was_valid<=rx_valid;
            reply_sync<={reply_sync[1:0],reply_toggle};
            if(image_begin)begin
                pad_active<=1;pad_count<=0;pad_sum<=0;pad_hash<=0;
            end else begin
                if(pad_active && padded_valid)begin
                    pad_count<=pad_count+1'b1;pad_sum<=pad_sum_next;pad_hash<=pad_hash_next;
                    if(pad_count==WORDS-1)begin
                        pad_active<=0;pad_number<=pad_number+1'b1;
                        last_pad<={pad_hash_next,pad_sum_next,WORD_COUNT,8'd0,8'hdc,pad_number};
                    end
                end
            end
            if(rx_valid) begin
                pos<=pos+1'b1;
                case(pos)
                    0:begin magic_ok<=rx_data==8'haa;match_type<=0;end
                    1:magic_ok<=magic_ok && rx_data==8'hbb;
                    2:magic_ok<=magic_ok && rx_data==8'hcc;
                    3:magic_ok<=magic_ok && rx_data==8'hdd;
                    4:match_type<=rx_data==0;
                    5:match_type<=match_type && rx_data==8'h47;
                    6:match_type<=match_type && rx_data==0;
                    7:match_type<=match_type && rx_data==0;
                    default:;
                endcase
            end else begin
                pos<=0;
                if(was_valid && magic_ok && match_type && pos==8 && state==IDLE) begin
                    request_toggle<=~request_toggle;
                    aux_snapshot_app<={last_pad,last_raw};
                    state<=SNAPSHOT;
                end
            end
            case(state)
                SNAPSHOT:if(reply_sync[2]==request_toggle) begin
                    payload<=snapshot_data_mem;state<=WAIT_READY;
                end
                WAIT_READY:if(tx_ready)state<=REQUEST;
                REQUEST:if(tx_ack)begin byte_index<=0;state<=SEND;end
                SEND:if(byte_index==71)state<=IDLE;else byte_index<=byte_index+1'b1;
                default:;
            endcase
        end
    end
endmodule
