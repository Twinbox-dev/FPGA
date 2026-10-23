`timescale 1ns/1ps
// Media-board fixed-topology UDP/IP implementation.
//
// The board exchanges UDP with two peers: PC (.1) and display (.2). The
// display MAC is fixed; the PC MAC is learned from ARP/IPv4. Payloads are
// buffered in a single 1024-byte block RAM so the application byte-stream
// interface and the TEMAC's non-backpressured source behavior remain intact.
module media_udp_lite #(
    parameter [31:0] LOCAL_IP  = 32'hc0a88903,
    parameter [47:0] LOCAL_MAC = 48'h020000000003,
    parameter [31:0] PC_IP     = 32'hc0a88901,
    parameter [31:0] DISPLAY_IP= 32'hc0a88902,
    parameter [47:0] DISPLAY_MAC = 48'h0123456789ab,
    parameter [15:0] LOCAL_PORT = 16'h0001,
    parameter [15:0] MAX_TX_PAYLOAD = 16'd1024
)(
    input  wire        clk,
    input  wire        reset,

    output wire        udp2app_tx_ready,
    output reg         udp2app_tx_ack,
    input  wire        app_tx_request,
    input  wire        app_tx_data_valid,
    input  wire [7:0]  app_tx_data,
    input  wire [15:0] app_tx_data_length,
    input  wire [15:0] app_tx_dst_port,
    input  wire [31:0] ip_tx_dst_address,

    output reg         app_rx_data_valid,
    output reg  [7:0]  app_rx_data,
    output reg  [15:0] app_rx_data_length,
    output reg  [15:0] app_rx_port_num,

    output wire        temac_rx_ready,
    input  wire        temac_rx_valid,
    input  wire [7:0]  temac_rx_data,
    input  wire        temac_rx_sof,
    input  wire        temac_rx_eof,

    input  wire        temac_tx_ready,
    output reg         temac_tx_valid,
    output reg  [7:0]  temac_tx_data,
    output reg         temac_tx_sof,
    output reg         temac_tx_eof,
    output reg         ip_rx_error,
    output wire        arp_request_no_reply_error
);
    localparam [2:0] TX_IDLE=3'd0, TX_COLLECT=3'd1, TX_PREP=3'd2,
                     TX_UDP=3'd3, TX_ARP=3'd4, TX_CSUM=3'd5,
                     TX_FOLD=3'd6;
    localparam [10:0] RX_IDLE=11'h7ff;

    reg [2:0] tx_state;
    reg [7:0] tx_payload [0:1023]; /* fehdl force_ram=1, ram_style="bram" */
    reg [10:0] tx_length, tx_count;
    reg [7:0] tx_payload_q;
    reg [15:0] tx_dst_port;
    reg [31:0] tx_dst_ip;
    reg [15:0] tx_ident;
    reg [15:0] tx_ip_checksum;
    reg [15:0] tx_ip_total_length;
    reg [31:0] tx_ip_sum;
    reg [3:0] tx_csum_index;
    reg [47:0] tx_dst_mac;
    reg [10:0] tx_frame_length, tx_index;
    wire tx_payload_write = (tx_state == TX_COLLECT) && app_tx_data_valid &&
                            ((tx_count != 0) || (app_tx_data_length <= MAX_TX_PAYLOAD));
    wire tx_payload_read = (tx_state == TX_PREP) ||
                           ((tx_state == TX_UDP) && !temac_tx_ready &&
                            (tx_index >= 11'd41) &&
                            (tx_index < (11'd41 + tx_length)));
    wire [9:0] tx_payload_read_addr = (tx_state == TX_PREP) ?
                                      10'd0 : (tx_index[9:0] - 10'd41);

    reg rx_active;
    reg [10:0] rx_index;
    reg [15:0] rx_ethertype;
    reg [31:0] rx_source_ip;
    reg [23:0] rx_dest_ip;
    reg [47:0] rx_source_mac;
    reg [15:0] rx_ip_length, rx_fragment;
    reg [7:0] rx_ip_version, rx_ip_protocol;
    reg [31:0] rx_ip_sum;
    reg [7:0] rx_ip_word_hi;
    reg rx_ip_valid;
    reg [15:0] rx_udp_src_port, rx_udp_dst_port, rx_udp_length;
    reg [7:0] rx_udp_port_hi, rx_udp_len_hi;
    reg [15:0] rx_payload_left;
    reg rx_payload_active;

    reg arp_pending;
    reg arp_header_valid;
    reg [15:0] rx_arp_opcode;
    reg [47:0] rx_arp_sender_mac, arp_target_mac;
    reg [31:0] rx_arp_sender_ip, arp_target_ip;
    reg [23:0] rx_arp_target_ip;
    reg [47:0] pc_mac;
    reg pc_mac_valid;

    assign temac_rx_ready = 1'b0; // Local-link ready is active low.
    assign udp2app_tx_ready = (tx_state == TX_IDLE) && !arp_pending;
    assign arp_request_no_reply_error = 1'b0;

    /* verilator lint_off BLKSEQ */
    function ip_checksum_ok;
        input [31:0] sum;
        reg [31:0] folded;
        begin
            folded = {16'd0,sum[15:0]} + {16'd0,sum[31:16]};
            folded = {16'd0,folded[15:0]} + {16'd0,folded[31:16]};
            ip_checksum_ok = folded[15:0] == 16'hffff;
        end
    endfunction

    function [15:0] finish_ip_checksum;
        input [31:0] input_sum;
        reg [31:0] sum;
        begin
            sum = input_sum;
            sum = {16'd0,sum[15:0]} + {16'd0,sum[31:16]};
            sum = {16'd0,sum[15:0]} + {16'd0,sum[31:16]};
            finish_ip_checksum = ~sum[15:0];
        end
    endfunction

    /* verilator lint_on BLKSEQ */

    function [7:0] mac_octet;
        input [47:0] mac;
        input [2:0] index;
        begin mac_octet = mac[47-index*8 -: 8]; end
    endfunction

    function [7:0] ip_octet;
        input [31:0] ip;
        input [1:0] index;
        begin ip_octet = ip[31-index*8 -: 8]; end
    endfunction

    function [7:0] udp_frame_octet;
        input [10:0] index;
        reg [15:0] total_length;
        reg [15:0] udp_length;
        begin
            total_length = 16'd28 + {5'd0,tx_length};
            udp_length = 16'd8 + {5'd0,tx_length};
            case (index)
                0,1,2,3,4,5: udp_frame_octet = mac_octet(tx_dst_mac,index[2:0]);
                6,7,8,9,10,11: udp_frame_octet = mac_octet(LOCAL_MAC,index[2:0]-3'd6);
                12: udp_frame_octet = 8'h08;
                13: udp_frame_octet = 8'h00;
                14: udp_frame_octet = 8'h45;
                15: udp_frame_octet = 8'h00;
                16: udp_frame_octet = total_length[15:8];
                17: udp_frame_octet = total_length[7:0];
                18: udp_frame_octet = tx_ident[15:8];
                19: udp_frame_octet = tx_ident[7:0];
                20: udp_frame_octet = 8'h40;
                21: udp_frame_octet = 8'h00;
                22: udp_frame_octet = 8'h40;
                23: udp_frame_octet = 8'h11;
                24: udp_frame_octet = tx_ip_checksum[15:8];
                25: udp_frame_octet = tx_ip_checksum[7:0];
                26,27,28,29: udp_frame_octet = ip_octet(LOCAL_IP,index[1:0]-2'd2);
                30,31,32,33: udp_frame_octet = ip_octet(tx_dst_ip,index[1:0]-2'd2);
                34: udp_frame_octet = LOCAL_PORT[15:8];
                35: udp_frame_octet = LOCAL_PORT[7:0];
                36: udp_frame_octet = tx_dst_port[15:8];
                37: udp_frame_octet = tx_dst_port[7:0];
                38: udp_frame_octet = udp_length[15:8];
                39: udp_frame_octet = udp_length[7:0];
                40,41: udp_frame_octet = 8'h00; // IPv4 UDP checksum may be zero.
                default:
                    if (index >= 11'd42 && index < (11'd42 + tx_length))
                        udp_frame_octet = tx_payload_q;
                    else udp_frame_octet = 8'h00; // Ethernet minimum-frame padding.
            endcase
        end
    endfunction

    function [7:0] arp_frame_octet;
        input [5:0] index;
        begin
            case (index)
                0,1,2,3,4,5: arp_frame_octet = mac_octet(arp_target_mac,index[2:0]);
                6,7,8,9,10,11: arp_frame_octet = mac_octet(LOCAL_MAC,index[2:0]-3'd6);
                12: arp_frame_octet = 8'h08;
                13: arp_frame_octet = 8'h06;
                14: arp_frame_octet = 8'h00;
                15: arp_frame_octet = 8'h01;
                16: arp_frame_octet = 8'h08;
                17: arp_frame_octet = 8'h00;
                18: arp_frame_octet = 8'h06;
                19: arp_frame_octet = 8'h04;
                20: arp_frame_octet = 8'h00;
                21: arp_frame_octet = 8'h02;
                22,23,24,25,26,27: arp_frame_octet = mac_octet(LOCAL_MAC,index[2:0]-3'd6);
                28,29,30,31: arp_frame_octet = ip_octet(LOCAL_IP,index[1:0]);
                32,33,34,35,36,37: arp_frame_octet = mac_octet(arp_target_mac,index[2:0]);
                38,39,40,41: arp_frame_octet = ip_octet(arp_target_ip,index[1:0]-2'd2);
                default: arp_frame_octet = 8'h00; // Pad to the 60-byte Ethernet minimum.
            endcase
        end
    endfunction

    always @* begin
        temac_tx_valid = 1'b1; // Active-low client source-ready.
        temac_tx_data = 8'd0;
        temac_tx_sof = 1'b1;
        temac_tx_eof = 1'b1;
        if (tx_state == TX_UDP) begin
            temac_tx_valid = 1'b0;
            temac_tx_data = udp_frame_octet(tx_index);
            temac_tx_sof = tx_index == 0 ? 1'b0 : 1'b1;
            temac_tx_eof = tx_index + 1'b1 >= tx_frame_length ? 1'b0 : 1'b1;
        end else if (tx_state == TX_ARP) begin
            temac_tx_valid = 1'b0;
            temac_tx_data = arp_frame_octet(tx_index[5:0]);
            temac_tx_sof = tx_index == 0 ? 1'b0 : 1'b1;
            temac_tx_eof = tx_index == 11'd59 ? 1'b0 : 1'b1;
        end
    end

    // Synchronous read keeps the 1 KB packet store in block RAM. The final
    // header byte (index 41) prefetches payload byte 0 for index 42.
    always @(posedge clk) begin
        if (tx_payload_write)
            tx_payload[tx_count[9:0]] <= app_tx_data;
    end
    always @(posedge clk) begin
        if (tx_payload_read)
            tx_payload_q <= tx_payload[tx_payload_read_addr];
    end

    always @(posedge clk or posedge reset) begin : p_protocol
        reg [31:0] ip_sum_next;
        reg [31:0] dest_ip_next;
        reg [15:0] fragment_next;
        reg [15:0] udp_len_next;
        if (reset) begin
            tx_state <= TX_IDLE; udp2app_tx_ack <= 1'b0;
            tx_length <= 0; tx_count <= 0; tx_dst_port <= 0; tx_dst_ip <= PC_IP;
            tx_dst_mac <= 0;
            tx_ident <= 0; tx_ip_checksum <= 0; tx_ip_total_length <= 0;
            tx_ip_sum <= 0; tx_csum_index <= 0;
            tx_frame_length <= 0; tx_index <= 0;
            rx_active <= 0; rx_index <= RX_IDLE; rx_ethertype <= 0;
            rx_source_ip <= 0; rx_dest_ip <= 0; rx_source_mac <= 0;
            rx_ip_length <= 0; rx_fragment <= 0; rx_ip_version <= 0;
            rx_ip_protocol <= 0; rx_ip_sum <= 0;
            rx_ip_word_hi <= 0; rx_ip_valid <= 0;
            rx_udp_src_port <= 0; rx_udp_dst_port <= 0; rx_udp_length <= 0;
            rx_udp_port_hi <= 0; rx_udp_len_hi <= 0; rx_payload_left <= 0;
            rx_payload_active <= 0;
            arp_pending <= 0;
            arp_header_valid <= 0; rx_arp_opcode <= 0;
            rx_arp_sender_mac <= 0; rx_arp_sender_ip <= 0; rx_arp_target_ip <= 0;
            arp_target_mac <= 0; arp_target_ip <= 0;
            pc_mac <= 0; pc_mac_valid <= 0;
            app_rx_data_valid <= 0; app_rx_data <= 0;
            app_rx_data_length <= 0; app_rx_port_num <= 0;
            ip_rx_error <= 0;
        end else begin
            udp2app_tx_ack <= 1'b0;
            app_rx_data_valid <= 1'b0;
            ip_rx_error <= 1'b0;

            if (temac_rx_valid) begin
                if (temac_rx_sof == 1'b0) begin
                    rx_active <= 1'b1; rx_index <= 11'd1;
                    rx_ethertype <= 0;
                    rx_source_mac <= 0; rx_source_ip <= 0; rx_dest_ip <= 0;
                    rx_arp_sender_mac <= 0; rx_arp_sender_ip <= 0; rx_arp_target_ip <= 0;
                    rx_arp_opcode <= 0; rx_ip_length <= 0; rx_fragment <= 0;
                    rx_ip_version <= 0; rx_ip_protocol <= 0; rx_ip_sum <= 0;
                    rx_ip_word_hi <= 0; rx_ip_valid <= 0;
                    rx_udp_src_port <= 0; rx_udp_dst_port <= 0; rx_udp_length <= 0;
                    rx_payload_left <= 0; rx_payload_active <= 0;
                    arp_header_valid <= 1'b1;
                end else if (rx_active) begin
                    if (rx_index >= 11'd6 && rx_index <= 11'd11)
                        rx_source_mac <= {rx_source_mac[39:0],temac_rx_data};
                    case (rx_index)
                        12: rx_ethertype[15:8] <= temac_rx_data;
                        13: rx_ethertype[7:0] <= temac_rx_data;
                        default: ;
                    endcase

                    if (rx_ethertype == 16'h0800) begin
                        case (rx_index)
                            14: rx_ip_version <= temac_rx_data;
                            16: rx_ip_length[15:8] <= temac_rx_data;
                            17: rx_ip_length[7:0] <= temac_rx_data;
                            20: rx_fragment[15:8] <= temac_rx_data;
                            21: rx_fragment[7:0] <= temac_rx_data;
                            23: rx_ip_protocol <= temac_rx_data;
                            26,27,28,29: rx_source_ip <= {rx_source_ip[23:0],temac_rx_data};
                            30,31,32: rx_dest_ip <= {rx_dest_ip[15:0],temac_rx_data};
                            33: begin
                                dest_ip_next = {rx_dest_ip[23:0],temac_rx_data};
                                fragment_next = rx_fragment;
                                ip_sum_next = rx_ip_sum + {16'd0,rx_ip_word_hi,temac_rx_data};
                                if ((rx_ip_version == 8'h45) && (rx_ip_protocol == 8'd17) &&
                                    (dest_ip_next == LOCAL_IP) && (rx_ip_length >= 16'd28) &&
                                    ((fragment_next & 16'h3fff) == 0) && ip_checksum_ok(ip_sum_next) &&
                                    ((rx_source_ip == PC_IP) ||
                                     ((rx_source_ip == DISPLAY_IP) && (rx_source_mac == DISPLAY_MAC)))) begin
                                    rx_ip_valid <= 1'b1;
                                    if (rx_source_ip == PC_IP) begin
                                        pc_mac <= rx_source_mac;
                                        pc_mac_valid <= 1'b1;
                                    end
                                end
                                else begin rx_ip_valid <= 1'b0; ip_rx_error <= 1'b1; end
                            end
                            34: rx_udp_src_port[15:8] <= temac_rx_data;
                            35: rx_udp_src_port[7:0] <= temac_rx_data;
                            36: rx_udp_port_hi <= temac_rx_data;
                            37: rx_udp_dst_port <= {rx_udp_port_hi,temac_rx_data};
                            38: rx_udp_len_hi <= temac_rx_data;
                            39: rx_udp_length <= {rx_udp_len_hi,temac_rx_data};
                            default: ;
                        endcase
                    end else if (rx_ethertype == 16'h0806) begin
                        case (rx_index)
                            14: if (temac_rx_data != 8'h00) arp_header_valid <= 1'b0;
                            15: if (temac_rx_data != 8'h01) arp_header_valid <= 1'b0;
                            16: if (temac_rx_data != 8'h08) arp_header_valid <= 1'b0;
                            17: if (temac_rx_data != 8'h00) arp_header_valid <= 1'b0;
                            18: if (temac_rx_data != 8'h06) arp_header_valid <= 1'b0;
                            19: if (temac_rx_data != 8'h04) arp_header_valid <= 1'b0;
                            20: begin rx_arp_opcode[15:8] <= temac_rx_data;
                                      if (temac_rx_data != 8'h00) arp_header_valid <= 1'b0; end
                            21: begin rx_arp_opcode[7:0] <= temac_rx_data;
                                      if (temac_rx_data != 8'h01) arp_header_valid <= 1'b0; end
                            22,23,24,25,26: rx_arp_sender_mac <= {rx_arp_sender_mac[39:0],temac_rx_data};
                            27: rx_arp_sender_mac <= {rx_arp_sender_mac[39:0],temac_rx_data};
                            28,29,30: rx_arp_sender_ip <= {rx_arp_sender_ip[23:0],temac_rx_data};
                            31: rx_arp_sender_ip <= {rx_arp_sender_ip[23:0],temac_rx_data};
                            38,39,40: rx_arp_target_ip <= {rx_arp_target_ip[15:0],temac_rx_data};
                            default: ;
                        endcase
                    end

                    if (rx_ethertype == 16'h0800 && rx_index[0] == 1'b0 &&
                        rx_index >= 11'd14 && rx_index <= 11'd32)
                        rx_ip_word_hi <= temac_rx_data;
                    if (rx_ethertype == 16'h0800 && rx_index[0] == 1'b1 &&
                        rx_index >= 11'd14 && rx_index <= 11'd33)
                        rx_ip_sum <= rx_ip_sum + {16'd0,rx_ip_word_hi,temac_rx_data};

                    if (rx_index == 11'd41 && rx_ethertype == 16'h0806) begin
                        dest_ip_next = {rx_arp_target_ip[23:0],temac_rx_data};
                        if (arp_header_valid && rx_arp_opcode == 16'd1 &&
                            (dest_ip_next == LOCAL_IP) &&
                            ((rx_arp_sender_ip == PC_IP) ||
                             ((rx_arp_sender_ip == DISPLAY_IP) &&
                              (rx_arp_sender_mac == DISPLAY_MAC)))) begin
                            arp_pending <= 1'b1;
                            arp_target_mac <= rx_arp_sender_mac;
                            arp_target_ip <= rx_arp_sender_ip;
                            if (rx_arp_sender_ip == PC_IP) begin
                                pc_mac <= rx_arp_sender_mac;
                                pc_mac_valid <= 1'b1;
                            end
                        end
                    end else if (rx_index == 11'd41 && rx_ethertype == 16'h0800) begin
                        udp_len_next = rx_udp_length;
                        if (rx_ip_valid && rx_udp_dst_port == LOCAL_PORT && udp_len_next >= 8 &&
                            udp_len_next <= rx_ip_length-16'd20) begin
                            app_rx_data_length <= udp_len_next-16'd8;
                            app_rx_port_num <= rx_udp_src_port;
                            rx_payload_left <= udp_len_next-16'd8;
                            rx_payload_active <= (udp_len_next > 16'd8);
                        end
                    end else if (rx_index >= 11'd42 && rx_payload_active && rx_payload_left != 0) begin
                        app_rx_data <= temac_rx_data;
                        app_rx_data_valid <= 1'b1;
                        rx_payload_left <= rx_payload_left-1'b1;
                        if (rx_payload_left == 1) rx_payload_active <= 1'b0;
                    end

                    rx_index <= rx_index+1'b1;
                    if (temac_rx_eof == 1'b0) begin
                        rx_active <= 1'b0;
                        rx_payload_active <= 1'b0;
                    end
                end
            end

            case (tx_state)
                TX_IDLE: begin
                    tx_count <= 0;
                    if (arp_pending) begin
                        tx_index <= 0; tx_state <= TX_ARP; arp_pending <= 1'b0;
                    end else if (app_tx_request) begin
                        udp2app_tx_ack <= 1'b1;
                        tx_count <= 0; tx_length <= 0;
                        tx_dst_port <= app_tx_dst_port; tx_dst_ip <= ip_tx_dst_address;
                        tx_dst_mac <= (ip_tx_dst_address == DISPLAY_IP) ? DISPLAY_MAC :
                                      (pc_mac_valid ? pc_mac : 48'hffffffffffff);
                        tx_state <= TX_COLLECT;
                    end
                end
                TX_COLLECT: if (app_tx_data_valid) begin
                    if (tx_count == 0) begin
                        if (app_tx_data_length > MAX_TX_PAYLOAD) begin
                            tx_state <= TX_IDLE; ip_rx_error <= 1'b1;
                        end else begin
                            tx_length <= app_tx_data_length[10:0];
                            tx_count <= 1;
                            if (app_tx_data_length <= 1) tx_state <= TX_PREP;
                        end
                    end else begin
                        tx_count <= tx_count+1'b1;
                        if (tx_count+1'b1 >= tx_length) tx_state <= TX_PREP;
                    end
                end
                TX_PREP: begin
                    tx_ip_total_length <= 16'd28 + {5'd0,tx_length};
                    tx_frame_length <= (11'd42+tx_length < 11'd60) ?
                                       11'd60 : 11'd42+tx_length;
                    tx_index <= 0; tx_ip_sum <= 32'h00004500; tx_csum_index <= 4'd1;
                    tx_state <= TX_CSUM;
                end
                // Add one IPv4 header word per cycle. A serial checksum
                // accumulator avoids the long chained adder on the 125 MHz
                // transmit-clock path; frame emission starts after the fold.
                TX_CSUM: begin
                    case(tx_csum_index)
                        4'd1: tx_ip_sum <= tx_ip_sum + tx_ip_total_length;
                        4'd2: tx_ip_sum <= tx_ip_sum + tx_ident;
                        4'd3: tx_ip_sum <= tx_ip_sum + 16'h4000;
                        4'd4: tx_ip_sum <= tx_ip_sum + 16'h4011;
                        4'd5: tx_ip_sum <= tx_ip_sum + LOCAL_IP[31:16];
                        4'd6: tx_ip_sum <= tx_ip_sum + LOCAL_IP[15:0];
                        4'd7: tx_ip_sum <= tx_ip_sum + tx_dst_ip[31:16];
                        4'd8: tx_ip_sum <= tx_ip_sum + tx_dst_ip[15:0];
                        default: tx_ip_sum <= tx_ip_sum;
                    endcase
                    if(tx_csum_index==4'd8) tx_state<=TX_FOLD;
                    else tx_csum_index<=tx_csum_index+1'b1;
                end
                TX_FOLD: begin
                    tx_ip_checksum <= finish_ip_checksum(tx_ip_sum);
                    tx_state <= TX_UDP;
                end
                TX_UDP: if (!temac_tx_ready) begin
                    if (tx_index+1'b1 >= tx_frame_length) begin
                        tx_state <= TX_IDLE; tx_ident <= tx_ident+1'b1;
                    end else tx_index <= tx_index+1'b1;
                end
                TX_ARP: if (!temac_tx_ready) begin
                    if (tx_index == 11'd59) tx_state <= TX_IDLE;
                    else tx_index <= tx_index+1'b1;
                end
                default: tx_state <= TX_IDLE;
            endcase
        end
    end
endmodule
