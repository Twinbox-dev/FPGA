`timescale 1ns/1ps
module tb_media_udp_route;
    reg media_active=0;reg [15:0] control_type=16'h0002;
    wire [31:0] destination_ip;wire [15:0] destination_port;wire display_route;
    media_udp_route dut(.*);
    task automatic expect_pc;
        begin #1;if(display_route || destination_ip!==32'hc0a88901 || destination_port!==16'h0002)
            $fatal(1,"expected PC route type=%04x media=%b ip=%h port=%h",control_type,media_active,destination_ip,destination_port);end
    endtask
    task automatic expect_display;
        begin #1;if(!display_route || destination_ip!==32'hc0a88902 || destination_port!==16'h0001)
            $fatal(1,"expected display route type=%04x media=%b ip=%h port=%h",control_type,media_active,destination_ip,destination_port);end
    endtask
    initial begin
        expect_pc();
        control_type=16'h0003;expect_pc();
        control_type=16'h0040;expect_display();
        control_type=16'h0042;expect_display();
        control_type=16'h0044;expect_display();
        control_type=16'h0045;expect_display();
        control_type=16'h0046;expect_display();
        control_type=16'h0041;expect_pc();
        control_type=16'h0043;expect_pc();
        control_type=16'h0002;media_active=1;expect_display();
        $display("PASS: media/display-control traffic routes to .2; V1 ACK and D probe route to PC .1");
        $finish;
    end
endmodule
