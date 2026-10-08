`timescale 1ns/1ps
// Draw 16 genuine DFT-energy bands in the reserved bottom portion of 720p.
// The horizontal bar cells are frequency bands, not arbitrary amplitude history.
module spectrum_overlay (
    input  wire         video_clk,
    input  wire         rst,
    input  wire         de,
    input  wire         vs,
    input  wire         enable_raw,
    input  wire [127:0] levels_raw,
    input  wire         done_toggle_raw,
    output reg          ack_toggle,
    output wire         shade,
    output wire         bar_hit,
    output wire [23:0]  bar_rgb
);
    reg enabled_s0, enabled_s1;
    reg done_s0, done_s1, done_s2;
    reg pending;
    reg [127:0] levels_frame;
    reg vs_d, de_d;
    reg [10:0] x_cnt;
    reg [9:0] y_cnt;
    wire vs_rise = vs && !vs_d;
    wire de_fall = de_d && !de;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            enabled_s0 <= 1'b0; enabled_s1 <= 1'b0;
            done_s0 <= 1'b0; done_s1 <= 1'b0; done_s2 <= 1'b0;
            pending <= 1'b0; levels_frame <= 128'd0; ack_toggle <= 1'b0;
            vs_d <= 1'b0; de_d <= 1'b0;
            x_cnt <= 11'd0; y_cnt <= 10'd0;
        end else begin
            enabled_s0 <= enable_raw; enabled_s1 <= enabled_s0;
            done_s0 <= done_toggle_raw;
            done_s1 <= done_s0;
            done_s2 <= done_s1;
            vs_d <= vs;
            de_d <= de;
            if (vs_rise) y_cnt <= 10'd0;
            else if (de_fall) y_cnt <= (y_cnt >= 10'd719) ? 10'd719 : y_cnt + 10'd1;
            if (de) x_cnt <= x_cnt + 11'd1;
            else x_cnt <= 11'd0;

            if (done_s1 ^ done_s2) pending <= 1'b1;
            if (vs_rise && pending) begin
                levels_frame <= levels_raw;
                ack_toggle <= ~ack_toggle;
                pending <= 1'b0;
            end
        end
    end

    wire in_panel = (x_cnt >= 11'd96) && (x_cnt < 11'd1184) &&
                    (y_cnt >= 10'd582) && (y_cnt < 10'd716);
    wire in_bands = (x_cnt >= 11'd128) && (x_cnt < 11'd1152);
    wire [10:0] band_x = x_cnt - 11'd128;
    wire [3:0] band_index = band_x[9:6];
    wire [7:0] height = levels_frame[{band_index, 3'b000} +: 8];
    wire [9:0] band_top = 10'd710 - {2'b00, height};
    wire cell_body = band_x[5:0] < 6'd48;
    wire filled = in_bands && cell_body && (height != 8'd0) &&
                  (y_cnt >= band_top) && (y_cnt < 10'd710);
    wire baseline = in_bands && cell_body && (y_cnt >= 10'd708) && (y_cnt < 10'd710);
    wire cap = filled && (height > 8'd96) && (y_cnt < band_top + 10'd3);

    assign shade = enabled_s1 && de && in_panel;
    assign bar_hit = shade && (filled || baseline);
    assign bar_rgb = cap ? 24'hF6BD71 :
                     filled ? ((band_index < 4'd8) ? 24'h5DD5CA : 24'h7FAFE6) :
                              24'h26394E;
endmodule
