// Minimal IS31FL3731 bus and panel smoke test.
// The matrix receives a solid full-on pattern; no HDMI, DFT, Ethernet,
// transition, or media-board logic is included in this project.
module top (
    input  wire clk,              // Board 50 MHz oscillator
    input  wire rst_n,            // Active-low board reset
    output wire matrix_i2c_scl,
    inout  wire matrix_i2c_sda
);
    wire [104:0] full_on_bitmap = {15'd0, {90{1'b1}}};

    is31fl3731_i2c_master u_matrix (
        .clk           (clk),
        .rst           (~rst_n),
        .visualizer_en (1'b1),
        .vol_gain      (4'd8),
        .matrix_bitmap (full_on_bitmap),
        .frame_ready   (1'b0),
        .i2c_scl       (matrix_i2c_scl),
        .i2c_sda       (matrix_i2c_sda)
    );
endmodule
