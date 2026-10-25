`timescale 1ns/1ps
module tb_display_udp_lite;
    localparam [31:0] LOCAL_IP = 32'hc0a88902;
    localparam [47:0] LOCAL_MAC = 48'h0123456789ab;
    localparam [31:0] PEER_IP = 32'hc0a88903;
    localparam [47:0] PEER_MAC = 48'h020000000003;
    localparam [31:0] PC_IP = 32'hc0a88901;
    localparam [47:0] PC_MAC = 48'h021122334455;

    reg clk=0, reset=1;
    reg chunk_request=0, chunk_valid=0;
    reg [7:0] chunk_data=0;
    reg [15:0] chunk_length=12, app_tx_dst_port=1;
    reg [31:0] ip_tx_dst_address=PEER_IP;
    reg [47:0] ip_tx_dst_mac=PEER_MAC;
    wire udp2app_tx_ready, udp2app_tx_ack;
    wire app_tx_request, app_tx_data_valid;
    wire [7:0] app_tx_data;
    wire [15:0] app_tx_data_length;
    wire chunk_ready, chunk_ack;
    wire app_rx_data_valid;
    wire [7:0] app_rx_data;
    wire [15:0] app_rx_data_length, app_rx_port_num;
    wire [47:0] app_rx_source_mac;
    wire [31:0] app_rx_source_ip;
    wire [15:0] app_rx_source_port;
    reg temac_rx_valid=0, temac_rx_sof=1, temac_rx_eof=1;
    reg [7:0] temac_rx_data=0;
    wire temac_rx_ready;
    reg temac_tx_ready=0; // Active low: always ready.
    wire temac_tx_valid, temac_tx_sof, temac_tx_eof;
    wire [7:0] temac_tx_data;
    wire ip_rx_error, arp_request_no_reply_error;

    reg [7:0] rx_frame[0:1535];
    reg [7:0] tx_frame[0:127];
    reg [7:0] app_bytes[0:1023];
    reg [15:0] expected_checksum;
    integer tx_count=0, app_count=0;
    integer i, timeout_count;

    always #4 clk=~clk;

    media_tx_mux u_tx_mux (
        .clk(clk),.rst(reset),.stack_ready(udp2app_tx_ready),.stack_ack(udp2app_tx_ack),
        .ctrl_req(1'b0),.ctrl_valid(1'b0),.ctrl_data(8'd0),.ctrl_length(16'd0),
        .ctrl_ready(),.ctrl_ack(),.chunk_req(chunk_request),.chunk_valid(chunk_valid),
        .chunk_data(chunk_data),.chunk_length(chunk_length),.chunk_ack(chunk_ack),
        .chunk_ready(chunk_ready),.stack_req(app_tx_request),.stack_valid(app_tx_data_valid),
        .stack_data(app_tx_data),.stack_length(app_tx_data_length),.chunk_active(),.chunk_owner());

    display_udp_lite #(.LOCAL_IP(LOCAL_IP),.LOCAL_MAC(LOCAL_MAC),
        .PEER_IP(PEER_IP),.PEER_MAC(PEER_MAC),.LOCAL_PORT(16'd1)) dut (
        .clk(clk),.reset(reset),
        .udp2app_tx_ready(udp2app_tx_ready),.udp2app_tx_ack(udp2app_tx_ack),
        .app_tx_request(app_tx_request),.app_tx_data_valid(app_tx_data_valid),
        .app_tx_data(app_tx_data),.app_tx_data_length(app_tx_data_length),
        .app_tx_dst_port(app_tx_dst_port),.ip_tx_dst_address(ip_tx_dst_address),.ip_tx_dst_mac(ip_tx_dst_mac),
        .app_rx_data_valid(app_rx_data_valid),.app_rx_data(app_rx_data),
        .app_rx_data_length(app_rx_data_length),.app_rx_port_num(app_rx_port_num),
        .app_rx_source_mac(app_rx_source_mac),.app_rx_source_ip(app_rx_source_ip),
        .app_rx_source_port(app_rx_source_port),
        .temac_rx_ready(temac_rx_ready),.temac_rx_valid(temac_rx_valid),
        .temac_rx_data(temac_rx_data),.temac_rx_sof(temac_rx_sof),.temac_rx_eof(temac_rx_eof),
        .temac_tx_ready(temac_tx_ready),.temac_tx_valid(temac_tx_valid),
        .temac_tx_data(temac_tx_data),.temac_tx_sof(temac_tx_sof),.temac_tx_eof(temac_tx_eof),
        .ip_rx_error(ip_rx_error),.arp_request_no_reply_error(arp_request_no_reply_error));

    always @(negedge clk) begin
        if (!reset && !temac_tx_valid && !temac_tx_ready) begin
            if (tx_count < 128) tx_frame[tx_count] = temac_tx_data;
            tx_count = tx_count + 1;
        end
        if (!reset && app_rx_data_valid) begin
            if (app_count < 1024) app_bytes[app_count] = app_rx_data;
            app_count = app_count + 1;
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

    initial begin
        repeat(5)@(posedge clk); reset=0;
        if (temac_rx_ready!==1'b0 || !udp2app_tx_ready) $fatal(1,"reset-ready state incorrect");

        // ARP request from the fixed media peer must receive a unicast reply.
        tx_count=0;make_arp_request();send_frame(60);wait_tx(60);
        if (tx_frame[0]!==8'h02 || tx_frame[5]!==8'h03 ||
            tx_frame[6]!==8'h01 || tx_frame[11]!==8'hab ||
            tx_frame[12]!==8'h08 || tx_frame[13]!==8'h06 ||
            tx_frame[20]!==0 || tx_frame[21]!==2 ||
            {tx_frame[28],tx_frame[29],tx_frame[30],tx_frame[31]}!==LOCAL_IP ||
            {tx_frame[38],tx_frame[39],tx_frame[40],tx_frame[41]}!==PEER_IP ||
            temac_tx_sof!==1'b1 || temac_tx_eof!==1'b1)
            $fatal(1,"ARP reply fields invalid");
        $display("PASS: ARP request/reply, static local addressing");

        // A PC host may resolve the display's address too; the reply must be
        // addressed to the ARP sender instead of the fixed media peer.
        tx_count=0;make_arp_request();
        {rx_frame[6],rx_frame[7],rx_frame[8],rx_frame[9],rx_frame[10],rx_frame[11]}=PC_MAC;
        {rx_frame[22],rx_frame[23],rx_frame[24],rx_frame[25],rx_frame[26],rx_frame[27]}=PC_MAC;
        {rx_frame[28],rx_frame[29],rx_frame[30],rx_frame[31]}=PC_IP;
        send_frame(60);wait_tx(60);
        if ({tx_frame[0],tx_frame[1],tx_frame[2],tx_frame[3],tx_frame[4],tx_frame[5]}!==PC_MAC ||
            {tx_frame[38],tx_frame[39],tx_frame[40],tx_frame[41]}!==PC_IP)
            $fatal(1,"PC ARP reply did not target its sender");
        $display("PASS: ARP reply targets dynamic PC sender");

        // Valid IPv4/UDP frame must arrive as the original application bytes.
        app_count=0;make_udp_request();send_frame(60);
        repeat(4)@(negedge clk);
        if (app_count!=8 || app_rx_data_length!=8 || app_rx_port_num!=1 ||
            app_bytes[0]!==8'haa || app_bytes[1]!==8'hbb || app_bytes[2]!==8'hcc ||
            app_bytes[3]!==8'hdd || app_bytes[4]!==0 || app_bytes[5]!==8'h31 ||
            app_bytes[6]!==1 || app_bytes[7]!==2)
            begin
                $display("UDP debug: count=%0d len=%0d port=%0d eth=%h ipok=%b iplen=%0d proto=%0d dstport=%0d udplen=%0d checksum=%h",
                    app_count,app_rx_data_length,app_rx_port_num,dut.rx_ethertype,dut.rx_ip_valid,
                    dut.rx_ip_length,dut.rx_ip_protocol,dut.rx_udp_dst_port,dut.rx_udp_length,dut.rx_ip_sum[15:0]);
                $fatal(1,"UDP receive failed count=%0d length=%0d",app_count,app_rx_data_length);
            end
        $display("PASS: IPv4 checksum and UDP length/port filtering, payload stream exact");

        app_count=0;make_udp_large_request();send_frame(1062);repeat(4)@(negedge clk);
        if(app_count!=1020 || app_rx_data_length!=1020 || app_rx_port_num!=1)
            $fatal(1,"maximum media datagram receive failed count=%0d len=%0d",app_count,app_rx_data_length);
        for(i=0;i<1020;i=i+1)if(app_bytes[i] !== i[7:0])
            $fatal(1,"large UDP payload mismatch byte=%0d got=%h",i,app_bytes[i]);
        $display("PASS: maximum 1020-byte media UDP payload streamed byte exact");

        // Invalid checksums, wrong ports, and ICMP must not reach the app or
        // trigger an outgoing response. ICMP is the one permitted feature cut.
        app_count=0;tx_count=0;make_udp_request();rx_frame[25]=rx_frame[25]^8'h01;
        send_frame(60);repeat(4)@(negedge clk);
        if(app_count!=0 || tx_count!=0)$fatal(1,"bad IPv4 checksum was accepted");
        app_count=0;tx_count=0;make_udp_request();rx_frame[37]=8'd2;
        send_frame(60);repeat(4)@(negedge clk);
        if(app_count!=0 || tx_count!=0)$fatal(1,"wrong UDP destination port was accepted");
        app_count=0;tx_count=0;make_udp_request();rx_frame[23]=8'd1;
        expected_checksum=ip_checksum(36,8'd1,PEER_IP,LOCAL_IP);
        rx_frame[24]=expected_checksum[15:8];rx_frame[25]=expected_checksum[7:0];
        send_frame(60);repeat(4)@(negedge clk);
        if(app_count!=0 || tx_count!=0)$fatal(1,"ICMP unexpectedly received a reply");
        $display("PASS: malformed IPv4/wrong UDP port rejection; ICMP omitted");

        // Learn the PC's UDP tuple and verify a later application response
        // uses its source MAC/IP/port while the media peer remains fixed.
        app_count=0;make_pc_udp_request();send_frame(60);repeat(4)@(negedge clk);
        if(app_count!=8 || app_rx_source_mac!==PC_MAC || app_rx_source_ip!==PC_IP ||
           app_rx_source_port!==16'd2)
            $fatal(1,"PC UDP sender tuple was not captured");
        $display("PASS: PC UDP source MAC/IP/port captured");

        // App response is wrapped in IPv4/UDP, padded to Ethernet minimum.
        tx_count=0;chunk_length=24;app_tx_dst_port=2;ip_tx_dst_address=PC_IP;ip_tx_dst_mac=PC_MAC;
        expected_checksum=ip_checksum(52,8'd17,LOCAL_IP,PC_IP);
        temac_tx_ready=1;
        @(negedge clk);chunk_request=1;
        timeout_count=0;
        while (!chunk_ack && timeout_count<20) begin @(negedge clk);timeout_count=timeout_count+1;end
        if (!chunk_ack) $fatal(1,"media_tx_mux packet request was not acknowledged");
        chunk_request=0;
        for(i=0;i<24;i=i+1)begin
            @(negedge clk);chunk_valid=1;chunk_data=8'h40+i;
            @(posedge clk);
        end
        @(negedge clk);chunk_valid=0;chunk_data=0;
        timeout_count=0;
        while (temac_tx_valid && timeout_count<20) begin @(negedge clk);timeout_count=timeout_count+1;end
        if (temac_tx_valid!==1'b0)$fatal(1,"UDP frame never reached the stalled output");
        repeat(4)@(negedge clk);
        if(tx_count!=0)$fatal(1,"stalled TEMAC consumed UDP frame bytes");
        temac_tx_ready=0;
        wait_tx(66);
        if ({tx_frame[0],tx_frame[1],tx_frame[2],tx_frame[3],tx_frame[4],tx_frame[5]}!==PC_MAC ||
            {tx_frame[6],tx_frame[7],tx_frame[8],tx_frame[9],tx_frame[10],tx_frame[11]}!==LOCAL_MAC ||
            tx_frame[12]!==8'h08 || tx_frame[13]!==0 || tx_frame[14]!==8'h45 ||
            {tx_frame[16],tx_frame[17]}!==16'd52 || tx_frame[23]!==17 ||
            {tx_frame[26],tx_frame[27],tx_frame[28],tx_frame[29]}!==LOCAL_IP ||
             {tx_frame[30],tx_frame[31],tx_frame[32],tx_frame[33]}!==PC_IP ||
             {tx_frame[34],tx_frame[35]}!==16'd1 || {tx_frame[36],tx_frame[37]}!==16'd2 ||
            {tx_frame[38],tx_frame[39]}!==16'd32 || tx_frame[40]!==0 || tx_frame[41]!==0)
            $fatal(1,"IPv4/UDP transmit header invalid");
        for(i=0;i<24;i=i+1)if(tx_frame[42+i] !== (8'h40+i))$fatal(1,"TX payload byte %0d mismatch",i);
        if ({tx_frame[24],tx_frame[25]}!==expected_checksum)
            $fatal(1,"TX IPv4 checksum mismatch got=%h%h expected=%h",tx_frame[24],tx_frame[25],expected_checksum);
        $display("PASS: UDP TX header, payload, Ethernet padding and TEMAC-side active-low handshake");

        $display("PASS: display UDP-lite ARP/IPv4/UDP transaction tests");
        $finish;
    end
endmodule
