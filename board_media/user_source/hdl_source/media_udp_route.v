module media_udp_route #(
    parameter [31:0] PC_IP = 32'hc0a88901,
    parameter [31:0] DISPLAY_IP = 32'hc0a88902,
    parameter [15:0] PC_PORT = 16'h0002,
    parameter [15:0] DISPLAY_PORT = 16'h0001
)(
    input wire clk,rst,packet_grant,media_selected,
    input wire media_to_pc,
    input wire [15:0] control_type,
    output reg [31:0] destination_ip,
    output reg [15:0] destination_port,
    output reg display_route
);
    wire display_control =
        control_type==16'h0040 || control_type==16'h0042 ||
        control_type==16'h0044 || control_type==16'h0045 ||
        control_type==16'h0046;
    wire selected_display=media_selected ? !media_to_pc : display_control;
    // Capture before stack_request rises, and keep the packet destination
    // through downstream drain. A queued control SET must not redirect a D
    // DATA packet that already owns the application port.
    always @(posedge clk) begin
        if(rst)begin destination_ip<=PC_IP;destination_port<=PC_PORT;display_route<=0;end
        else if(packet_grant)begin
            display_route<=selected_display;
            destination_ip<=selected_display ? DISPLAY_IP : PC_IP;
            destination_port<=selected_display ? DISPLAY_PORT : PC_PORT;
        end
    end
endmodule
