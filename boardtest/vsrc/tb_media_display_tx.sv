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
    wire tx_request,tx_valid,tx_ack;
    reg tx_ready=1;
    wire [7:0] tx_data;
    wire [15:0] tx_length;

    media_display_tx #(.TX_GAP_CYCLES(4)) dut(
        .view_busy(1'b0),.view_prepare_valid(1'b0),.view_prepare_body(64'd0),.view_status_valid(1'b0),.view_status_body(128'd0),.*);
    assign tx_ack=tx_request;
    reg [7:0] packets[0:8][0:15];
    integer packet_lengths[0:8];
    integer packet_count=0, byte_count=0;
    reg in_packet=0;
    always @(posedge clk) begin
        if (tx_valid) begin
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
                default: ;
            endcase
            @(negedge clk);
            ready_valid=0; image_result_valid=0; audio_result_valid=0;
            control_ack_valid=0; status_valid=0;
        end
    endtask

    task automatic check_header(input integer n,input [7:0] kind,input [15:0] len);
        begin
            if (packet_lengths[n] != ({16'd0,len}+32'd8) || packets[n][0]!=8'haa ||
                packets[n][1]!=8'hbb || packets[n][2]!=8'hcc || packets[n][3]!=8'hdd ||
                ((kind==8'h01 || kind==8'h41 || kind==8'h43) ?
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
        if(packets[0][8]!=1) $fatal(1,"READY payload");
        pulse(1); wait(packet_count==2);
        check_header(1,8'h24,3);
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

        @(negedge clk); local_cmd_async=8'h4e; local_cmd_toggle_async=~local_cmd_toggle_async;
        wait(packet_count==9);
        check_header(8,8'h01,2);
        if(packets[8][8]!=8'h4e || packets[8][9]!=8'hb1) $fatal(1,"local next command");
        $display("PASS: READY/results ordering, repeated commit result, control/status, local touch command");
        $finish;
    end
    initial begin #200000; $fatal(1,"timeout"); end
endmodule
