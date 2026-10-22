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
    wire route_grant,route_media;
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
        .media_in_flight(media_in_flight),.media_packet_drained(media_packet_drained),
        .route_grant(route_grant),.route_media(route_media)
    );
    media_udp_route u_route (
        .clk(clk),.rst(rst),.packet_grant(route_grant),.media_selected(route_media),.media_to_pc(media_to_pc),
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

    task automatic control_packet(input [15:0] kind,input bit to_display);
        begin
            @(negedge clk);stack_ready=1;control_type=kind;ctrl_length=0;ctrl_request=1;
            @(negedge clk);
            if(to_display)expect_display();else expect_pc();
            stack_ack=1;
            @(negedge clk);ctrl_request=0;stack_ack=0;ctrl_length=2;ctrl_valid=1;
            repeat(2)@(negedge clk);
            ctrl_valid=0;stack_ready=0;ctrl_length=99;
            control_type=to_display ? 16'h0002 : 16'h0040;
            repeat(3)begin
                @(negedge clk);
                if(stack_length!=2)$fatal(1,"control length changed during UDP drain");
                if(to_display)expect_display();else expect_pc();
            end
        end
    endtask
    task automatic media_packet(input bit to_pc);
        begin
            @(negedge clk);stack_ready=1;media_to_pc=to_pc;media_length=2;media_request=1;
            @(negedge clk);
            if(!media_in_flight)$fatal(1,"no media ownership after grant");
            if(to_pc)expect_pc();else expect_display();
            stack_ack=1;
            @(negedge clk);media_request=0;stack_ack=0;media_valid=1;
            // Queue an opposite-destination control operation during DATA.
            ctrl_request=1;control_type=to_pc ? 16'h0040 : 16'h0002;media_to_pc=~to_pc;
            if(to_pc)expect_pc();else expect_display();
            repeat(2)@(negedge clk);
            media_valid=0;stack_ready=0;media_length=99;
            if(media_in_flight)$fatal(1,"active metric remained high after payload");
            repeat(3)begin
                @(negedge clk);
                if(stack_length!=2)$fatal(1,"media length changed during UDP drain");
                if(to_pc)expect_pc();else expect_display();
            end
            ctrl_request=0;
        end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst=0;expect_pc();
        control_packet('h0002,0);control_packet('h0003,0);
        control_packet('h0040,1);control_packet('h0042,1);
        control_packet('h0044,1);control_packet('h0045,1);control_packet('h0046,1);
        control_packet('h0041,0);control_packet('h0043,0);
        media_packet(0);control_packet('h0002,0);
        media_packet(1);control_packet('h0040,1);
        $display("PASS: grant-selected PC/display routes, concurrent snapshot/SET isolation, and route/length lifetime through UDP drain");
        $finish;
    end
    initial begin #100000;$fatal(1,"media route timeout");end
endmodule
