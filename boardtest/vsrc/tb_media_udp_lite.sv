module tb_media_udp_lite;
    localparam [31:0] LOCAL_IP=32'hc0a88903;
    localparam [47:0] LOCAL_MAC=48'h020000000003;
    localparam [31:0] PC_IP=32'hc0a88901;
    localparam [47:0] PC_MAC=48'h5c263a112233;
    localparam [31:0] DISPLAY_IP=32'hc0a88902;
    localparam [47:0] DISPLAY_MAC=48'h0123456789ab;

    reg clk=0, reset=1;
    reg app_tx_request=0, app_tx_data_valid=0;
    reg [7:0] app_tx_data=0;
    reg [15:0] app_tx_data_length=0, app_tx_dst_port=0;
    reg [31:0] ip_tx_dst_address=0;
    wire udp2app_tx_ready, udp2app_tx_ack;
    wire app_rx_data_valid;
    wire [7:0] app_rx_data;
    wire [15:0] app_rx_data_length, app_rx_port_num;
    reg temac_rx_valid=0, temac_rx_sof=1, temac_rx_eof=1;
    reg [7:0] temac_rx_data=0;
    wire temac_rx_ready;
    reg temac_tx_ready=0; // Active low: always ready unless a test stalls it.
    wire temac_tx_valid, temac_tx_sof, temac_tx_eof;
    wire [7:0] temac_tx_data;
    wire ip_rx_error, arp_request_no_reply_error;

    reg [7:0] rx_frame[0:1535];
    reg [7:0] tx_frame[0:1535];
    reg [7:0] app_bytes[0:1023];
    integer tx_count=0, app_count=0, i;

    always #4 clk=~clk;

    media_udp_lite #(.LOCAL_IP(LOCAL_IP),.LOCAL_MAC(LOCAL_MAC),
        .PC_IP(PC_IP),.DISPLAY_IP(DISPLAY_IP),.DISPLAY_MAC(DISPLAY_MAC),
        .LOCAL_PORT(16'd1),.MAX_TX_PAYLOAD(16'd1024)) dut (
        .clk(clk),.reset(reset),
        .udp2app_tx_ready(udp2app_tx_ready),.udp2app_tx_ack(udp2app_tx_ack),
        .app_tx_request(app_tx_request),.app_tx_data_valid(app_tx_data_valid),
        .app_tx_data(app_tx_data),.app_tx_data_length(app_tx_data_length),
        .app_tx_dst_port(app_tx_dst_port),.ip_tx_dst_address(ip_tx_dst_address),
        .app_rx_data_valid(app_rx_data_valid),.app_rx_data(app_rx_data),
        .app_rx_data_length(app_rx_data_length),.app_rx_port_num(app_rx_port_num),
        .temac_rx_ready(temac_rx_ready),.temac_rx_valid(temac_rx_valid),
        .temac_rx_data(temac_rx_data),.temac_rx_sof(temac_rx_sof),.temac_rx_eof(temac_rx_eof),
        .temac_tx_ready(temac_tx_ready),.temac_tx_valid(temac_tx_valid),
        .temac_tx_data(temac_tx_data),.temac_tx_sof(temac_tx_sof),.temac_tx_eof(temac_tx_eof),
        .ip_rx_error(ip_rx_error),.arp_request_no_reply_error(arp_request_no_reply_error));

    always @(negedge clk) begin
        if (!reset && !temac_tx_valid && !temac_tx_ready) begin
            if (tx_count < 1536) tx_frame[tx_count]=temac_tx_data;
            tx_count=tx_count+1;
        end
        if (!reset && app_rx_data_valid) begin
            if (app_count < 1024) app_bytes[app_count]=app_rx_data;
            app_count=app_count+1;
        end
    end

    function [15:0] ip_checksum;
        input [15:0] total_len,ident;
        input [31:0] source_ip,dest_ip;
        reg [31:0] sum;
        begin
            sum=32'h4500+total_len+ident+32'h00004000+32'h00004011+
                source_ip[31:16]+source_ip[15:0]+dest_ip[31:16]+dest_ip[15:0];
            sum={16'd0,sum[15:0]}+{16'd0,sum[31:16]};
            sum={16'd0,sum[15:0]}+{16'd0,sum[31:16]};
            ip_checksum=~sum[15:0];
        end
    endfunction

    task send_frame;
        input integer length;
        integer k;
        begin
            for(k=0;k<length;k=k+1)begin
                @(negedge clk);temac_rx_valid=1;temac_rx_sof=(k==0)?0:1;
                temac_rx_eof=(k==length-1)?0:1;temac_rx_data=rx_frame[k];
                @(posedge clk);
            end
            @(negedge clk);temac_rx_valid=0;temac_rx_sof=1;temac_rx_eof=1;temac_rx_data=0;
        end
    endtask

    task wait_tx;
        input integer expected;
        integer n;
        begin
            n=0;
            while(tx_count<expected && n<4000)begin @(negedge clk);n=n+1;end
            if(tx_count!=expected)$fatal(1,"TX timeout got=%0d expected=%0d",tx_count,expected);
        end
    endtask

    task make_arp_request;
        input [47:0] sender_mac;
        input [31:0] sender_ip;
        integer k;
        begin
            for(k=0;k<60;k=k+1)rx_frame[k]=0;
            for(k=0;k<6;k=k+1)rx_frame[k]=8'hff;
            {rx_frame[6],rx_frame[7],rx_frame[8],rx_frame[9],rx_frame[10],rx_frame[11]}=sender_mac;
            rx_frame[12]=8'h08;rx_frame[13]=8'h06;
            rx_frame[14]=0;rx_frame[15]=1;rx_frame[16]=8;rx_frame[17]=0;
            rx_frame[18]=6;rx_frame[19]=4;rx_frame[20]=0;rx_frame[21]=1;
            {rx_frame[22],rx_frame[23],rx_frame[24],rx_frame[25],rx_frame[26],rx_frame[27]}=sender_mac;
            {rx_frame[28],rx_frame[29],rx_frame[30],rx_frame[31]}=sender_ip;
            {rx_frame[38],rx_frame[39],rx_frame[40],rx_frame[41]}=LOCAL_IP;
        end
    endtask

    task make_udp;
        input [47:0] sender_mac;
        input [31:0] sender_ip;
        input [15:0] sender_port,dest_port,payload_len;
        output integer frame_len;
        integer k;
        reg [15:0] total_len,udp_len,check;
        begin
            total_len=16'd28+payload_len;
            udp_len=16'd8+payload_len;
            frame_len=14+total_len;
            if(frame_len<60)frame_len=60;
            for(k=0;k<frame_len;k=k+1)rx_frame[k]=0;
            {rx_frame[0],rx_frame[1],rx_frame[2],rx_frame[3],rx_frame[4],rx_frame[5]}=LOCAL_MAC;
            {rx_frame[6],rx_frame[7],rx_frame[8],rx_frame[9],rx_frame[10],rx_frame[11]}=sender_mac;
            rx_frame[12]=8'h08;rx_frame[13]=0;rx_frame[14]=8'h45;rx_frame[15]=0;
            rx_frame[16]=total_len[15:8];rx_frame[17]=total_len[7:0];
            rx_frame[18]=0;rx_frame[19]=0;rx_frame[20]=8'h40;rx_frame[21]=0;
            rx_frame[22]=64;rx_frame[23]=17;check=ip_checksum(total_len,16'd0,sender_ip,LOCAL_IP);
            rx_frame[24]=check[15:8];rx_frame[25]=check[7:0];
            {rx_frame[26],rx_frame[27],rx_frame[28],rx_frame[29]}=sender_ip;
            {rx_frame[30],rx_frame[31],rx_frame[32],rx_frame[33]}=LOCAL_IP;
            rx_frame[34]=sender_port[15:8];rx_frame[35]=sender_port[7:0];
            rx_frame[36]=dest_port[15:8];rx_frame[37]=dest_port[7:0];
            rx_frame[38]=udp_len[15:8];rx_frame[39]=udp_len[7:0];
            rx_frame[40]=0;rx_frame[41]=0;
            for(k=0;k<payload_len;k=k+1)rx_frame[42+k]=k[7:0]^8'h6d;
        end
    endtask

    task send_app_packet;
        input [31:0] destination_ip;
        input [15:0] destination_port,length;
        integer k,n;
        begin
            ip_tx_dst_address=destination_ip;app_tx_dst_port=destination_port;
            app_tx_data_length=length;app_tx_request=1;
            n=0;
            while(!udp2app_tx_ack && n<100)begin @(negedge clk);n=n+1;end
            if(!udp2app_tx_ack)$fatal(1,"application transmit request was not acknowledged");
            app_tx_request=0;
            for(k=0;k<length;k=k+1)begin
                @(negedge clk);app_tx_data_valid=1;app_tx_data=k[7:0]^8'h93;
                @(posedge clk);
            end
            @(negedge clk);app_tx_data_valid=0;app_tx_data=0;
        end
    endtask

    task check_tx_header;
        input [31:0] destination_ip;
        input [47:0] destination_mac;
        input [15:0] destination_port,length;
        integer expected_frame,k;
        reg [15:0] check;
        begin
            expected_frame=42+length;if(expected_frame<60)expected_frame=60;
            wait_tx(expected_frame);
            if({tx_frame[0],tx_frame[1],tx_frame[2],tx_frame[3],tx_frame[4],tx_frame[5]}!==destination_mac)
                $fatal(1,"TX destination MAC mismatch got=%h expected=%h",
                    {tx_frame[0],tx_frame[1],tx_frame[2],tx_frame[3],tx_frame[4],tx_frame[5]},destination_mac);
            if({tx_frame[6],tx_frame[7],tx_frame[8],tx_frame[9],tx_frame[10],tx_frame[11]}!==LOCAL_MAC ||
               tx_frame[12]!==8'h08 || tx_frame[13]!==0 || tx_frame[14]!==8'h45 ||
               {tx_frame[16],tx_frame[17]}!==(16'd28+length) || tx_frame[23]!==17 ||
               {tx_frame[26],tx_frame[27],tx_frame[28],tx_frame[29]}!==LOCAL_IP ||
               {tx_frame[30],tx_frame[31],tx_frame[32],tx_frame[33]}!==destination_ip ||
               {tx_frame[34],tx_frame[35]}!==16'd1 ||
               {tx_frame[36],tx_frame[37]}!==destination_port ||
               {tx_frame[38],tx_frame[39]}!==(16'd8+length) ||
               tx_frame[40]!==0 || tx_frame[41]!==0)
                $fatal(1,"TX IPv4/UDP header mismatch");
            check=ip_checksum(16'd28+length,{tx_frame[18],tx_frame[19]},LOCAL_IP,destination_ip);
            if({tx_frame[24],tx_frame[25]}!==check)
                $fatal(1,"TX IP checksum mismatch got=%h expected=%h id=%h%h dutid=%h dst=%h src=%h total=%h",
                    {tx_frame[24],tx_frame[25]},check,tx_frame[18],tx_frame[19],dut.tx_ident,
                    {tx_frame[30],tx_frame[31],tx_frame[32],tx_frame[33]},
                    {tx_frame[26],tx_frame[27],tx_frame[28],tx_frame[29]},
                    {tx_frame[16],tx_frame[17]});
            for(k=0;k<length;k=k+1)
                if(tx_frame[42+k] !== (k[7:0]^8'h93))
                    $fatal(1,"TX payload mismatch at %0d",k);
        end
    endtask

    integer frame_len;
    initial begin
        repeat(5)@(posedge clk);reset=0;
        if(temac_rx_ready!==0 || !udp2app_tx_ready)$fatal(1,"unexpected ready after reset");

        // Learn the PC MAC and verify a dynamic ARP reply.
        tx_count=0;make_arp_request(PC_MAC,PC_IP);send_frame(60);wait_tx(60);
        if({tx_frame[0],tx_frame[1],tx_frame[2],tx_frame[3],tx_frame[4],tx_frame[5]}!==PC_MAC ||
           {tx_frame[6],tx_frame[7],tx_frame[8],tx_frame[9],tx_frame[10],tx_frame[11]}!==LOCAL_MAC ||
           tx_frame[21]!==2 || {tx_frame[38],tx_frame[39],tx_frame[40],tx_frame[41]}!==PC_IP)
            $fatal(1,"PC ARP reply mismatch");
        $display("PASS: PC ARP learning and unicast reply");

        // The display board is a second fixed peer on the same application port.
        tx_count=0;make_arp_request(DISPLAY_MAC,DISPLAY_IP);send_frame(60);wait_tx(60);
        if({tx_frame[0],tx_frame[1],tx_frame[2],tx_frame[3],tx_frame[4],tx_frame[5]}!==DISPLAY_MAC ||
           {tx_frame[6],tx_frame[7],tx_frame[8],tx_frame[9],tx_frame[10],tx_frame[11]}!==LOCAL_MAC)
            $fatal(1,"display ARP reply mismatch");
        $display("PASS: display peer ARP reply");

        tx_count=0;make_arp_request(48'h001122334455,32'hc0a88977);
        send_frame(60);repeat(3)@(negedge clk);
        if(tx_count!=0)$fatal(1,"unknown ARP peer unexpectedly received a reply");
        $display("PASS: unknown ARP peer rejected");

        app_count=0;make_udp(PC_MAC,PC_IP,16'd2,16'd1,16'd8,frame_len);
        send_frame(frame_len);repeat(3)@(negedge clk);
        if(app_count!=8 || app_rx_data_length!=8 || app_rx_port_num!=2)begin
            $display("RX debug eth=%h ipok=%b src=%h dst=%h sum=%h sport=%h dport=%h ulen=%h idx=%0d",
                dut.rx_ethertype,dut.rx_ip_valid,dut.rx_source_ip,dut.rx_dest_ip,
                dut.rx_ip_sum,dut.rx_udp_src_port,dut.rx_udp_dst_port,dut.rx_udp_length,dut.rx_index);
            $display("RX checksum bytes=%h%h expected=%h",
                rx_frame[24],rx_frame[25],ip_checksum(16'd36,16'd0,PC_IP,LOCAL_IP));
            for(i=14;i<34;i=i+1)$write("%02x",rx_frame[i]);$write("\n");
            $fatal(1,"PC UDP receive failed count=%0d length=%0d",app_count,app_rx_data_length);
        end
        for(i=0;i<8;i=i+1)if(app_bytes[i] !== (i[7:0]^8'h6d))$fatal(1,"PC RX payload mismatch");
        $display("PASS: PC UDP control receive");

        app_count=0;make_udp(DISPLAY_MAC,DISPLAY_IP,16'd1,16'd1,16'd8,frame_len);
        send_frame(frame_len);repeat(3)@(negedge clk);
        if(app_count!=8 || app_rx_port_num!=1)$fatal(1,"display UDP result receive failed");
        $display("PASS: display UDP status/result receive");

        // Maximum media-sized datagram is streamed to eth_front without truncation.
        app_count=0;make_udp(PC_MAC,PC_IP,16'd2,16'd1,16'd1022,frame_len);
        send_frame(frame_len);repeat(3)@(negedge clk);
        if(app_count!=1022 || app_rx_data_length!=1022)$fatal(1,"1022-byte RX failed count=%0d",app_count);
        for(i=0;i<1022;i=i+1)if(app_bytes[i] !== (i[7:0]^8'h6d))$fatal(1,"large RX mismatch at %0d",i);
        $display("PASS: 1022-byte maximum RX stream");

        app_count=0;make_udp(PC_MAC,PC_IP,16'd2,16'd2,16'd8,frame_len);
        send_frame(frame_len);repeat(3)@(negedge clk);
        if(app_count!=0)$fatal(1,"wrong UDP port accepted");
        app_count=0;make_udp(48'h001122334455,32'hc0a88977,16'd2,16'd1,16'd8,frame_len);
        send_frame(frame_len);repeat(3)@(negedge clk);
        if(app_count!=0)$fatal(1,"unknown source accepted");
        app_count=0;make_udp(PC_MAC,PC_IP,16'd2,16'd1,16'd8,frame_len);
        rx_frame[25]=rx_frame[25]^8'h01;
        send_frame(frame_len);repeat(3)@(negedge clk);
        if(app_count!=0)$fatal(1,"bad IPv4 checksum accepted");
        $display("PASS: wrong-port, bad-checksum, and unknown-peer filtering");

        tx_count=0;send_app_packet(PC_IP,16'd2,16'd16);check_tx_header(PC_IP,PC_MAC,16'd2,16'd16);
        $display("PASS: UDP TX to learned PC MAC");

        tx_count=0;temac_tx_ready=1;
        send_app_packet(PC_IP,16'd2,16'd1022);
        repeat(10)@(negedge clk);
        if(tx_count!=0)$fatal(1,"PC maximum UDP frame ignored TEMAC backpressure");
        temac_tx_ready=0;
        check_tx_header(PC_IP,PC_MAC,16'd2,16'd1022);
        $display("PASS: 1022-byte UDP TX to PC, including D-sized datagrams");

        tx_count=0;temac_tx_ready=1;
        send_app_packet(DISPLAY_IP,16'd1,16'd1022);
        repeat(10)@(negedge clk);
        if(tx_count!=0)$fatal(1,"TEMAC backpressure was ignored");
        temac_tx_ready=0;
        check_tx_header(DISPLAY_IP,DISPLAY_MAC,16'd1,16'd1022);
        $display("PASS: 1022-byte UDP TX to display, checksum and backpressure");

        $display("PASS: media UDP-lite dual-peer transaction tests");
        $finish;
    end
endmodule
