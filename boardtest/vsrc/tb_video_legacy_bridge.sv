`timescale 1ns/1ps
module tb_video_legacy_bridge #(parameter TX_MAILBOX=0);
    localparam ISOLATE=1;
    localparam [31:0] LOCAL_IP = 32'hc0a88902;
    localparam [47:0] LOCAL_MAC = 48'h0123456789ab;
    localparam [31:0] PEER_IP = 32'hc0a88903;
    localparam [47:0] PEER_MAC = 48'h020000000003;
    localparam [31:0] PC_IP = 32'hc0a88901;
    localparam [47:0] PC_MAC = 48'h021122334455;

    reg clk=0, reset=1;
    wire chunk_request, chunk_valid;
    wire [7:0] chunk_data;
    wire [15:0] chunk_length;
    wire owner_chunk;
    wire [15:0] app_tx_dst_port=owner_chunk?app_rx_source_port:16'd4;
    wire [31:0] ip_tx_dst_address=owner_chunk?app_rx_source_ip:PC_IP;
    wire [47:0] ip_tx_dst_mac=owner_chunk?app_rx_source_mac:PC_MAC;
    wire udp2app_tx_ready, udp2app_tx_ack;
    wire app_tx_request, app_tx_data_valid;
    wire [7:0] app_tx_data;
    wire [15:0] app_tx_data_length;
    wire chunk_ready, chunk_ack;
    wire app_rx_data_valid;
    wire [7:0] app_rx_data;
    wire [15:0] app_rx_data_length, app_rx_port_num;
    wire app_rx_packet_start, app_rx_packet_end;
    wire [47:0] app_rx_source_mac;
    wire [31:0] app_rx_source_ip;
    wire [15:0] app_rx_source_port;
    reg temac_rx_valid=0, temac_rx_sof=1, temac_rx_eof=1;
    reg [7:0] temac_rx_data=0;
    wire temac_rx_ready;
    wire temac_tx_ready;
    wire temac_tx_valid, temac_tx_sof, temac_tx_eof;
    wire [7:0] temac_tx_data;
    wire ip_rx_error, arp_request_no_reply_error;
    wire observed_valid;wire [7:0] observed_data;
    generate if(TX_MAILBOX)begin:g_mailbox
        wire mac_valid,mac_ack;wire [7:0] mac_data;reg mac_active=0;
        assign mac_ack=mac_valid&&!mac_active;
        always @(posedge clk)if(reset)mac_active<=0;else mac_active<=mac_valid;
        display_tx_packet_fifo u_mailbox(.rd_clk(clk),.rd_sreset(reset),.rd_enable(1'b1),
            .tx_data(mac_data),.tx_data_valid(mac_valid),.tx_ack(mac_ack),.tx_collision(1'b0),.tx_retransmit(1'b0),.overflow(),
            .wr_clk(clk),.wr_sreset(reset),.wr_data(temac_tx_data),.wr_sof_n(temac_tx_sof),.wr_eof_n(temac_tx_eof),
            .wr_src_rdy_n(temac_tx_valid),.wr_dst_rdy_n(temac_tx_ready),.wr_fifo_status());
        assign observed_valid=mac_valid;assign observed_data=mac_data;
    end else begin:g_direct
        assign temac_tx_ready=0;
        assign observed_valid=!temac_tx_valid&&!temac_tx_ready;assign observed_data=temac_tx_data;
    end endgenerate

    reg [7:0] rx_frame[0:1535];
    reg [7:0] tx_frame[0:127];
    reg [7:0] app_bytes[0:1535];
    reg [15:0] expected_checksum;
    integer tx_count=0, app_count=0, app_packet_starts=0, app_packet_ends=0;
    integer i, timeout_count;

    always #4 clk=~clk;

    media_tx_mux u_tx_mux (
        .clk(clk),.rst(reset),.stack_ready(udp2app_tx_ready),.stack_ack(udp2app_tx_ack),
        .ctrl_req(fb_req),.ctrl_valid(fb_valid),.ctrl_data(fb_data),.ctrl_length(fb_length),
        .ctrl_ready(),.ctrl_ack(fb_ack),.chunk_req(chunk_request),.chunk_valid(chunk_valid),
        .chunk_data(chunk_data),.chunk_length(chunk_length),.chunk_ack(chunk_ack),
        .chunk_ready(chunk_ready),.stack_req(app_tx_request),.stack_valid(app_tx_data_valid),
        .stack_data(app_tx_data),.stack_length(app_tx_data_length),.chunk_active(),.chunk_owner(owner_chunk));

    display_udp_lite #(.LOCAL_IP(LOCAL_IP),.LOCAL_MAC(LOCAL_MAC),
        .PEER_IP(PEER_IP),.PEER_MAC(PEER_MAC),.LOCAL_PORT(16'd1),.ISOLATE_VIDEO_PEER(ISOLATE)) dut (
        .clk(clk),.reset(reset),
        .udp2app_tx_ready(udp2app_tx_ready),.udp2app_tx_ack(udp2app_tx_ack),
        .app_tx_request(app_tx_request),.app_tx_data_valid(app_tx_data_valid),
        .app_tx_data(app_tx_data),.app_tx_data_length(app_tx_data_length),
        .app_tx_dst_port(app_tx_dst_port),.ip_tx_dst_address(ip_tx_dst_address),.ip_tx_dst_mac(ip_tx_dst_mac),
        .app_rx_data_valid(app_rx_data_valid),.app_rx_data(app_rx_data),
        .app_rx_data_length(app_rx_data_length),.app_rx_packet_start(app_rx_packet_start),
        .app_rx_packet_end(app_rx_packet_end),.app_rx_port_num(app_rx_port_num),
        .app_rx_source_mac(app_rx_source_mac),.app_rx_source_ip(app_rx_source_ip),
        .app_rx_source_port(app_rx_source_port),
        .temac_rx_ready(temac_rx_ready),.temac_rx_valid(temac_rx_valid),
        .temac_rx_data(temac_rx_data),.temac_rx_sof(temac_rx_sof),.temac_rx_eof(temac_rx_eof),
        .temac_tx_ready(temac_tx_ready),.temac_tx_valid(temac_tx_valid),
        .temac_tx_data(temac_tx_data),.temac_tx_sof(temac_tx_sof),.temac_tx_eof(temac_tx_eof),
        .ip_rx_error(ip_rx_error),.arp_request_no_reply_error(arp_request_no_reply_error));

    always @(negedge clk) begin
        if (!reset && observed_valid) begin
            if (tx_count < 128) tx_frame[tx_count] = observed_data;
            tx_count = tx_count + 1;
        end
        if (!reset && app_rx_data_valid) begin
            if (app_count < 1536) app_bytes[app_count] = app_rx_data;
            app_count = app_count + 1;
            if (app_rx_packet_start) app_packet_starts = app_packet_starts + 1;
            if (app_rx_packet_end) app_packet_ends = app_packet_ends + 1;
        end
    end

    function [15:0] ip_checksum;
        input [15:0] total_len;
        input [7:0] protocol;
        input [31:0] source_ip, dest_ip;
        reg [31:0] sum;
        begin
            sum=32'h4500+total_len+16'd0+16'h4000+{16'd0,8'd64,protocol}+
                source_ip[31:16]+source_ip[15:0]+dest_ip[31:16]+dest_ip[15:0];
            sum={16'd0,sum[15:0]}+{16'd0,sum[31:16]};
            sum={16'd0,sum[15:0]}+{16'd0,sum[31:16]};
            ip_checksum=~sum[15:0];
        end
    endfunction

    task send_frame(input integer length);
        integer k;
        begin
            for (k=0;k<length;k=k+1) begin
                @(negedge clk);
                temac_rx_valid=1;
                temac_rx_sof=(k==0)?1'b0:1'b1;
                temac_rx_eof=(k==length-1)?1'b0:1'b1;
                temac_rx_data=rx_frame[k];
                @(posedge clk);
            end
            @(negedge clk);
            temac_rx_valid=0;temac_rx_sof=1;temac_rx_eof=1;temac_rx_data=0;
        end
    endtask

    task wait_tx(input integer expected_count);
        integer n;
        begin
            n=0;
            while (tx_count < expected_count && n < 1000) begin
                @(negedge clk); n=n+1;
            end
            if (tx_count != expected_count) begin
                $display("FAIL TX timeout count=%0d expected=%0d",tx_count,expected_count);
                $fatal(1);
            end
        end
    endtask

    task make_arp_request;
        integer k;
        begin
            for(k=0;k<60;k=k+1)rx_frame[k]=0;
            for(k=0;k<6;k=k+1)rx_frame[k]=8'hff;
            {rx_frame[6],rx_frame[7],rx_frame[8],rx_frame[9],rx_frame[10],rx_frame[11]}=PEER_MAC;
            rx_frame[12]=8'h08;rx_frame[13]=8'h06;
            rx_frame[14]=0;rx_frame[15]=1;rx_frame[16]=8;rx_frame[17]=0;
            rx_frame[18]=6;rx_frame[19]=4;rx_frame[20]=0;rx_frame[21]=1;
            {rx_frame[22],rx_frame[23],rx_frame[24],rx_frame[25],rx_frame[26],rx_frame[27]}=PEER_MAC;
            {rx_frame[28],rx_frame[29],rx_frame[30],rx_frame[31]}=PEER_IP;
            {rx_frame[38],rx_frame[39],rx_frame[40],rx_frame[41]}=LOCAL_IP;
        end
    endtask

    task make_udp_request;
        integer k;
        reg [15:0] sum;
        begin
            for(k=0;k<60;k=k+1)rx_frame[k]=0;
            {rx_frame[0],rx_frame[1],rx_frame[2],rx_frame[3],rx_frame[4],rx_frame[5]}=LOCAL_MAC;
            {rx_frame[6],rx_frame[7],rx_frame[8],rx_frame[9],rx_frame[10],rx_frame[11]}=PEER_MAC;
            rx_frame[12]=8'h08;rx_frame[13]=0;
            rx_frame[14]=8'h45;rx_frame[15]=0;rx_frame[16]=0;rx_frame[17]=36;
            rx_frame[18]=0;rx_frame[19]=0;rx_frame[20]=8'h40;rx_frame[21]=0;
            rx_frame[22]=64;rx_frame[23]=17;
            sum=ip_checksum(36,8'd17,PEER_IP,LOCAL_IP);
            rx_frame[24]=sum[15:8];rx_frame[25]=sum[7:0];
            {rx_frame[26],rx_frame[27],rx_frame[28],rx_frame[29]}=PEER_IP;
            {rx_frame[30],rx_frame[31],rx_frame[32],rx_frame[33]}=LOCAL_IP;
            rx_frame[34]=0;rx_frame[35]=1;rx_frame[36]=0;rx_frame[37]=1;
            rx_frame[38]=0;rx_frame[39]=16;rx_frame[40]=0;rx_frame[41]=0;
            rx_frame[42]=8'haa;rx_frame[43]=8'hbb;rx_frame[44]=8'hcc;rx_frame[45]=8'hdd;
            rx_frame[46]=8'h00;rx_frame[47]=8'h31;rx_frame[48]=8'h01;rx_frame[49]=8'h02;
        end
    endtask

    task make_pc_udp_request;
        integer k;
        reg [15:0] sum;
        begin
            for(k=0;k<60;k=k+1)rx_frame[k]=0;
            {rx_frame[0],rx_frame[1],rx_frame[2],rx_frame[3],rx_frame[4],rx_frame[5]}=LOCAL_MAC;
            {rx_frame[6],rx_frame[7],rx_frame[8],rx_frame[9],rx_frame[10],rx_frame[11]}=PC_MAC;
            rx_frame[12]=8'h08;rx_frame[13]=0;
            rx_frame[14]=8'h45;rx_frame[15]=0;rx_frame[16]=0;rx_frame[17]=36;
            rx_frame[18]=0;rx_frame[19]=0;rx_frame[20]=8'h40;rx_frame[21]=0;
            rx_frame[22]=64;rx_frame[23]=17;
            sum=ip_checksum(36,8'd17,PC_IP,LOCAL_IP);
            rx_frame[24]=sum[15:8];rx_frame[25]=sum[7:0];
            {rx_frame[26],rx_frame[27],rx_frame[28],rx_frame[29]}=PC_IP;
            {rx_frame[30],rx_frame[31],rx_frame[32],rx_frame[33]}=LOCAL_IP;
            rx_frame[34]=0;rx_frame[35]=2;rx_frame[36]=0;rx_frame[37]=1;
            rx_frame[38]=0;rx_frame[39]=16;rx_frame[40]=0;rx_frame[41]=0;
            rx_frame[42]=8'haa;rx_frame[43]=8'hbb;rx_frame[44]=8'hcc;rx_frame[45]=8'hdd;
            rx_frame[46]=8'h00;rx_frame[47]=8'h31;rx_frame[48]=8'h01;rx_frame[49]=8'h02;
        end
    endtask

    task make_udp_large_request;
        integer k;
        reg [15:0] sum;
        begin
            // 1020-byte UDP payload matches the display board's maximum media
            // datagram: 8-byte app header + 253 RGB565 words.
            for(k=0;k<1062;k=k+1)rx_frame[k]=0;
            {rx_frame[0],rx_frame[1],rx_frame[2],rx_frame[3],rx_frame[4],rx_frame[5]}=LOCAL_MAC;
            {rx_frame[6],rx_frame[7],rx_frame[8],rx_frame[9],rx_frame[10],rx_frame[11]}=PEER_MAC;
            rx_frame[12]=8'h08;rx_frame[13]=0;
            rx_frame[14]=8'h45;rx_frame[15]=0;rx_frame[16]=8'h04;rx_frame[17]=8'h18;
            rx_frame[18]=0;rx_frame[19]=0;rx_frame[20]=8'h40;rx_frame[21]=0;
            rx_frame[22]=64;rx_frame[23]=17;
            sum=ip_checksum(16'd1048,8'd17,PEER_IP,LOCAL_IP);
            rx_frame[24]=sum[15:8];rx_frame[25]=sum[7:0];
            {rx_frame[26],rx_frame[27],rx_frame[28],rx_frame[29]}=PEER_IP;
            {rx_frame[30],rx_frame[31],rx_frame[32],rx_frame[33]}=LOCAL_IP;
            rx_frame[34]=0;rx_frame[35]=1;rx_frame[36]=0;rx_frame[37]=1;
            rx_frame[38]=8'h04;rx_frame[39]=8'h04;rx_frame[40]=0;rx_frame[41]=0;
            for(k=42;k<1062;k=k+1)rx_frame[k]=k-42;
        end
    endtask


    wire legacy_valid, ready_req;wire[7:0] legacy_data;
    wire fb_req,fb_valid,fb_ack;wire[7:0] fb_data;wire[15:0] fb_length;
    reg credit_event=0;reg[15:0] credit=0;
    direct_video_packet_demux #(.DROP_AUDIO(1)) demux(.clk(clk),.rst(reset),
      .rx_valid(app_rx_data_valid),.rx_data(app_rx_data),.rx_length(app_rx_data_length),
      .rx_packet_start(app_rx_packet_start),.rx_packet_end(app_rx_packet_end),
      .app_valid(legacy_valid),.app_data(legacy_data));
    media_protocol_rx #(.MULTIVIEW(1)) protocol(.clk(clk),.rst(reset),.rx_valid(legacy_valid),.rx_data(legacy_data),
      .ready_request(ready_req),.stream_word_ready(1'b1));
    media_display_tx #(.VIEW_ENABLE(1),.TX_GAP_CYCLES(4)) replies(.clk(clk),.rst(reset),
      .local_cmd_toggle_async(1'b0),.local_cmd_async(8'd0),.ready_valid(ready_req),
      .image_result_valid(1'b0),.image_result_code('0),.image_result_frame('0),
      .audio_result_valid(1'b0),.audio_result_code('0),.audio_result_frame('0),
      .control_ack_valid(1'b0),.control_ack_sequence('0),.control_ack_op('0),.control_ack_status('0),.control_ack_value('0),
      .status_valid(1'b0),.status_payload('0),.view_busy(1'b0),.view_prepare_valid(1'b0),.view_status_valid(1'b0),.view_prepare_body('0),.view_status_body('0),
      .tx_request(chunk_request),.tx_valid(chunk_valid),.tx_data(chunk_data),.tx_length(chunk_length),
      .tx_to_source(),.tx_to_owner(),.tx_ready(chunk_ready),.tx_ack(chunk_ack));
    direct_video_feedback_tx #(.READY_ENABLED(1),.CREDIT_STEP(4)) feedback(.clk(clk),.rst(reset),
      .ready_event(1'b0),.ready_sequence('0),.ready_frame('0),.nack_event(1'b0),.nack_sequence('0),
      .credit_event(credit_event),.credit_next_sequence(credit),.free_row_credits(8'd255),.health_flags('0),
      .parser_accepted('0),.parser_rejected('0),.store_accepted('0),.store_rejected('0),.duplicate_rows('0),
      .underflow_gray_async('0),.reject_reason_stats('0),.diagnostic_mode(1'b0),.video_output_stats('0),.memory_stats('0),
      .hybrid_stats('0),.readback_stats('0),.audio_stats('0),.memory_kind('0),.memory_mode(1'b0),.output_color_mode('0),
      .digest_req(fb_req),.digest_valid(fb_valid),.digest_data(fb_data),.digest_length(fb_length),.digest_ack(fb_ack));
    initial begin
      repeat(8)@(negedge clk);reset=0;repeat(8)@(negedge clk);
      make_pc_udp_request();rx_frame[46]=8'h20;rx_frame[47]=0;rx_frame[48]=0;rx_frame[49]=0;
      send_frame(60);wait_tx(60);
      if(tx_frame[42]!=8'haa||tx_frame[46]!=8'h20||tx_frame[48]!=1||tx_frame[50]!=1)
        $fatal(1,"READY reply differs after real UDP/demux/protocol/mux path");
      repeat(30)@(negedge clk);tx_count=0;
      credit=100;credit_event=1;@(negedge clk);credit_event=0;
      make_pc_udp_request();rx_frame[46]=8'h20;rx_frame[47]=0;rx_frame[48]=0;rx_frame[49]=0;
      send_frame(60);wait_tx(120);
      if(!((tx_frame[42]==8'h56&&tx_frame[102]==8'haa)||(tx_frame[42]==8'haa&&tx_frame[102]==8'h56)))
        $fatal(1,"feedback and legacy reply did not both drain");
      $display("PASS UDP -> demux -> product READY -> response/feedback mux -> UDP Ethernet output");$finish;
    end
    initial begin #100000;$fatal(1,"connected bridge timeout");end
endmodule
