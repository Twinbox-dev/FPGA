`timescale 1ns / 1ps

// First media-board milestone: an independent Ethernet endpoint.  The SD and
// inter-board data paths will be added only after this endpoint is validated.
module top (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       eth_rgmii_rxc,
    input  wire       eth_rgmii_rx_ctl,
    input  wire [3:0] eth_rgmii_rxd,
    output wire       eth_rgmii_txc,
    output wire       eth_rgmii_tx_ctl,
    output wire [3:0] eth_rgmii_txd,
    output wire       eth_phy_reset
);
    // The existing ETH subsystem deliberately resets only once after power-up.
    // Keep its command bridge on the same reset lifetime.  Reprogram or power
    // cycle the board for another clean network reset; the key is sampled only
    // before the first release.
    reg boot_rst = 1'b1;
    always @(posedge clk)
        if (rst_n)
            boot_rst <= 1'b0;

    wire [7:0] cmd;
    wire       cmd_pending;
    wire       cmd_ack_t;
    wire       tx_tog;
    wire [63:0] tx_pkt;

    media_probe_bridge u_probe (
        .clk         (clk),
        .rst         (boot_rst),
        .cmd         (cmd),
        .cmd_pending (cmd_pending),
        .cmd_ack_t   (cmd_ack_t),
        .tx_tog      (tx_tog),
        .tx_pkt      (tx_pkt)
    );

    // .3 is the media board; the original display board remains at .2.
    // 02:00:00:00:00:03 is a locally administered, unicast MAC.
    eth_subsys #(
        .LOCAL_IP  (32'hc0a88903),
        .LOCAL_MAC (48'h020000000003),
        .DST_IP    (32'hc0a88901)
    ) u_eth (
        .clk_50             (clk),
        .rst_all            (boot_rst),
        .phy1_rgmii_rx_clk  (eth_rgmii_rxc),
        .phy1_rgmii_rx_ctl  (eth_rgmii_rx_ctl),
        .phy1_rgmii_rx_data (eth_rgmii_rxd),
        .phy1_rgmii_tx_clk  (eth_rgmii_txc),
        .phy1_rgmii_tx_ctl  (eth_rgmii_tx_ctl),
        .phy1_rgmii_tx_data (eth_rgmii_txd),
        .phy_reset          (eth_phy_reset),
        .cmd                (cmd),
        .cmd_pending        (cmd_pending),
        .cmd_ack_t          (cmd_ack_t),
        .tx_tog             (tx_tog),
        .tx_pkt             (tx_pkt),
        .sys_rst            (boot_rst),
        .tap_clk            (clk),
        .tap_val            (1'b0),
        .tap_word           (32'd0),
        .tap_end            (1'b0),
        .tap2_clk           (clk),
        .tap2_val           (1'b0),
        .tap2_word          (32'd0),
        .tap2_end           (1'b0)
    );
endmodule
