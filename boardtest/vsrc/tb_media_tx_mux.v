`timescale 1ns/1ps
module tb_media_tx_mux;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1, stack_ready=1, stack_ack=0;
    reg ctrl_req=0, ctrl_valid=0, chunk_req=0, chunk_valid=0;
    reg [7:0] ctrl_data=8'hc1, chunk_data=8'hd2;
    wire ctrl_ready, ctrl_ack, chunk_ack, stack_req, stack_valid;
    wire [7:0] stack_data;
    wire [15:0] stack_length;

    media_tx_mux dut (
        .clk(clk), .rst(rst), .stack_ready(stack_ready),
        .stack_ack(stack_ack),
        .ctrl_req(ctrl_req), .ctrl_valid(ctrl_valid),
        .ctrl_data(ctrl_data), .ctrl_length(16'd16),
        .ctrl_ready(ctrl_ready), .ctrl_ack(ctrl_ack),
        .chunk_req(chunk_req), .chunk_valid(chunk_valid),
        .chunk_data(chunk_data), .chunk_length(16'd44),
        .chunk_ack(chunk_ack),
        .stack_req(stack_req), .stack_valid(stack_valid),
        .stack_data(stack_data), .stack_length(stack_length)
    );

    initial begin
        repeat(3) @(negedge clk); rst=0;
        // Simultaneous requests: command forwarding owns the first packet.
        ctrl_req=1; chunk_req=1;
        @(negedge clk);
        if (!stack_req || stack_length!=16 || stack_data!=8'hc1)
            $fatal(1,"control did not win simultaneous requests");
        stack_ack=1;
        #1;
        if (!ctrl_ack || chunk_ack) $fatal(1,"ACK went to wrong owner");
        @(negedge clk); stack_ack=0; ctrl_req=0; ctrl_valid=1;
        repeat(3) begin
            @(negedge clk);
            if (!stack_valid || stack_data!=8'hc1 || stack_length!=16)
                $fatal(1,"control data lost ownership during TX");
        end
        ctrl_valid=0;
        repeat(2) @(negedge clk);

        // Waiting media chunk takes the port next; command ready is gated.
        if (!stack_req || stack_length!=44)
            $fatal(1,"waiting chunk was not granted");
        stack_ack=1;
        #1;
        if (!chunk_ack || ctrl_ack || ctrl_ready)
            $fatal(1,"chunk ACK/ready routing failed");
        @(negedge clk); stack_ack=0; chunk_req=0; chunk_valid=1;
        repeat(3) begin
            @(negedge clk);
            if (!stack_valid || stack_data!=8'hd2 || stack_length!=44)
                $fatal(1,"chunk data lost ownership during TX");
        end
        chunk_valid=0;
        repeat(2) @(negedge clk);
        if (stack_req || stack_valid || !ctrl_ready)
            $fatal(1,"mux failed to return to idle");
        $display("PASS: media UDP TX arbitration and packet ownership");
        $finish;
    end
endmodule
