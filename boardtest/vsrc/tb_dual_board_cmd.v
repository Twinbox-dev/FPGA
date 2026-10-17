`timescale 1ns/1ps

// Application-side model of the two boards.  The encrypted UDP/IP stack is
// replaced by byte streams; the actual media bridge and both eth_front copies
// remain in the test.  Checks the complete command payload across both boards.
module tb_dual_board_cmd;
    reg media_clk = 0, media_udp_clk = 0, display_udp_clk = 0;
    always #10 media_clk = ~media_clk;
    always #4  media_udp_clk = ~media_udp_clk;
    always #5  display_udp_clk = ~display_udp_clk;

    reg rst = 1;
    reg [7:0] pc_byte = 0;
    reg pc_valid = 0;
    wire [7:0] media_cmd;
    wire media_pending, media_ack_t, media_tx_tog;
    wire [63:0] media_tx_pkt;
    wire [7:0] media_tx_data;
    wire media_tx_req, media_tx_valid;
    wire [15:0] media_tx_len;
    reg media_tx_ack = 0;

    media_probe_bridge bridge (
        .clk(media_clk), .rst(rst), .cmd(media_cmd),
        .cmd_pending(media_pending), .cmd_ack_t(media_ack_t),
        .tx_tog(media_tx_tog), .tx_pkt(media_tx_pkt)
    );

    eth_front #(.TX_TYPE(16'h0001)) media_front (
        .app_rx_clk(media_udp_clk), .app_tx_clk(media_udp_clk),
        .reset(rst), .sys_rst(rst),
        .app_rx_data(pc_byte), .app_rx_data_valid(pc_valid),
        .app_rx_data_length(16'd10),
        .udp_tx_ready(1'b1), .app_tx_ack(media_tx_ack),
        .app_tx_data(media_tx_data), .app_tx_data_request(media_tx_req),
        .app_tx_data_valid(media_tx_valid), .udp_data_length(media_tx_len),
        .cmd(media_cmd), .cmd_pending(media_pending), .cmd_ack_t(media_ack_t),
        .tx_tog(media_tx_tog), .tx_pkt(media_tx_pkt),
        .tap_clk(media_clk), .tap_val(1'b0), .tap_word(32'd0), .tap_end(1'b0),
        .tap2_clk(media_clk), .tap2_val(1'b0), .tap2_word(32'd0), .tap2_end(1'b0)
    );

    reg [7:0] link_byte = 0;
    reg link_valid = 0;
    reg display_ack_t = 0;
    wire [7:0] display_cmd;
    wire display_pending;
    eth_front display_front (
        .app_rx_clk(display_udp_clk), .app_tx_clk(display_udp_clk),
        .reset(rst), .sys_rst(rst),
        .app_rx_data(link_byte), .app_rx_data_valid(link_valid),
        .app_rx_data_length(16'd16),
        .udp_tx_ready(1'b0), .app_tx_ack(1'b0),
        .app_tx_data(), .app_tx_data_request(),
        .app_tx_data_valid(), .udp_data_length(),
        .cmd(display_cmd), .cmd_pending(display_pending),
        .cmd_ack_t(display_ack_t), .tx_tog(1'b0), .tx_pkt(64'd0),
        .tap_clk(display_udp_clk), .tap_val(1'b0),
        .tap_word(32'd0), .tap_end(1'b0),
        .tap2_clk(display_udp_clk), .tap2_val(1'b0),
        .tap2_word(32'd0), .tap2_end(1'b0)
    );

    reg [7:0] capture [0:15];
    integer captured = 0;
    reg capturing = 0;
    always @(posedge media_udp_clk)
        if (capturing && media_tx_valid && captured < 16) begin
            capture[captured] = media_tx_data;
            captured = captured + 1;
        end

    task send_pc(input [7:0] command);
        reg [7:0] header [0:7];
        integer i;
        begin
            header[0]=8'haa; header[1]=8'hbb; header[2]=8'hcc;
            header[3]=8'hdd; header[4]=8'h00; header[5]=8'h01;
            header[6]=8'h00; header[7]=8'h02;
            for (i=0; i<8; i=i+1) begin
                @(negedge media_udp_clk);
                pc_byte=header[i]; pc_valid=1;
            end
            @(negedge media_udp_clk); pc_byte=command;
            @(negedge media_udp_clk); pc_byte=~command;
            @(negedge media_udp_clk); pc_byte=0; pc_valid=0;
        end
    endtask

    task roundtrip(input [7:0] command);
        integer guard, i;
        begin
            captured=0; capturing=1;
            send_pc(command);
            guard=0;
            while (!media_tx_req && guard<1000) begin
                @(negedge media_udp_clk); guard=guard+1;
            end
            if (!media_tx_req) $fatal(1, "media TX request timed out");
            @(negedge media_udp_clk); media_tx_ack=1;
            @(negedge media_udp_clk); media_tx_ack=0;
            guard=0;
            while (captured<16 && guard<1000) begin
                @(negedge media_udp_clk); guard=guard+1;
            end
            if (captured!=16 || media_tx_len!=16)
                $fatal(1, "media packet length error: %0d / %0d",captured,media_tx_len);
            capturing=0;
            if (capture[0]!=8'haa || capture[1]!=8'hbb ||
                capture[2]!=8'hcc || capture[3]!=8'hdd ||
                capture[4]!=8'h00 || capture[5]!=8'h01 ||
                capture[6]!=8'h00 || capture[7]!=8'h08 ||
                capture[8]!=command || capture[9]!=(~command))
                $fatal(1, "inter-board command frame/byte order error");
            for (i=10; i<16; i=i+1)
                if (capture[i]!=8'h00) $fatal(1, "unexpected payload byte %0d",i);

            for (i=0; i<16; i=i+1) begin
                @(negedge display_udp_clk);
                link_byte=capture[i]; link_valid=1;
            end
            @(negedge display_udp_clk); link_byte=0; link_valid=0;
            guard=0;
            while (!display_pending && guard<100) begin
                @(negedge display_udp_clk); guard=guard+1;
            end
            if (!display_pending || display_cmd!=command)
                $fatal(1, "display did not receive command %02x",command);
            @(negedge display_udp_clk); display_ack_t=~display_ack_t;
            repeat(10) @(negedge display_udp_clk);
            if (display_pending) $fatal(1, "display command mailbox not cleared");
            repeat(10) @(negedge media_udp_clk);
            if (media_pending) $fatal(1, "media command mailbox not cleared");
        end
    endtask

    integer j;
    initial begin
        repeat(12) @(negedge media_udp_clk);
        rst=0;
        repeat(12) @(negedge media_udp_clk);
        roundtrip("S");
        roundtrip("N");
        send_pc("M");
        repeat(20) @(negedge media_udp_clk);
        if (media_tx_req || media_pending)
            $fatal(1,"M diagnostic trigger leaked into command forwarding");
        // Media type 0x0010 may contain a complementary byte pair.  The
        // display command parser must ignore it entirely.
        capture[5]=8'h10;
        for (j=0; j<16; j=j+1) begin
            @(negedge display_udp_clk);
            link_byte=capture[j]; link_valid=1;
        end
        @(negedge display_udp_clk); link_byte=0; link_valid=0;
        repeat(8) @(negedge display_udp_clk);
        if (display_pending)
            $fatal(1,"media payload was mistaken for a control command");
        $display("PASS: PC -> media -> display command payload, repeated mailbox use");
        $finish;
    end
endmodule
