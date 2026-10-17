`timescale 1ns / 1ps

// Crosses the ETH command mailbox into the 50 MHz board clock domain.
// The response is deliberately distinct from the display-board ACK/status:
// bytes E1, command, 'E', 'M', 00, 00, 00, 00.
module media_probe_bridge (
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  cmd,
    input  wire        cmd_pending,
    output reg         cmd_ack_t,
    output reg         tx_tog,
    output reg  [63:0] tx_pkt
);
    reg pending_s0, pending_s1, consumed;

    always @(posedge clk) begin
        if (rst) begin
            pending_s0 <= 1'b0;
            pending_s1 <= 1'b0;
            consumed   <= 1'b0;
            cmd_ack_t  <= 1'b0;
            tx_tog     <= 1'b0;
            tx_pkt     <= 64'd0;
        end else begin
            pending_s0 <= cmd_pending;
            pending_s1 <= pending_s0;
            if (!pending_s1)
                consumed <= 1'b0;
            else if (!consumed) begin
                // eth_front holds cmd stable throughout cmd_pending, and
                // captures tx_pkt only after synchronizing tx_tog.
                consumed  <= 1'b1;
                cmd_ack_t <= ~cmd_ack_t;
                tx_pkt    <= {32'd0, 8'h4d, 8'h45, cmd, 8'he1};
                tx_tog    <= ~tx_tog;
            end
        end
    end
endmodule
