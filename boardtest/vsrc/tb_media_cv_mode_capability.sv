`timescale 1ns/1ps
module tb_media_cv_mode_capability;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,valid=0;reg [7:0] data=0;
    wire set_toggle;wire [7:0] set_op,set_value;
    wire status_req,ack_valid;wire [7:0] ack_seq,ack_op,ack_status,ack_value;
    media_display_control_rx #(.CV_ENABLED(1),.CV_NEIGHBORHOOD_ENABLED(0),.SPECTRUM_ENABLED(1)) dut(
        .clk(clk),.rst(rst),.rx_data(data),.rx_valid(valid),.set_toggle(set_toggle),.set_op(set_op),.set_value(set_value),
        .status_req_valid(status_req),.status_sequence(),.control_ack_valid(ack_valid),.control_ack_sequence(ack_seq),
        .control_ack_op(ack_op),.control_ack_status(ack_status),.control_ack_value(ack_value),
        .subtitle_write_toggle(),.subtitle_write_index(),.subtitle_write_char(),.subtitle_commit_toggle(),
        .subtitle_commit_length(),.subtitle_commit_sequence());
    task automatic send_set(input [7:0] seq,op,value,input [7:0] expected_status);
        begin
            @(negedge clk);valid=1;data=8'haa;
            @(negedge clk);data=8'hbb;@(negedge clk);data=8'hcc;@(negedge clk);data=8'hdd;
            @(negedge clk);data=0;@(negedge clk);data=8'h40;
            @(negedge clk);data=0;@(negedge clk);data=4;
            @(negedge clk);data=seq;@(negedge clk);data=op;
            @(negedge clk);data=value;@(negedge clk);data=0;
            @(negedge clk);valid=0;
            wait(ack_valid);
            if(ack_seq!=seq||ack_op!=op||ack_status!=expected_status)$fatal(1,"SET %02x status=%0d expected=%0d",op,ack_status,expected_status);
            if(expected_status==0 && (set_op!=9||set_value!=value))$fatal(1,"accepted CV mode not forwarded");
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);rst=0;
        send_set(1,9,1,0);send_set(2,9,2,0);send_set(3,9,5,0);
        send_set(4,9,3,1);send_set(5,9,4,1);send_set(6,9,0,0);
        $display("PASS CV gate: raw/gray/binary/snow available; Sobel/sharpen refused");$finish;
    end
    initial begin #100000;$fatal(1,"CV capability test timeout");end
endmodule
