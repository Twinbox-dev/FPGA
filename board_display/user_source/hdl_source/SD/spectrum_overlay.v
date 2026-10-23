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
    reg [1:0] height_state;
    reg [3:0] scale_index;
    reg [7:0] scale_level;
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
            height_state <= 0; scale_index <= 0; scale_level <= 0;
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
                scale_index <= 0;
                height_state <= 1;
            end else if (height_state == 1) begin
                scale_level <= levels_frame[{scale_index,3'b000} +: 8];
                height_state <= 2;
            end else if (height_state == 2) begin
                // Convert the captured mailbox in place during VS blanking.
                // One READ/WRITE pair per band keeps the scale adder out of
                // the per-pixel selection/comparison path, with no second RAM.
                levels_frame[{scale_index,3'b000} +: 8] <= scaled_height[15:8];
                if (scale_index == 15) height_state <= 0;
                else begin scale_index <= scale_index + 1'b1; height_state <= 1; end
            end
        end
    end

    wire in_bands = (x_cnt >= 11'd128) && (x_cnt < 11'd1152);
    wire [10:0] band_x = x_cnt - 11'd128;
    wire [3:0] band_index = band_x[9:6];
    wire [7:0] bounded_level = scale_level > 8'd120 ? 8'd120 : scale_level;
    // Q8 coefficient 341 approximates 4/3. For integer levels 0..120,
    // rounded heights match round(level*4/3), including the 160-pixel maximum.
    // Explicit shifts/adds keep this display-only mapping out of the DSPs.
    wire [15:0] scaled_height = {bounded_level,8'd0} +
        {2'd0,bounded_level,6'd0} + {4'd0,bounded_level,4'd0} +
        {6'd0,bounded_level,2'd0} + {8'd0,bounded_level} + 16'd128;
    wire [7:0] height = levels_frame[{band_index, 3'b000} +: 8];
    wire [9:0] band_top = 10'd710 - {2'b00, height};
    wire cell_body = band_x[5:0] < 6'd48;
    wire filled = in_bands && cell_body && (height != 8'd0) &&
                  (y_cnt >= band_top) && (y_cnt < 10'd710);
    wire baseline = in_bands && cell_body && (y_cnt >= 10'd708) && (y_cnt < 10'd710);
    wire cap = filled && (height > 8'd128) && (y_cnt < band_top + 10'd3);

    assign shade = 1'b0;
    assign bar_hit = enabled_s1 && de && height_state==0 && (filled || baseline);
    assign bar_rgb = cap ? 24'hF6BD71 :
                     filled ? ((band_index < 4'd8) ? 24'h5DD5CA : 24'h7FAFE6) :
                              24'h26394E;
endmodule
