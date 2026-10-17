`timescale 1ns / 1ps

// Crosses the ETH command mailbox into the 50 MHz board clock domain.
// For the inter-board command probe, emit [CMD, ~CMD] in the first two bytes
// of the existing eight-byte transmit slot.  Display eth_front accepts this
// pair after the application header and delivers it to its control core.
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
                if (cmd != 8'h4d) begin // 'M' starts the synthetic media chunk
                    tx_pkt <= {48'd0, ~cmd, cmd};
                    tx_tog <= ~tx_tog;
                end
            end
        end
    end
endmodule
