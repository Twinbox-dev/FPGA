`timescale 1ns/1ps

// Receives the display-side 0x0040/0x0042 control packets and the
// 0x0044/0x0045/0x0046 subtitle transaction forwarded by the media board.
module media_display_control_rx #(
    parameter CV_ENABLED=1,
    parameter CV_NEIGHBORHOOD_ENABLED=1,
    parameter SPECTRUM_ENABLED=1
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    output reg         set_toggle,
    output reg  [7:0]  set_op,
    output reg  [7:0]  set_value,
    output reg         status_req_valid,
    output reg  [7:0]  status_sequence,
    output reg         control_ack_valid,
    output reg  [7:0]  control_ack_sequence,
    output reg  [7:0]  control_ack_op,
    output reg  [7:0]  control_ack_status,
    output reg  [7:0]  control_ack_value,
    output reg         subtitle_write_toggle,
    output reg  [7:0]  subtitle_write_index,
    output reg  [7:0]  subtitle_write_char,
    output reg         subtitle_commit_toggle,
    output reg  [7:0]  subtitle_commit_length,
    output reg  [7:0]  subtitle_commit_sequence
);
    localparam [7:0] TYPE_SET = 8'h40;
    localparam [7:0] TYPE_STATUS_REQ = 8'h42;
    localparam [7:0] TYPE_SUB_BEGIN = 8'h44;
    localparam [7:0] TYPE_SUB_DATA = 8'h45;
    localparam [7:0] TYPE_SUB_END = 8'h46;

    reg [10:0] rx_pos;
    reg was_valid, magic_ok;
    reg [7:0] type_lo, type_hi;
    reg [15:0] payload_length;
    reg [7:0] payload [0:7];
    reg subtitle_active, subtitle_bad;
    reg [7:0] subtitle_sequence, subtitle_length, subtitle_checksum;
    reg [7:0] subtitle_next_offset, subtitle_sum;

    function set_value_valid;
        input [7:0] op;
        input [7:0] value;
        begin
            case (op)
                8'd1, 8'd2: set_value_valid = (value <= 8'd8);
                8'd3:       set_value_valid = (value <= 8'd6);
                8'd4, 8'd5: set_value_valid = (value <= 8'd2);
                8'd6:       set_value_valid = (value <= 8'd1) && (SPECTRUM_ENABLED || value==0);
                8'd7:       set_value_valid = (value <= 8'd3);
                8'd9:       set_value_valid = (value <= 8'd5) && (CV_ENABLED || value==0) &&
                                                  (CV_NEIGHBORHOOD_ENABLED || (value!=3 && value!=4));
                default:    set_value_valid = 1'b0;
            endcase
        end
    endfunction

    function [7:0] safe_ascii;
        input [7:0] value;
        begin
            safe_ascii = (value >= 8'h20 && value <= 8'h7e) ? value : 8'h20;
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_pos <= 11'd0; was_valid <= 1'b0; magic_ok <= 1'b0;
            type_lo <= 8'd0; type_hi <= 8'd0; payload_length <= 16'd0;
            subtitle_active <= 1'b0; subtitle_bad <= 1'b0;
            subtitle_sequence <= 8'd0; subtitle_length <= 8'd0;
            subtitle_checksum <= 8'd0; subtitle_next_offset <= 8'd0;
            subtitle_sum <= 8'd0;
            set_toggle <= 1'b0; set_op <= 8'd0; set_value <= 8'd0;
            status_req_valid <= 1'b0; status_sequence <= 8'd0;
            control_ack_valid <= 1'b0; control_ack_sequence <= 8'd0;
            control_ack_op <= 8'd0; control_ack_status <= 8'd0;
            control_ack_value <= 8'd0;
            subtitle_write_toggle <= 1'b0; subtitle_write_index <= 8'd0;
            subtitle_write_char <= 8'h20; subtitle_commit_toggle <= 1'b0;
            subtitle_commit_length <= 8'd0; subtitle_commit_sequence <= 8'd0;
        end else begin
            status_req_valid <= 1'b0;
            control_ack_valid <= 1'b0;
            was_valid <= rx_valid;
            if (rx_valid) begin
                if (rx_pos == 0) magic_ok <= rx_data == 8'haa;
                else if (rx_pos == 1) magic_ok <= magic_ok && rx_data == 8'hbb;
                else if (rx_pos == 2) magic_ok <= magic_ok && rx_data == 8'hcc;
                else if (rx_pos == 3) magic_ok <= magic_ok && rx_data == 8'hdd;
                case (rx_pos)
                    // The 0x0040-0x0046 control packets use the V1
                    // envelope byte order: TYPE_HI, TYPE_LO, LEN_HI, LEN_LO.
                    11'd4: type_hi <= rx_data;
                    11'd5: type_lo <= rx_data;
                    11'd6: payload_length[15:8] <= rx_data;
                    11'd7: payload_length[7:0] <= rx_data;
                    11'd8: payload[0] <= rx_data;
                    11'd9: payload[1] <= rx_data;
                    11'd10: payload[2] <= rx_data;
                    11'd11: payload[3] <= rx_data;
                    11'd12: payload[4] <= rx_data;
                    11'd13: payload[5] <= rx_data;
                    11'd14: payload[6] <= rx_data;
                    11'd15: payload[7] <= rx_data;
                    default: ;
                endcase
                if (rx_pos != 11'd2047) rx_pos <= rx_pos + 11'd1;
            end else if (was_valid) begin
                if (magic_ok && type_hi == 8'h00 &&
                    {6'd0, rx_pos} == 17'd8 + {1'b0, payload_length}) begin
                    case (type_lo)
                        TYPE_SET: begin
                            if (payload_length == 16'd4 && payload[3] == 8'd0 &&
                                set_value_valid(payload[1], payload[2])) begin
                                set_op <= payload[1];
                                set_value <= payload[2];
                                set_toggle <= ~set_toggle;
                                control_ack_status <= 8'd0;
                            end else begin
                                control_ack_status <= 8'd1;
                            end
                            control_ack_sequence <= payload[0];
                            control_ack_op <= payload[1];
                            control_ack_value <= payload[2];
                            control_ack_valid <= 1'b1;
                        end
                        TYPE_STATUS_REQ: begin
                            if (payload_length == 16'd1) begin
                                status_sequence <= payload[0];
                                status_req_valid <= 1'b1;
                            end
                        end
                        TYPE_SUB_BEGIN: begin
                            if (payload_length == 16'd3 && payload[1] <= 8'd160 &&
                                !subtitle_active) begin
                                subtitle_sequence <= payload[0];
                                subtitle_length <= payload[1];
                                subtitle_checksum <= payload[2];
                                subtitle_next_offset <= 8'd0;
                                subtitle_sum <= payload[1];
                                subtitle_bad <= 1'b0;
                                subtitle_active <= 1'b1;
                            end else begin
                                subtitle_bad <= 1'b1;
                            end
                        end
                        TYPE_SUB_DATA: begin
                            if (payload_length == 16'd3 && subtitle_active &&
                                payload[0] == subtitle_sequence &&
                                payload[1] == subtitle_next_offset &&
                                payload[1] < subtitle_length &&
                                payload[2] >= 8'h20 && payload[2] <= 8'h7e) begin
                                subtitle_write_index <= payload[1];
                                subtitle_write_char <= safe_ascii(payload[2]);
                                subtitle_write_toggle <= ~subtitle_write_toggle;
                                subtitle_next_offset <= subtitle_next_offset + 8'd1;
                                subtitle_sum <= subtitle_sum ^ payload[2];
                            end else if (subtitle_active) begin
                                subtitle_bad <= 1'b1;
                            end
                        end
                        TYPE_SUB_END: begin
                            if (payload_length == 16'd3 && subtitle_active &&
                                payload[0] == subtitle_sequence &&
                                payload[1] == subtitle_length &&
                                payload[2] == subtitle_checksum &&
                                subtitle_next_offset == subtitle_length &&
                                subtitle_sum == subtitle_checksum && !subtitle_bad) begin
                                subtitle_commit_sequence <= subtitle_sequence;
                                subtitle_commit_length <= subtitle_length;
                                subtitle_commit_toggle <= ~subtitle_commit_toggle;
                            end else begin
                                control_ack_sequence <= payload[0];
                                control_ack_op <= 8'd8;
                                control_ack_status <= 8'd1;
                                // Return the first failed END condition in the
                                // existing ACK value byte for field diagnosis.
                                if (!subtitle_active) control_ack_value <= 8'd1;
                                else if (payload_length != 16'd3) control_ack_value <= 8'd2;
                                else if (payload[0] != subtitle_sequence) control_ack_value <= 8'd3;
                                else if (payload[1] != subtitle_length) control_ack_value <= 8'd4;
                                else if (payload[2] != subtitle_checksum) control_ack_value <= 8'd5;
                                else if (subtitle_next_offset != subtitle_length) control_ack_value <= 8'd6;
                                else if (subtitle_sum != subtitle_checksum) control_ack_value <= 8'd7;
                                else if (subtitle_bad) control_ack_value <= 8'd8;
                                else control_ack_value <= 8'd15;
                                control_ack_valid <= 1'b1;
                            end
                            subtitle_active <= 1'b0;
                        end
                        default: ;
                    endcase
                end
                rx_pos <= 11'd0;
            end
        end
    end
endmodule
