`timescale 1ns/1ps

// Native 48-bit SD command frame shifter. CRC7 uses x^7+x^3+1, MSB-first;
// R1/R2 response CRC and frame bits use the same ordering as the Physical
// Layer Simplified Specification. SD clock edges are qualified in the
// 100 MHz host domain; CMD changes on falling SD clock edges and is sampled on
// rising SD clock edges. The open-drain mode is used through card identification.
module sd_native_cmd (
    input  wire         clk,
    input  wire         rst,
    input  wire         sd_clk_rise,
    input  wire         sd_clk_fall,
    input  wire         cmd_in,
    output wire         cmd_out,
    output wire         cmd_oe,
    input  wire         start,
    input  wire [5:0]   command_index,
    input  wire [31:0]  command_argument,
    input  wire [1:0]   response_kind,  // 0: none, 1: R1, 2: R2, 3: R3
    input  wire         open_drain,
    output wire         busy,
    output wire         done,
    output reg          error,
    output reg  [2:0]   error_code,
    output reg  [15:0]  response_wait_trace,
    output reg  [5:0]   last_tx_mismatch_position,
    output reg          last_tx_mismatch_expected,
    output reg          last_tx_mismatch_sampled,
    output reg  [135:0] response,
    output wire [2:0] debug_state
);
    localparam [2:0] S_IDLE        = 3'd0;
    localparam [2:0] S_PREPARE     = 3'd1;
    localparam [2:0] S_SEND        = 3'd2;
    localparam [2:0] S_RELEASE     = 3'd3;
    localparam [2:0] S_WAIT_REPLY  = 3'd4;
    localparam [2:0] S_READ_REPLY  = 3'd5;
    localparam [2:0] S_GAP         = 3'd6;
    localparam [2:0] S_FINISH      = 3'd7;

    reg [2:0] state;
    reg [47:0] command_frame;
    reg [5:0] command_bit;
    reg [7:0] response_count;
    reg [7:0] response_length;
    reg [6:0] response_wait;
    reg [3:0] inter_command_gap;
    reg [1:0] response_kind_latched;
    reg [5:0] command_index_latched;
    reg open_drain_latched;
    reg sampled_this_bit;
    reg [135:0] response_next;

    function [6:0] crc7_40;
        input [39:0] bits_in;
        integer i;
        reg [6:0] crc;
        reg feedback;
        begin
            crc = 7'd0;
            for (i = 39; i >= 0; i = i - 1) begin
                feedback = bits_in[i] ^ crc[6];
                crc = {crc[5:0], 1'b0};
                if (feedback) crc = crc ^ 7'h09;
            end
            crc7_40 = crc;
        end
    endfunction

    function [6:0] crc7_120;
        input [119:0] bits_in;
        integer i;
        reg [6:0] crc;
        reg feedback;
        begin
            crc = 7'd0;
            for (i = 119; i >= 0; i = i - 1) begin
                feedback = bits_in[i] ^ crc[6];
                crc = {crc[5:0], 1'b0};
                if (feedback) crc = crc ^ 7'h09;
            end
            crc7_120 = crc;
        end
    endfunction

    assign busy = (state != S_IDLE);
    assign debug_state = state;
    // Let the parent transaction FSM observe completion during S_FINISH.
    // Registering this pulse one cycle later can miss the first data token at
    // 50 MHz, where one 100 MHz host cycle is half an SD clock period.
    assign done = (state == S_FINISH);
    assign cmd_out = command_frame[command_bit];
    assign cmd_oe = (state == S_SEND) &&
                    (!open_drain_latched || !command_frame[command_bit]);

    always @* begin
        response_next = {response[134:0], cmd_in};
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_IDLE;
            command_frame <= 48'hffffffffffff;
            command_bit <= 6'd47;
            response_count <= 8'd0;
            response_length <= 8'd0;
            response_wait <= 7'd0;
            inter_command_gap<=4'd0;
            response_kind_latched <= 2'd0;
            command_index_latched <= 6'd0;
            open_drain_latched <= 1'b1;
            sampled_this_bit <= 1'b0;
            response <= 136'd0;
            response_wait_trace<=16'd0;
            last_tx_mismatch_position<=6'd63;
            last_tx_mismatch_expected<=1'b0;last_tx_mismatch_sampled<=1'b0;
            error <= 1'b0;
            error_code<=0;
        end else begin
            case (state)
                S_IDLE: begin
                    error <= 1'b0;
                    error_code<=0;
                    sampled_this_bit <= 1'b0;
                    if (start) begin
                        command_frame <= {
                            2'b01,
                            command_index,
                            command_argument,
                            crc7_40({2'b01, command_index, command_argument}),
                            1'b1
                        };
                        command_bit <= 6'd47;
                        response <= 136'd0;
                        response_wait_trace<=16'd0;
                        last_tx_mismatch_position<=6'd63;
                        last_tx_mismatch_expected<=1'b0;last_tx_mismatch_sampled<=1'b0;
                        response_count <= 8'd0;
                        response_wait <= 7'd0;
                        inter_command_gap<=4'd0;
                        response_kind_latched <= response_kind;
                        response_length <= (response_kind == 2'd2) ? 8'd136 : 8'd48;
                        command_index_latched <= command_index;
                        open_drain_latched <= open_drain;
                        state <= S_PREPARE;
                    end
                end

                // Wait for a falling edge so the first command bit has a full
                // half cycle of setup before the card samples the next rising edge.
                S_PREPARE: begin
                    if (sd_clk_fall) begin
                        sampled_this_bit <= 1'b0;
                        state <= S_SEND;
                    end
                end

                S_SEND: begin
                    if (sd_clk_rise) begin
                        sampled_this_bit <= 1'b1;
                        if(cmd_in!==command_frame[command_bit] && last_tx_mismatch_position==6'd63) begin
                            last_tx_mismatch_position<=command_bit;
                            last_tx_mismatch_expected<=command_frame[command_bit];
                            last_tx_mismatch_sampled<=cmd_in;
                        end
                        if (command_bit == 0) state <= S_RELEASE;
                    end
                    if (sd_clk_fall && sampled_this_bit) begin
                        sampled_this_bit <= 1'b0;
                        if (command_bit != 0) command_bit <= command_bit - 1'b1;
                    end
                end

                S_RELEASE: begin
                    if (sd_clk_fall) begin
                        if (response_kind_latched == 0) begin
                            // SD command timing requires an idle gap before
                            // the next host command (NCC); keep CMD released.
                            inter_command_gap<=0;state <= S_GAP;
                        end else begin
                            response_wait <= 7'd0;
                            state <= S_WAIT_REPLY;
                        end
                    end
                end

                S_WAIT_REPLY: begin
                    if (sd_clk_rise) begin
                        response_wait_trace<={response_wait_trace[14:0],cmd_in};
                        if (!cmd_in) begin
                            response <= response_next;
                            response_count <= 8'd1;
                            state <= S_READ_REPLY;
                        end else if (response_wait == 7'd63) begin
                            error <= 1'b1;
                            error_code<=3'd1; // response start timeout
                            inter_command_gap<=0;state <= S_GAP;
                        end else begin
                            response_wait <= response_wait + 1'b1;
                        end
                    end
                end

                S_READ_REPLY: begin
                    if (sd_clk_rise) begin
                        response <= response_next;
                        if (response_count + 1'b1 >= response_length) begin
                            if (response_kind_latched == 2'd2) begin
                                if (response_next[135:134] != 2'b00 ||
                                    response_next[133:128] != 6'b111111 ||
                                    response_next[0] != 1'b1)begin
                                    error <= 1'b1;error_code<=3'd2;
                                end else if(response_next[7:1] != crc7_120(response_next[127:8]))begin
                                    error <= 1'b1;error_code<=3'd3;
                                end
                            end else if (response_next[47:46] != 2'b00 ||
                                         response_next[0] != 1'b1 ||
                                         response_next[45:40] != command_index_latched) begin
                                if (response_kind_latched != 2'd3) begin error <= 1'b1;error_code<=3'd4;end
                            end else if (response_kind_latched != 2'd3 &&
                                         response_next[7:1] != crc7_40(response_next[47:8])) begin
                                error <= 1'b1;error_code<=3'd5;
                            end
                            if(command_index_latched==6'd6 &&
                               (command_frame[39:8]==32'h00FFFFF1 || command_frame[39:8]==32'h80FFFFF1) &&
                               !response_next[30]) begin
                                // Standard CMD6 returns a 64-byte status block
                                // immediately after R1; let the parent arm DAT receive.
                                state<=S_FINISH;
                            end else if(command_index_latched==6'd17) begin
                                // CMD17 data may start after minimum NAC; arm DAT0 immediately.
                                state<=S_FINISH;
                            end else begin
                                inter_command_gap<=0;state <= S_GAP;
                            end
                        end else begin
                            response_count <= response_count + 1'b1;
                        end
                    end
                end

                // Leave eight complete SD clock periods between command/response
                // frames so native cards have the required CMD bus turnaround.
                S_GAP: begin
                    if(sd_clk_rise)begin
                        if(inter_command_gap==4'd7)state<=S_FINISH;
                        else inter_command_gap<=inter_command_gap+1'b1;
                    end
                end

                S_FINISH: begin
                    state <= S_IDLE;
                end

                default: begin
                    error <= 1'b1;
                    state <= S_FINISH;
                end
            endcase
        end
    end
endmodule
