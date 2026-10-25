module tb_media_udp_lite_ethfront;
    localparam [31:0] LOCAL_IP=32'hc0a88903;
    localparam [47:0] LOCAL_MAC=48'h020000000003;
    localparam [31:0] PC_IP=32'hc0a88901;
    localparam [47:0] PC_MAC=48'h5c263a112233;
    reg clk=0,reset=1;
    reg [7:0] rx_data=0;
    reg rx_valid=0,rx_sof=1,rx_eof=1;
    wire rx_ready;
    wire [7:0] app_rx_data;
    wire app_rx_valid;
    wire [15:0] app_rx_length;
    wire udp_ready,udp_ack;
    wire [7:0] app_tx_data;
    wire app_tx_valid,app_tx_request;
    wire [15:0] app_tx_length;
    wire app_rx_err,arp_err;
    reg tx_ready=0;
    wire [7:0] tx_data;
    wire tx_valid,tx_sof,tx_eof;
    wire [7:0] cmd;
    wire cmd_pending;
    reg cmd_ack=0,tx_tog=0;
    reg [15:0] tx_type=16'h0002,tx_payload_len=16'd8;
    reg [63:0] tx_pkt=64'h0807060504030201;
    wire tx_done_tog;
    reg [7:0] rx_frame[0:63];
    reg [7:0] tx_frame[0:127];
    integer tx_count=0,k,n;
    always #4 clk=~clk;

    media_udp_lite #(.LOCAL_IP(LOCAL_IP),.LOCAL_MAC(LOCAL_MAC),.PC_IP(PC_IP),
        .DISPLAY_IP(32'hc0a88902),.DISPLAY_MAC(48'h0123456789ab),.LOCAL_PORT(16'd1)) net (
        .clk(clk),.reset(reset),.udp2app_tx_ready(udp_ready),.udp2app_tx_ack(udp_ack),
        .app_tx_request(app_tx_request),.app_tx_data_valid(app_tx_valid),.app_tx_data(app_tx_data),
        .app_tx_data_length(app_tx_length),.app_tx_dst_port(16'd2),.ip_tx_dst_address(PC_IP),
        .app_rx_data_valid(app_rx_valid),.app_rx_data(app_rx_data),.app_rx_data_length(app_rx_length),
        .app_rx_port_num(),.temac_rx_ready(rx_ready),.temac_rx_valid(rx_valid),.temac_rx_data(rx_data),
        .temac_rx_sof(rx_sof),.temac_rx_eof(rx_eof),.temac_tx_ready(tx_ready),
        .temac_tx_valid(tx_valid),.temac_tx_data(tx_data),.temac_tx_sof(tx_sof),.temac_tx_eof(tx_eof),
        .ip_rx_error(app_rx_err),.arp_request_no_reply_error(arp_err));

    eth_front app (
        .app_rx_clk(clk),.app_tx_clk(clk),.reset(reset),.sys_rst(reset),
        .app_rx_data(app_rx_data),.app_rx_data_valid(app_rx_valid),.app_rx_data_length(app_rx_length),
        .udp_tx_ready(udp_ready),.app_tx_ack(udp_ack),.app_tx_data(app_tx_data),
        .app_tx_data_request(app_tx_request),.app_tx_data_valid(app_tx_valid),.udp_data_length(app_tx_length),
        .cmd(cmd),.cmd_pending(cmd_pending),.cmd_ack_t(cmd_ack),.tx_tog(tx_tog),
        .tx_type(tx_type),.tx_payload_len(tx_payload_len),.tx_pkt(tx_pkt),.tx_done_tog(tx_done_tog),
        .tap_clk(clk),.tap_val(1'b0),.tap_word(32'd0),.tap_end(1'b0),
        .tap2_clk(clk),.tap2_val(1'b0),.tap2_word(32'd0),.tap2_end(1'b0));

    always @(negedge clk)
        if(!reset && !tx_valid && !tx_ready) begin
            if(tx_count<128)tx_frame[tx_count]=tx_data;
            tx_count=tx_count+1;
        end

    function [15:0] ip_checksum;
        input [15:0] total_len;
        input [31:0] source_ip,dest_ip;
        reg [31:0] sum;
        begin
            sum=32'h4500+total_len+32'h4000+32'h4011+
                source_ip[31:16]+source_ip[15:0]+dest_ip[31:16]+dest_ip[15:0];
            sum={16'd0,sum[15:0]}+{16'd0,sum[31:16]};
            sum={16'd0,sum[15:0]}+{16'd0,sum[31:16]};
            ip_checksum=~sum[15:0];
        end
    endfunction

    task send_control;
        reg [15:0] sum;
        integer j;
        begin
            for(j=0;j<60;j=j+1)rx_frame[j]=0;
            {rx_frame[0],rx_frame[1],rx_frame[2],rx_frame[3],rx_frame[4],rx_frame[5]}=LOCAL_MAC;
            {rx_frame[6],rx_frame[7],rx_frame[8],rx_frame[9],rx_frame[10],rx_frame[11]}=PC_MAC;
            rx_frame[12]=8'h08;rx_frame[13]=0;rx_frame[14]=8'h45;
            rx_frame[16]=0;rx_frame[17]=38;rx_frame[20]=8'h40;rx_frame[22]=64;rx_frame[23]=17;
            sum=ip_checksum(38,PC_IP,LOCAL_IP);rx_frame[24]=sum[15:8];rx_frame[25]=sum[7:0];
            {rx_frame[26],rx_frame[27],rx_frame[28],rx_frame[29]}=PC_IP;
            {rx_frame[30],rx_frame[31],rx_frame[32],rx_frame[33]}=LOCAL_IP;
            rx_frame[34]=0;rx_frame[35]=2;rx_frame[36]=0;rx_frame[37]=1;
            rx_frame[38]=0;rx_frame[39]=18;
            rx_frame[42]=8'hAA;rx_frame[43]=8'hBB;rx_frame[44]=8'hCC;rx_frame[45]=8'hDD;
            rx_frame[46]=0;rx_frame[47]=1;rx_frame[48]=0;rx_frame[49]=2;
            rx_frame[50]=8'h4E;rx_frame[51]=8'hB1;
            for(j=0;j<60;j=j+1)begin
                @(negedge clk);rx_valid=1;rx_sof=(j==0)?0:1;rx_eof=(j==59)?0:1;rx_data=rx_frame[j];
                @(posedge clk);
            end
            @(negedge clk);rx_valid=0;rx_sof=1;rx_eof=1;rx_data=0;
        end
    endtask

    initial begin
        repeat(6)@(posedge clk);reset=0;
        send_control();
        n=0;while(!cmd_pending && n<100)begin @(negedge clk);n=n+1;end
        if(!cmd_pending || cmd!==8'h4E)$fatal(1,"eth_front failed to decode PC command");
        $display("PASS: PC Ethernet UDP command reaches media eth_front");
        @(negedge clk);cmd_ack=~cmd_ack;
        repeat(5)@(negedge clk);

        tx_count=0;@(negedge clk);tx_tog=~tx_tog;
        n=0;while(tx_count<60 && n<2000)begin @(negedge clk);n=n+1;end
        if(tx_count!=60)$fatal(1,"eth_front response did not transmit, count=%0d",tx_count);
        if({tx_frame[0],tx_frame[1],tx_frame[2],tx_frame[3],tx_frame[4],tx_frame[5]}!==PC_MAC ||
           {tx_frame[26],tx_frame[27],tx_frame[28],tx_frame[29]}!==LOCAL_IP ||
           {tx_frame[30],tx_frame[31],tx_frame[32],tx_frame[33]}!==PC_IP ||
           tx_frame[42]!==8'hAA || tx_frame[43]!==8'hBB || tx_frame[44]!==8'hCC ||
           tx_frame[45]!==8'hDD || tx_frame[46]!==0 || tx_frame[47]!==2 ||
           tx_frame[48]!==0 || tx_frame[49]!==8 || tx_frame[50]!==1 || tx_frame[57]!==8)
            $fatal(1,"eth_front response payload/destination mismatch");
        $display("PASS: real eth_front response is wrapped and returned to learned PC MAC");
        $display("PASS: media UDP-lite application integration");
        $finish;
    end
endmodule
