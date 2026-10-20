module media_udp_route #(
    parameter [31:0] PC_IP = 32'hc0a88901,
    parameter [31:0] DISPLAY_IP = 32'hc0a88902,
    parameter [15:0] PC_PORT = 16'h0002,
    parameter [15:0] DISPLAY_PORT = 16'h0001
)(
    input wire media_active,
    input wire media_to_pc,
    input wire [15:0] control_type,
    output wire [31:0] destination_ip,
    output wire [15:0] destination_port,
    output wire display_route
);
    wire display_control =
        control_type==16'h0040 || control_type==16'h0042 ||
        control_type==16'h0044 || control_type==16'h0045 ||
        control_type==16'h0046;
    assign display_route=display_control || (media_active && !media_to_pc);
    assign destination_ip=display_route ? DISPLAY_IP : PC_IP;
    assign destination_port=display_route ? DISPLAY_PORT : PC_PORT;
endmodule
