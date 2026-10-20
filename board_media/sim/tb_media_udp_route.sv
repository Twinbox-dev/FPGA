`timescale 1ns/1ps
module tb_media_udp_route;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1,stack_ready=1,stack_ack=0;
    reg ctrl_request=0,ctrl_valid=0,media_request=0,media_valid=0;
    reg [7:0] ctrl_data=8'hc1,media_data=8'hd2;
    reg [15:0] control_type=16'h0002;
    reg [15:0] ctrl_length=16'd2,media_length=16'd2;
    reg media_to_pc=0;
    wire ctrl_ready,ctrl_ack,media_ack,stack_request,stack_valid;
    wire [7:0] stack_data;
    wire [15:0] stack_length;
    wire late_ack_seen,packet_active,media_in_flight,media_packet_drained;
    wire [31:0] destination_ip;
    wire [15:0] destination_port;
    wire display_route;

    media_udp_mux u_mux (
        .clk(clk),.rst(rst),.stack_ready(stack_ready),.stack_ack(stack_ack),
        .ctrl_request(ctrl_request),.ctrl_valid(ctrl_valid),.ctrl_data(ctrl_data),
        .ctrl_length(ctrl_length),.ctrl_ready(ctrl_ready),.ctrl_ack(ctrl_ack),
        .media_request(media_request),.media_valid(media_valid),.media_data(media_data),
        .media_length(media_length),.media_ack(media_ack),.stack_request(stack_request),
        .stack_valid(stack_valid),.stack_data(stack_data),.stack_length(stack_length),
        .late_ack_seen(late_ack_seen),.packet_active(packet_active),
        .media_in_flight(media_in_flight),.media_packet_drained(media_packet_drained)
    );
    media_udp_route u_route (
        .media_active(media_in_flight),.media_to_pc(media_to_pc),
        .control_type(control_type),.destination_ip(destination_ip),
        .destination_port(destination_port),.display_route(display_route)
    );

    task automatic expect_pc;
        begin
            #1;
            if(display_route || destination_ip!==32'hc0a88901 || destination_port!==16'h0002)
                $fatal(1,"expected PC route type=%04x media=%b ip=%h port=%h",
                       control_type,media_in_flight,destination_ip,destination_port);
        end
    endtask
    task automatic expect_display;
        begin
            #1;
            if(!display_route || destination_ip!==32'hc0a88902 || destination_port!==16'h0001)
                $fatal(1,"expected display route type=%04x media=%b ip=%h port=%h",
                       control_type,media_in_flight,destination_ip,destination_port);
        end
    endtask

    initial begin
        repeat(3) @(negedge clk);
        rst=0;
        expect_pc();
        control_type=16'h0003;expect_pc();
        control_type=16'h0040;expect_display();
        control_type=16'h0042;expect_display();
        control_type=16'h0044;expect_display();
        control_type=16'h0045;expect_display();
        control_type=16'h0046;expect_display();
        control_type=16'h0041;expect_pc();
        control_type=16'h0043;expect_pc();

        // A real media-mux grant must assert media_in_flight and route a
        // normal image/audio packet to the display board at .2:1.
        control_type=16'h0011;
        @(negedge clk);media_request=1;
        @(negedge clk);media_request=0;
        if(!media_in_flight)$fatal(1,"media mux failed to assert media_in_flight");
        expect_display();
        media_to_pc=1;expect_pc();
        media_to_pc=0;
        media_valid=1;
        @(posedge clk);#1;if(!media_in_flight)$fatal(1,"route ended before final byte");
        @(posedge clk);#1;if(media_in_flight)$fatal(1,"route stayed active after final byte");
        media_valid=0;
        expect_pc();

        control_type=16'h0022;expect_pc();
        control_type=16'h0040;expect_display();
        $display("PASS: media packets route to display, PC snapshots route to PC, control packet routes stay fixed");
        $finish;
    end
endmodule
