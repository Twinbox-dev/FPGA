`timescale 1ns/100ps

// Dedicated 100 MHz clock for the native SD host. The SD clock is generated
// by the host divider from this domain (400 kHz during initialization,
// 25 MHz default speed, and 50 MHz High Speed).
module sd_host_pll (
    input  wire refclk_50m,
    input  wire reset,
    output wire clk_100m,
    output wire locked
);
    wire clk0_unbuffered;
    wire [3:0] unused_clocks;
    wire [7:0] unused_do;
    wire unused_psdone;

    EG_LOGIC_BUFG u_clk_buf (
        .i (clk0_unbuffered),
        .o (clk_100m)
    );

    EG_PHY_PLL #(
        .DPHASE_SOURCE ("DISABLE"),
        .DYNCFG        ("DISABLE"),
        .FIN           ("50.000000"),
        .FEEDBK_MODE   ("NORMAL"),
        .FEEDBK_PATH   ("CLKC0_EXT"),
        .STDBY_ENABLE  ("DISABLE"),
        .PLLRST_ENA    ("ENABLE"),
        .SYNC_ENABLE   ("DISABLE"),
        .GMC_GAIN      (4),
        .ICP_CURRENT   (29),
        .KVCO          (4),
        .LPF_CAPACITOR (1),
        .LPF_RESISTOR  (2),
        .REFCLK_DIV    (1),
        .FBCLK_DIV     (2),
        .CLKC0_ENABLE  ("ENABLE"),
        .CLKC0_DIV     (10),
        .CLKC0_CPHASE  (9),
        .CLKC0_FPHASE  (0),
        .CLKC1_ENABLE  ("DISABLE"),
        .CLKC1_DIV     (10),
        .CLKC1_CPHASE  (9),
        .CLKC1_FPHASE  (0),
        .CLKC2_ENABLE  ("DISABLE"),
        .CLKC2_DIV     (10),
        .CLKC2_CPHASE  (4),
        .CLKC2_FPHASE  (0)
    ) u_pll (
        .refclk   (refclk_50m),
        .reset    (reset),
        .stdby    (1'b0),
        .extlock  (locked),
        .load_reg (1'b0),
        .psclk    (1'b0),
        .psdown   (1'b0),
        .psstep   (1'b0),
        .psclksel (3'b000),
        .psdone   (unused_psdone),
        .dclk     (1'b0),
        .dcs      (1'b0),
        .dwe      (1'b0),
        .di       (8'd0),
        .daddr    (6'd0),
        .do       (unused_do),
        .fbclk    (clk_100m),
        .clkc     ({unused_clocks, clk0_unbuffered})
    );
endmodule
