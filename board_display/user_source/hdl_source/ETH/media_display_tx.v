`timescale 1ns/1ps

// Serializes display-board replies and local touch actions onto the single
// UDP application TX port. The surrounding eth_subsys routes this channel to
// the media peer (.3 in the completed dual-board system).
module media_display_tx #(
    parameter integer TX_GAP_CYCLES = 125000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        local_cmd_toggle_async,
    input  wire [7:0]  local_cmd_async,
    input  wire        ready_valid,
    input  wire        image_result_valid,
    input  wire [7:0]  image_result_code,
    input  wire [15:0] image_result_frame,
    input  wire        audio_result_valid,
    input  wire [7:0]  audio_result_code,
    input  wire [15:0] audio_result_frame,
    input  wire        control_ack_valid,
    input  wire [7:0]  control_ack_sequence,
    input  wire [7:0]  control_ack_op,
    input  wire [7:0]  control_ack_status,
    input  wire [7:0]  control_ack_value,
    input  wire        status_valid,
    input  wire [63:0] status_payload,
    output wire        tx_request,
    output wire        tx_valid,
    output wire [7:0]  tx_data,
    output wire [15:0] tx_length,
    input  wire        tx_ready,
    input  wire        tx_ack
);
    localparam [1:0] IDLE=2'd0, WAIT_READY=2'd1, REQUEST=2'd2, SEND=2'd3;
    reg [1:0] state;
    reg [7:0] packet [0:15];
    reg [4:0] packet_length;
    reg [4:0] byte_index;
    reg [16:0] gap_count;

    reg [2:0] local_cmd_sync;
    reg local_cmd_seen;
    reg local_cmd_pending;
    reg [7:0] local_cmd_latched;
    reg ready_pending, image_pending, audio_pending, ack_pending, status_pending;
    reg [7:0] image_code_pending, audio_code_pending;
    reg [15:0] image_frame_pending, audio_frame_pending;
    reg [7:0] ack_seq_pending, ack_op_pending, ack_status_pending, ack_value_pending;
    reg [63:0] status_pending_data;

    assign tx_request = (state == REQUEST);
    assign tx_valid = (state == SEND);
    assign tx_data = packet[byte_index[3:0]];
    assign tx_length = {11'd0, packet_length};

    task automatic header(input [7:0] kind, input [15:0] payload_len);
        begin
            packet[0] <= 8'haa; packet[1] <= 8'hbb;
            packet[2] <= 8'hcc; packet[3] <= 8'hdd;
            packet[4] <= kind; packet[5] <= 8'h00;
            packet[6] <= payload_len[7:0]; packet[7] <= payload_len[15:8];
            packet_length <= payload_len[4:0] + 5'd8;
            byte_index <= 5'd0;
            state <= WAIT_READY;
        end
    endtask

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            packet_length <= 5'd0; byte_index <= 5'd0;
            gap_count <= 17'd0;
            local_cmd_sync <= 3'b000; local_cmd_seen <= 1'b0;
            local_cmd_pending <= 1'b0; local_cmd_latched <= 8'd0;
            ready_pending <= 1'b0; image_pending <= 1'b0; audio_pending <= 1'b0;
            ack_pending <= 1'b0; status_pending <= 1'b0;
            image_code_pending <= 8'd0; audio_code_pending <= 8'd0;
            image_frame_pending <= 16'd0; audio_frame_pending <= 16'd0;
            ack_seq_pending <= 8'd0; ack_op_pending <= 8'd0;
            ack_status_pending <= 8'd0; ack_value_pending <= 8'd0;
            status_pending_data <= 64'd0;
        end else begin
            local_cmd_sync <= {local_cmd_sync[1:0], local_cmd_toggle_async};
            if (local_cmd_sync[2] != local_cmd_seen) begin
                local_cmd_seen <= local_cmd_sync[2];
                if (local_cmd_async == 8'h4e || local_cmd_async == 8'h41 ||
                    local_cmd_async == 8'h50) begin
                    local_cmd_latched <= local_cmd_async;
                    local_cmd_pending <= 1'b1;
                end
            end
            if (ready_valid) ready_pending <= 1'b1;
            if (image_result_valid) begin
                image_code_pending <= image_result_code;
                image_frame_pending <= image_result_frame;
                image_pending <= 1'b1;
            end
            if (audio_result_valid) begin
                audio_code_pending <= audio_result_code;
                audio_frame_pending <= audio_result_frame;
                audio_pending <= 1'b1;
            end
            if (control_ack_valid) begin
                ack_seq_pending <= control_ack_sequence;
                ack_op_pending <= control_ack_op;
                ack_status_pending <= control_ack_status;
                ack_value_pending <= control_ack_value;
                ack_pending <= 1'b1;
            end
            if (status_valid) begin
                status_pending_data <= status_payload;
                status_pending <= 1'b1;
            end

            case (state)
                WAIT_READY: if (tx_ready) state <= REQUEST;
                IDLE: begin
                    if (gap_count != 0) begin
                        gap_count <= gap_count - 17'd1;
                    end else if (ready_pending) begin
                        header(8'h20, 16'd1);
                        packet[8] <= 8'h01;
                        ready_pending <= 1'b0;
                    end else if (image_pending && image_code_pending != 8'd2) begin
                        header(8'h24, 16'd3);
                        packet[8] <= image_frame_pending[7:0];
                        packet[9] <= image_frame_pending[15:8];
                        packet[10] <= image_code_pending;
                        image_pending <= 1'b0;
                    end else if (audio_pending) begin
                        header(8'h33, 16'd3);
                        packet[8] <= audio_frame_pending[7:0];
                        packet[9] <= audio_frame_pending[15:8];
                        packet[10] <= audio_code_pending;
                        audio_pending <= 1'b0;
                    end else if (image_pending) begin
                        header(8'h24, 16'd3);
                        packet[8] <= image_frame_pending[7:0];
                        packet[9] <= image_frame_pending[15:8];
                        packet[10] <= image_code_pending;
                        image_pending <= 1'b0;
                    end else if (ack_pending) begin
                        header(8'h41, 16'd4);
                        packet[8] <= ack_seq_pending; packet[9] <= ack_op_pending;
                        packet[10] <= ack_status_pending; packet[11] <= ack_value_pending;
                        ack_pending <= 1'b0;
                    end else if (status_pending) begin
                        header(8'h43, 16'd8);
                        packet[8] <= status_pending_data[7:0];
                        packet[9] <= status_pending_data[15:8];
                        packet[10] <= status_pending_data[23:16];
                        packet[11] <= status_pending_data[31:24];
                        packet[12] <= status_pending_data[39:32];
                        packet[13] <= status_pending_data[47:40];
                        packet[14] <= status_pending_data[55:48];
                        packet[15] <= status_pending_data[63:56];
                        status_pending <= 1'b0;
                    end else if (local_cmd_pending) begin
                        header(8'h05, 16'd2);
                        packet[8] <= local_cmd_latched;
                        packet[9] <= ~local_cmd_latched;
                        local_cmd_pending <= 1'b0;
                    end
                end
                REQUEST: if (tx_ack) begin
                    byte_index <= 5'd0;
                    state <= SEND;
                end
                SEND: begin
                    if (byte_index + 5'd1 >= packet_length) begin
                        byte_index <= 5'd0;
                        state <= IDLE;
                        gap_count <= TX_GAP_CYCLES[16:0];
                    end else begin
                        byte_index <= byte_index + 5'd1;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
