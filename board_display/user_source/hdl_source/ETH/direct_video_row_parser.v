module direct_video_row_parser #(
    parameter integer PIXELS_PER_ROW=640,
    parameter integer ACTIVE_LINES=360,
    parameter integer STATUS_ENABLED=1
)(
    input              clk,
    input              rst,
    input              packet_start,
    input              packet_end,
    input      [15:0]  packet_length,
    input              rx_valid,
    input      [7:0]   rx_data,
    output reg         row_prepare,
    output reg         row_begin,
    output reg         row_stream_start,
    output reg [15:0]  row_frame_id,
    output reg [8:0]   row_index,
    output reg [15:0]  row_sequence,
    output reg         pixel_write,
    output reg [9:0]   pixel_index,
    output reg [15:0]  pixel_data,
    output reg         row_commit,
    output reg         row_reject,
    output reg [15:0]  row_crc_seed,row_crc_expected,
    output reg [31:0]  accepted_rows,
    output reg [31:0]  rejected_rows
);
    localparam [10:0] ROW_PACKET_BYTES = 14+2*PIXELS_PER_ROW;
    localparam [10:0] HEADER_BYTES = 11'd12;
    localparam [10:0] PIXEL_BYTES = 2*PIXELS_PER_ROW;
    localparam [10:0] CRC_OFFSET = 12+2*PIXELS_PER_ROW;
    localparam [15:0] WIDTH_U16=PIXELS_PER_ROW;
    localparam [8:0] HEIGHT_U9=ACTIVE_LINES;

    reg in_packet;
    reg [10:0] byte_index;
    reg [15:0] packet_length_latched;
    reg packet_length_ok;
    reg header_ok;
    reg [15:0] crc_state;
    reg [7:0] crc_low;
    reg [7:0] pixel_low;
    reg [8:0] row_y_tmp;
    reg [15:0] frame_tmp;
    reg [15:0] sequence_tmp;
    reg stream_start_flag;
    reg [10:0] current_index;
    reg [15:0] crc_base;
    reg [15:0] crc_after_byte;
    reg [10:0] payload_index;
    reg crc_match_now;
    reg last_byte_seen;
    reg crc_good;

    function [15:0] crc16_ccitt_byte;
        input [15:0] crc;
        input [7:0] data;
        integer bit_index;
        reg [15:0] value;
        begin
            value = crc ^ {data, 8'h00};
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                value = value[15] ? ((value << 1) ^ 16'h1021) : (value << 1);
            crc16_ccitt_byte = value;
        end
    endfunction

    always @* begin
        current_index = packet_start ? 11'd0 : byte_index;
        crc_base = packet_start ? 16'hffff : crc_state;
        crc_after_byte = crc16_ccitt_byte(crc_base, rx_data);
        payload_index = current_index - HEADER_BYTES;
        crc_match_now = (current_index == ROW_PACKET_BYTES-1) &&
                        (rx_data == crc_state[15:8]) &&
                        (crc_low == crc_state[7:0]);
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            in_packet <= 1'b0;
            byte_index <= 11'd0;
            packet_length_latched <= 16'd0;
            packet_length_ok <= 1'b0;
            header_ok <= 1'b0;
            crc_state <= 16'hffff;
            crc_low <= 8'd0;
            pixel_low <= 8'd0;
            row_y_tmp <= 9'd0;
            frame_tmp <= 16'd0;
            sequence_tmp <= 16'd0;
            stream_start_flag <= 1'b0;
            row_frame_id <= 16'd0;
            row_index <= 9'd0;
            row_sequence <= 16'd0;
            pixel_index <= 10'd0;
            pixel_data <= 16'd0;
            row_prepare <= 1'b0;
            row_begin <= 1'b0;
            row_stream_start <= 1'b0;
            pixel_write <= 1'b0;
            row_commit <= 1'b0;
            row_reject <= 1'b0;
            row_crc_seed<=16'hffff;row_crc_expected<=0;
            accepted_rows <= 32'd0;
            rejected_rows <= 32'd0;
            last_byte_seen <= 1'b0;
            crc_good <= 1'b0;
        end else begin
            row_prepare <= 1'b0;
            row_begin <= 1'b0;
            row_stream_start <= 1'b0;
            pixel_write <= 1'b0;
            row_commit <= 1'b0;
            row_reject <= 1'b0;

            if (packet_start) begin
                in_packet <= 1'b1;
                byte_index <= 11'd0;
                packet_length_latched <= packet_length;
                packet_length_ok <= (packet_length == ROW_PACKET_BYTES);
                header_ok <= 1'b1;
                crc_state <= 16'hffff;
                crc_low <= 8'd0;
                pixel_low <= 8'd0;
                row_y_tmp <= 9'd0;
                frame_tmp <= 16'd0;
                sequence_tmp <= 16'd0;
                stream_start_flag <= 1'b0;
                last_byte_seen <= 1'b0;
                crc_good <= 1'b0;
            end

            if (rx_valid && (in_packet || packet_start)) begin
                byte_index <= current_index + 11'd1;
                if (current_index < CRC_OFFSET)
                    crc_state <= crc_after_byte;

                case (current_index)
                    11'd0: if (rx_data != 8'h56) header_ok <= 1'b0;
                    11'd1: if (rx_data != 8'h44) header_ok <= 1'b0;
                    11'd2: if (rx_data != 8'h01) header_ok <= 1'b0;
                    11'd3: begin
                        if (rx_data[7:1] != 0) header_ok <= 1'b0;
                        stream_start_flag <= rx_data[0];
                    end
                    11'd4: frame_tmp[7:0] <= rx_data;
                    11'd5: frame_tmp[15:8] <= rx_data;
                    11'd6: row_y_tmp[7:0] <= rx_data;
                    11'd7: begin
                        row_y_tmp[8] <= rx_data[0];
                        if (rx_data[7:1] != 0) header_ok <= 1'b0;
                    end
                    11'd8: sequence_tmp[7:0] <= rx_data;
                    11'd9: begin
                        sequence_tmp[15:8] <= rx_data;
                        row_frame_id<=frame_tmp;row_index<=row_y_tmp;
                        row_sequence<={rx_data,sequence_tmp[7:0]};
                        row_prepare<=header_ok && row_y_tmp<HEIGHT_U9;
                    end
                    11'd10: if (rx_data != WIDTH_U16[7:0]) header_ok <= 1'b0;
                    11'd11: begin
                        row_crc_seed<=crc_after_byte;
                        if (rx_data != WIDTH_U16[15:8]) header_ok <= 1'b0;
                        if (row_y_tmp >= HEIGHT_U9) header_ok <= 1'b0;
                        // Announce a fully checked header before payload bytes.
                        // This gives the store two clocks to decode slot/stride
                        // before the first assembled RGB565 pixel is written.
                        if(header_ok && rx_data==WIDTH_U16[15:8] && row_y_tmp<HEIGHT_U9)begin
                            row_begin<=1'b1;
                            row_stream_start<=(row_y_tmp==0 && stream_start_flag);
                        end
                    end
                    default: ;
                endcase

                if ((current_index >= HEADER_BYTES) &&
                    (current_index < HEADER_BYTES + PIXEL_BYTES) && header_ok) begin
                    if (!payload_index[0]) begin
                        pixel_low <= rx_data;
                        pixel_index <= payload_index[10:1];
                    end else begin
                        pixel_data <= {rx_data, pixel_low};
                        pixel_index <= payload_index[10:1];
                        pixel_write <= 1'b1;
                    end
                end

                if (current_index == CRC_OFFSET)
                    crc_low <= rx_data;
                if (current_index == ROW_PACKET_BYTES-1) begin
                    last_byte_seen <= 1'b1;
                    crc_good <= crc_match_now;
                end
            end

            if (packet_end && (in_packet || packet_start)) begin
                in_packet <= 1'b0;
                if (packet_length_ok && (packet_length_latched == ROW_PACKET_BYTES) &&
                    ((last_byte_seen || (rx_valid && current_index == ROW_PACKET_BYTES-1)) &&
                     (crc_good || (rx_valid && current_index == ROW_PACKET_BYTES-1 && crc_match_now)) &&
                     header_ok && (row_y_tmp < HEIGHT_U9) &&
                     (byte_index == ROW_PACKET_BYTES ||
                      (rx_valid && current_index == ROW_PACKET_BYTES - 11'd1)))) begin
                    row_commit <= 1'b1;row_crc_expected<=crc_state;
                    if(STATUS_ENABLED) accepted_rows <= accepted_rows + 32'd1;
                end else begin
                    row_reject <= 1'b1;
                    if(STATUS_ENABLED) rejected_rows <= rejected_rows + 32'd1;
                end
            end
        end
    end
endmodule

// The parser announces SESSION_START when a valid row header ends, but the
// row is published only after its payload CRC is received. Retain that intent
// across the packet and request the memory lease only for a complete first row.
module direct_video_session_gate(
    input wire clk,
    input wire rst,
    input wire row_stream_start,
    input wire [15:0] row_frame_id,
    input wire [8:0] row_index,
    input wire row_commit,
    input wire row_reject,
    output reg request
);
    reg pending_start;
    reg [15:0] pending_frame;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pending_start <= 1'b0;
            pending_frame <= 16'd0;
            request <= 1'b0;
        end else begin
            request <= 1'b0;
            if (row_stream_start && row_index == 0) begin
                if (row_commit) begin
                    request <= 1'b1;
                    pending_start <= 1'b0;
                end else begin
                    pending_start <= 1'b1;
                    pending_frame <= row_frame_id;
                end
            end

            if (row_reject && row_index == 0 &&
                ((pending_start && pending_frame == row_frame_id) || row_stream_start))
                pending_start <= 1'b0;

            if (row_commit && row_index == 0 && !row_stream_start) begin
                if (pending_start && pending_frame == row_frame_id)
                    request <= 1'b1;
                // Never let a different completed frame consume a stale start.
                pending_start <= 1'b0;
            end
        end
    end
endmodule
