`timescale 1ns/1ps

module tb_media_display_tx;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg local_cmd_toggle_async=0;
    reg [7:0] local_cmd_async=0;
    reg ready_valid=0, image_result_valid=0, audio_result_valid=0;
    reg [7:0] image_result_code=0,audio_result_code=0;
    reg [15:0] image_result_frame=16'h1234,audio_result_frame=16'h1234;
    reg control_ack_valid=0;
    reg [7:0] control_ack_sequence=0,control_ack_op=0,control_ack_status=0,control_ack_value=0;
    reg status_valid=0;
    reg [63:0] status_payload=0;
    reg view_status_valid=0;
    reg [127:0] view_status_body=128'h0102030405060708090a0b0c0d0e0f10;
    wire tx_request,tx_valid,tx_ack;
    reg tx_ready=1;
    wire [7:0] tx_data;
    wire [15:0] tx_length;
    wire tx_to_source;
    wire tx_to_owner;

    media_display_tx #(.TX_GAP_CYCLES(4),.VIEW_ENABLE(1)) dut(
        .view_busy(1'b0),.view_prepare_valid(1'b0),.view_prepare_body(64'd0),.view_status_valid(view_status_valid),.view_status_body(view_status_body),.*);
    assign tx_ack=tx_request;
    reg [7:0] packets[0:16][0:23];
    reg routes_source[0:16],routes_owner[0:16];
    integer packet_lengths[0:16];
    integer packet_count=0, byte_count=0;
    reg in_packet=0;
    always @(posedge clk) begin
        if (tx_valid) begin
            if(byte_count==0)begin routes_source[packet_count]=tx_to_source;routes_owner[packet_count]=tx_to_owner;end
            packets[packet_count][byte_count]=tx_data;
            byte_count=byte_count+1;
            in_packet=1;
        end else if (in_packet) begin
            packet_lengths[packet_count]=byte_count;
            packet_count=packet_count+1;
            byte_count=0;
            in_packet=0;
        end
    end

    task automatic pulse(input integer selector);
        begin
            @(negedge clk);
            case(selector)
                0: ready_valid=1;
                1: begin image_result_valid=1; image_result_code=0; end
                2: begin audio_result_valid=1; audio_result_code=0; image_result_valid=1; image_result_code=2; end
                3: begin control_ack_valid=1; control_ack_sequence=8'h31; control_ack_op=8'd4; control_ack_status=0; control_ack_value=2; end
                4: begin status_valid=1; status_payload=64'h0706050403020100; end
                5: view_status_valid=1;
                default: ;
            endcase
            @(negedge clk);
            ready_valid=0; image_result_valid=0; audio_result_valid=0; view_status_valid=0;
            control_ack_valid=0; status_valid=0;
        end
    endtask

    task automatic check_header(input integer n,input [7:0] kind,input [15:0] len);
        begin
            if (packet_lengths[n] != ({16'd0,len}+32'd8) || packets[n][0]!=8'haa ||
                packets[n][1]!=8'hbb || packets[n][2]!=8'hcc || packets[n][3]!=8'hdd ||
                ((kind==8'h01 || kind==8'h41 || kind==8'h43 || kind==8'h48 || kind==8'h4a) ?
                    (packets[n][4]!=0 || packets[n][5]!=kind ||
                     packets[n][6]!=len[15:8] || packets[n][7]!=len[7:0]) :
                    (packets[n][4]!=kind || packets[n][5]!=0 ||
                     packets[n][6]!=len[7:0] || packets[n][7]!=len[15:8])))
                $fatal(1,"packet %0d header/type %h length %0d",n,packets[n][4],packet_lengths[n]);
        end
    endtask

    initial begin
        repeat(4) @(negedge clk); rst=0;
        pulse(0); wait(packet_count==1);
        check_header(0,8'h20,1);
        if (!tx_to_source) $fatal(1,"READY response was not marked for request source");
        if(packets[0][8]!=1) $fatal(1,"READY payload");
        pulse(1); wait(packet_count==2);
        check_header(1,8'h24,3);
        if (!tx_to_owner) $fatal(1,"image result was not marked for transaction owner");
        if(packets[1][8]!=8'h34 || packets[1][9]!=8'h12 || packets[1][10]!=0)
            $fatal(1,"image accept result");
        pulse(2); wait(packet_count==6);
        check_header(2,8'h33,3);
        if(packets[2][10]!=0) $fatal(1,"audio result ordering");
        for(integer i=3;i<=5;i=i+1) begin
            check_header(i,8'h24,3);
            if(packets[i][8]!=8'h34 || packets[i][9]!=8'h12 || packets[i][10]!=2)
                $fatal(1,"final image commit result copy %0d",i-2);
        end
        pulse(3); wait(packet_count==7);
        check_header(6,8'h41,4);
        if(packets[6][8]!=8'h31 || packets[6][9]!=4 || packets[6][10]!=0 || packets[6][11]!=2)
            $fatal(1,"control ACK payload");
        pulse(4); wait(packet_count==8);
        check_header(7,8'h43,8);
        if(packets[7][8]!=0 || packets[7][15]!=7) $fatal(1,"status payload byte order");

        pulse(5); wait(packet_count==10);
        check_header(8,8'h48,16);check_header(9,8'h48,16);
        if(!routes_source[8] || routes_owner[8] || routes_source[9] || routes_owner[9])
            $fatal(1,"VIEW_STATUS must go both to requester and fixed media peer");
        if(packets[8][8]!=8'h10 || packets[9][8]!=8'h10)
            $fatal(1,"VIEW_STATUS body was not duplicated intact");

        @(negedge clk); local_cmd_async=8'h41; local_cmd_toggle_async=~local_cmd_toggle_async;
        wait(packet_count==11);
        check_header(10,8'h01,2);
        if (routes_source[10] || routes_owner[10]) $fatal(1,"local touch command was routed away from media peer");
        if(packets[10][8]!=8'h41 || packets[10][9]!=8'hbe) $fatal(1,"local next command");
        $display("PASS: replies, commits, duplicated VIEW_STATUS routes and local touch command");
        $finish;
    end
    initial begin #200000; $fatal(1,"timeout"); end
endmodule
