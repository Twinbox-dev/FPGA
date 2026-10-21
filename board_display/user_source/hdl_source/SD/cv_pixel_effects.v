// HDMI-only image effects. Fixed modes are useful for unit tests and area
// comparisons; MODE=7 is the shared runtime point-effect datapath used by the
// product selector (0 bypass, 1 grayscale, 2 binary, 5 moving snow).
//
// The 3x3 modes use the current pixel plus two prior raster lines. Three
// rotating RGB565 line banks (1280x16 each) avoid same-address read/write on
// a BRAM. The output is delayed by H_TOTAL+4 clocks so DE/VS and the center
// pixel stay aligned through the horizontal taps and arithmetic pipeline.
// Top and bottom boundary rows are black; left/right neighbors are zero padded.
module cv_pixel_effects #(
    parameter integer MODE       = 0,
    parameter integer H_ACTIVE   = 1280,
    parameter integer H_TOTAL    = 1650,
    parameter integer V_ACTIVE   = 720,
    parameter integer SYNC_DEPTH = 2048
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [23:0] rgb_in,
    input  wire        de_in,
    input  wire        vs_in,
    input  wire [2:0]  mode_in,
    output wire [23:0] rgb_out,
    output wire        de_out,
    output wire        vs_out
);

function [7:0] luma;
    input [23:0] rgb;
    reg [11:0] weighted_sum;
    begin
        // Q4 approximation to Rec.601: 0.3125R + 0.5625G + 0.125B.
        // Coefficients sum to one and use shifts/adds rather than DSPs.
        weighted_sum = ({4'b0, rgb[23:16]} << 2) + {4'b0, rgb[23:16]} +
                       ({4'b0, rgb[15:8]}  << 3) + {4'b0, rgb[15:8]}  +
                       ({4'b0, rgb[7:0]}   << 1);
        luma = weighted_sum[11:4];
    end
endfunction

function [15:0] pack_rgb565;
    input [23:0] rgb;
    begin
        pack_rgb565 = {rgb[23:19], rgb[15:10], rgb[7:3]};
    end
endfunction

function [23:0] expand_rgb565;
    input [15:0] rgb;
    reg [4:0] r5, b5;
    reg [5:0] g6;
    begin
        r5 = rgb[15:11];
        g6 = rgb[10:5];
        b5 = rgb[4:0];
        expand_rgb565 = {r5, r5[4:2], g6, g6[5:4], b5, b5[4:2]};
    end
endfunction

function snow_flake_hit;
    input [10:0] px;
    input [9:0] py;
    input [10:0] fx;
    input [9:0] fy;
    reg x_near, y_near;
    begin
        x_near = (px == fx) || ((px + 11'd1) == fx) || (px == (fx + 11'd1));
        y_near = (py == fy) || ((py + 10'd1) == fy) || (py == (fy + 10'd1));
        snow_flake_hit = ((x_near && (py == fy)) || ((px == fx) && y_near));
    end
endfunction

generate
    if (MODE == 0) begin : g_bypass
        assign rgb_out = rgb_in;
        assign de_out  = de_in;
        assign vs_out  = vs_in;
    end else if (MODE == 1 || MODE == 2) begin : g_point
        reg [23:0] rgb_q;
        reg de_q, vs_q;
        wire [7:0] gray = luma(rgb_in);
        always @(posedge clk or posedge rst) begin
            if (rst) begin
                rgb_q <= 24'd0;
                de_q  <= 1'b0;
                vs_q  <= 1'b0;
            end else begin
                de_q <= de_in;
                vs_q <= vs_in;
                if (!de_in)
                    rgb_q <= 24'd0;
                else if (MODE == 1)
                    rgb_q <= {gray, gray, gray};
                else
                    rgb_q <= (gray >= 8'd128) ? 24'hffffff : 24'h000000;
            end
        end
        assign rgb_out = rgb_q;
        assign de_out  = de_q;
        assign vs_out  = vs_q;
    end else if (MODE == 7) begin : g_point_runtime
        reg [10:0] x_count;
        reg [9:0]  y_count;
        reg de_prev, vs_prev;
        reg [9:0] flake_y [0:7];
        reg [23:0] rgb_q;
        reg de_q, vs_q;
        integer i;
        localparam [10:0] FX0 = (H_ACTIVE * 1) / 9;
        localparam [10:0] FX1 = (H_ACTIVE * 2) / 9;
        localparam [10:0] FX2 = (H_ACTIVE * 3) / 9;
        localparam [10:0] FX3 = (H_ACTIVE * 4) / 9;
        localparam [10:0] FX4 = (H_ACTIVE * 5) / 9;
        localparam [10:0] FX5 = (H_ACTIVE * 6) / 9;
        localparam [10:0] FX6 = (H_ACTIVE * 7) / 9;
        localparam [10:0] FX7 = (H_ACTIVE * 8) / 9;
        wire [10:0] pixel_x = de_prev ? x_count : 11'd0;
        wire snow_hit =
            snow_flake_hit(pixel_x, y_count, FX0, flake_y[0]) |
            snow_flake_hit(pixel_x, y_count, FX1, flake_y[1]) |
            snow_flake_hit(pixel_x, y_count, FX2, flake_y[2]) |
            snow_flake_hit(pixel_x, y_count, FX3, flake_y[3]) |
            snow_flake_hit(pixel_x, y_count, FX4, flake_y[4]) |
            snow_flake_hit(pixel_x, y_count, FX5, flake_y[5]) |
            snow_flake_hit(pixel_x, y_count, FX6, flake_y[6]) |
            snow_flake_hit(pixel_x, y_count, FX7, flake_y[7]);
        wire [7:0] gray = luma(rgb_in);

        always @(posedge clk or posedge rst) begin
            if (rst) begin
                x_count <= 11'd0;
                y_count <= 10'd0;
                de_prev <= 1'b0;
                vs_prev <= 1'b0;
                rgb_q <= 24'd0;
                de_q <= 1'b0;
                vs_q <= 1'b0;
                for (i = 0; i < 8; i = i + 1)
                    flake_y[i] <= (V_ACTIVE * (i + 1)) / 9;
            end else begin
                de_prev <= de_in;
                vs_prev <= vs_in;
                de_q <= de_in;
                vs_q <= vs_in;
                if (!de_in)
                    rgb_q <= 24'd0;
                else begin
                    case (mode_in)
                        3'd1: rgb_q <= {gray, gray, gray};
                        3'd2: rgb_q <= (gray >= 8'd128) ? 24'hffffff : 24'h000000;
                        3'd5: rgb_q <= snow_hit ? 24'hffffff : rgb_in;
                        default: rgb_q <= rgb_in;
                    endcase
                end

                if (vs_in && !vs_prev) begin
                    x_count <= 11'd0;
                    y_count <= 10'd0;
                    for (i = 0; i < 8; i = i + 1) begin
                        if (flake_y[i] >= V_ACTIVE - 2)
                            flake_y[i] <= 10'd0;
                        else
                            flake_y[i] <= flake_y[i] + ((i & 1) ? 2 : 1);
                    end
                end else if (de_in) begin
                    if (!de_prev)
                        x_count <= 11'd1;
                    else
                        x_count <= x_count + 11'd1;
                end else if (de_prev) begin
                    x_count <= 11'd0;
                    if (y_count < V_ACTIVE - 1)
                        y_count <= y_count + 10'd1;
                end
            end
        end
        assign rgb_out = rgb_q;
        assign de_out = de_q;
        assign vs_out = vs_q;
    end else if (MODE == 5) begin : g_snow
        reg [10:0] x_count;
        reg [9:0]  y_count;
        reg de_prev, vs_prev;
        reg [9:0] flake_y [0:7];
        reg [23:0] rgb_q;
        reg de_q, vs_q;
        integer i;
        localparam [10:0] FX0 = (H_ACTIVE * 1) / 9;
        localparam [10:0] FX1 = (H_ACTIVE * 2) / 9;
        localparam [10:0] FX2 = (H_ACTIVE * 3) / 9;
        localparam [10:0] FX3 = (H_ACTIVE * 4) / 9;
        localparam [10:0] FX4 = (H_ACTIVE * 5) / 9;
        localparam [10:0] FX5 = (H_ACTIVE * 6) / 9;
        localparam [10:0] FX6 = (H_ACTIVE * 7) / 9;
        localparam [10:0] FX7 = (H_ACTIVE * 8) / 9;
        wire [10:0] pixel_x = de_prev ? x_count : 11'd0;
        wire snow_hit =
            snow_flake_hit(pixel_x, y_count, FX0, flake_y[0]) |
            snow_flake_hit(pixel_x, y_count, FX1, flake_y[1]) |
            snow_flake_hit(pixel_x, y_count, FX2, flake_y[2]) |
            snow_flake_hit(pixel_x, y_count, FX3, flake_y[3]) |
            snow_flake_hit(pixel_x, y_count, FX4, flake_y[4]) |
            snow_flake_hit(pixel_x, y_count, FX5, flake_y[5]) |
            snow_flake_hit(pixel_x, y_count, FX6, flake_y[6]) |
            snow_flake_hit(pixel_x, y_count, FX7, flake_y[7]);

        always @(posedge clk or posedge rst) begin
            if (rst) begin
                x_count <= 11'd0;
                y_count <= 10'd0;
                de_prev <= 1'b0;
                vs_prev <= 1'b0;
                rgb_q   <= 24'd0;
                de_q    <= 1'b0;
                vs_q    <= 1'b0;
                for (i = 0; i < 8; i = i + 1)
                    flake_y[i] <= (V_ACTIVE * (i + 1)) / 9;
            end else begin
                de_prev <= de_in;
                vs_prev <= vs_in;
                de_q    <= de_in;
                vs_q    <= vs_in;
                rgb_q   <= !de_in ? 24'd0 : snow_hit ? 24'hffffff : rgb_in;

                if (vs_in && !vs_prev) begin
                    x_count <= 11'd0;
                    y_count <= 10'd0;
                    for (i = 0; i < 8; i = i + 1) begin
                        if (flake_y[i] >= V_ACTIVE - 2)
                            flake_y[i] <= 10'd0;
                        else
                            flake_y[i] <= flake_y[i] + ((i & 1) ? 2 : 1);
                    end
                end else if (de_in) begin
                    if (!de_prev)
                        x_count <= 11'd1;
                    else
                        x_count <= x_count + 11'd1;
                end else if (de_prev) begin
                    x_count <= 11'd0;
                    if (y_count < V_ACTIVE - 1)
                        y_count <= y_count + 10'd1;
                end
            end
        end
        assign rgb_out = rgb_q;
        assign de_out  = de_q;
        assign vs_out  = vs_q;
    end else if (MODE == 3 || MODE == 4 || MODE == 6) begin : g_neighborhood
        // Three horizontal taps place the kernel center at x-2; two arithmetic
        // registers add two clocks. Keep the sync delay equal to that latency.
        localparam integer SYNC_DELAY = H_TOTAL + 4;
        localparam integer PTR_WIDTH  = $clog2(SYNC_DEPTH);
        localparam integer RD_INIT    = SYNC_DEPTH - SYNC_DELAY;
        localparam integer COUNT_WIDTH = $clog2(SYNC_DELAY + 2);

        // A circular BRAM delays only DE/VS; data uses the two full-width
        // line stores below. Neither memory is reset so both infer block RAM.
        reg [1:0] sync_mem [0:SYNC_DEPTH-1]; /* fehdl force_ram=1, ram_style="bram_9k" */
        reg [PTR_WIDTH-1:0] sync_wr_ptr, sync_rd_ptr;
        reg [1:0] sync_q;
        reg [COUNT_WIDTH-1:0] sync_count;

        reg [15:0] line0 [0:H_ACTIVE-1]; /* fehdl force_ram=1, ram_style="bram_32k" */
        reg [15:0] line1 [0:H_ACTIVE-1]; /* fehdl force_ram=1, ram_style="bram_32k" */
        reg [15:0] line2 [0:H_ACTIVE-1]; /* fehdl force_ram=1, ram_style="bram_32k" */
        reg [15:0] q_line0, q_line1, q_line2;
        reg [15:0] mid_rgb_1, mid_rgb_2;
        reg [7:0] top_y_1, top_y_2, top_y_3;
        reg [7:0] mid_y_1, mid_y_2, mid_y_3;
        reg [7:0] bot_y_1, bot_y_2, bot_y_3;
        reg [7:0] current_y;
        reg [10:0] x_count;
        reg [1:0] row_bank;
        reg [1:0] rows_seen;
        reg de_prev, vs_prev, read_valid;
        reg signed [12:0] gx_q, gy_q;
        reg [7:0] sharpen_luma_q, sharpen_center_y_q;
        reg [15:0] sharpen_center_rgb_q;
        reg border_q;
        reg [23:0] cv_rgb_q;

        wire [15:0] q_mid_pixel = !read_valid || (rows_seen == 0) ? 16'd0 :
                                  (row_bank == 0) ? q_line2 :
                                  (row_bank == 1) ? q_line0 : q_line1;
        wire [15:0] q_top_pixel = !read_valid || (rows_seen < 2) ? 16'd0 :
                                  (row_bank == 0) ? q_line1 :
                                  (row_bank == 1) ? q_line2 : q_line0;
        wire [23:0] q_mid_rgb = expand_rgb565(q_mid_pixel);
        wire [23:0] q_top_rgb = expand_rgb565(q_top_pixel);
        wire [7:0] q_mid_y = luma(q_mid_rgb);
        wire [7:0] q_top_y = luma(q_top_rgb);
        wire [10:0] ram_addr = de_prev ? x_count : 11'd0;
        // All 3x3 taps are registered here, so the Sobel arithmetic no longer
        // follows the BRAM output in the same combinational path.
        wire [11:0] p00 = {4'b0, top_y_3};
        wire [11:0] p01 = {4'b0, top_y_2};
        wire [11:0] p02 = {4'b0, top_y_1};
        wire [11:0] p10 = {4'b0, mid_y_3};
        wire [11:0] p11 = {4'b0, mid_y_2};
        wire [11:0] p12 = {4'b0, mid_y_1};
        wire [11:0] p20 = {4'b0, bot_y_3};
        wire [11:0] p21 = {4'b0, bot_y_2};
        wire [11:0] p22 = {4'b0, bot_y_1};
        wire signed [12:0] gx_calc = -$signed(p00) + $signed(p02) -
                                     ($signed(p10) <<< 1) + ($signed(p12) <<< 1) -
                                     $signed(p20) + $signed(p22);
        wire signed [12:0] gy_calc = -$signed(p00) - ($signed(p01) <<< 1) -
                                     $signed(p02) + $signed(p20) +
                                     ($signed(p21) <<< 1) + $signed(p22);
        wire [12:0] gx_abs = gx_q[12] ? -gx_q : gx_q;
        wire [12:0] gy_abs = gy_q[12] ? -gy_q : gy_q;
        wire [13:0] sobel_sum = gx_abs + gy_abs;
        wire [7:0] sobel_gray = sobel_sum[10:3];

        wire signed [12:0] sharpen_y = ($signed(p11) <<< 2) + $signed(p11) -
                                       $signed(p01) - $signed(p21) -
                                       $signed(p10) - $signed(p12);
        wire [7:0] sharpen_luma = sharpen_y < 0 ? 8'd0 :
                                   sharpen_y > 255 ? 8'hff : sharpen_y[7:0];
        wire signed [9:0] luma_delta_q = $signed({1'b0, sharpen_luma_q}) -
                                         $signed({1'b0, sharpen_center_y_q});
        wire [23:0] sharpen_center_rgb = expand_rgb565(sharpen_center_rgb_q);
        wire signed [10:0] sharpen_r = $signed({1'b0, sharpen_center_rgb[23:16]}) + luma_delta_q;
        wire signed [10:0] sharpen_g = $signed({1'b0, sharpen_center_rgb[15:8]}) + luma_delta_q;
        wire signed [10:0] sharpen_b = $signed({1'b0, sharpen_center_rgb[7:0]}) + luma_delta_q;
        wire [23:0] sharpen_rgb = {
            sharpen_r < 0 ? 8'd0 : sharpen_r > 255 ? 8'hff : sharpen_r[7:0],
            sharpen_g < 0 ? 8'd0 : sharpen_g > 255 ? 8'hff : sharpen_g[7:0],
            sharpen_b < 0 ? 8'd0 : sharpen_b > 255 ? 8'hff : sharpen_b[7:0]
        };
        wire [23:0] sobel_rgb = {sobel_gray, sobel_gray, sobel_gray};
        wire border_row = (rows_seen == 0);

        always @(posedge clk or posedge rst) begin
            if (rst) begin
                sync_wr_ptr <= {PTR_WIDTH{1'b0}};
                sync_rd_ptr <= RD_INIT[PTR_WIDTH-1:0];
                sync_q      <= 2'b00;
                sync_count  <= {COUNT_WIDTH{1'b0}};
            end else begin
                sync_mem[sync_wr_ptr] <= {vs_in, de_in};
                sync_q <= sync_mem[sync_rd_ptr];
                if (sync_count <= SYNC_DELAY)
                    sync_count <= sync_count + 1'b1;
                sync_wr_ptr <= (sync_wr_ptr == SYNC_DEPTH - 1) ?
                               {PTR_WIDTH{1'b0}} : sync_wr_ptr + 1'b1;
                sync_rd_ptr <= (sync_rd_ptr == SYNC_DEPTH - 1) ?
                               {PTR_WIDTH{1'b0}} : sync_rd_ptr + 1'b1;
            end
        end

        always @(posedge clk or posedge rst) begin
            if (rst) begin
                x_count    <= 11'd0;
                row_bank <= 2'd0;
                rows_seen  <= 2'd0;
                de_prev    <= 1'b0;
                vs_prev    <= 1'b0;
                read_valid <= 1'b0;
            end else begin
                de_prev <= de_in;
                vs_prev <= vs_in;
                read_valid <= de_in;
                if (vs_in && !vs_prev) begin
                    x_count     <= 11'd0;
                    row_bank <= 2'd0;
                    rows_seen   <= 2'd0;
                end else if (de_in) begin
                    if (!de_prev)
                        x_count <= 11'd1;
                    else
                        x_count <= x_count + 11'd1;
                end else if (de_prev) begin
                    x_count <= 11'd0;
                    row_bank <= (row_bank == 2'd2) ? 2'd0 : row_bank + 1'b1;
                    if (rows_seen < 2)
                        rows_seen <= rows_seen + 1'b1;
                end
            end
        end

        // Each bank has one synchronous port per cycle: it either stores the
        // current row or reads one older row. Splitting these into one-port
        // templates lets TD infer three block RAMs without read/write aliasing.
        always @(posedge clk) begin
            if (de_in) begin
                if (row_bank == 0)
                    line0[ram_addr] <= pack_rgb565(rgb_in);
                else
                    q_line0 <= line0[ram_addr];
            end
        end
        always @(posedge clk) begin
            if (de_in) begin
                if (row_bank == 1)
                    line1[ram_addr] <= pack_rgb565(rgb_in);
                else
                    q_line1 <= line1[ram_addr];
            end
        end
        always @(posedge clk) begin
            if (de_in) begin
                if (row_bank == 2)
                    line2[ram_addr] <= pack_rgb565(rgb_in);
                else
                    q_line2 <= line2[ram_addr];
            end
        end
        always @(posedge clk or posedge rst) begin
            if (rst)
                current_y <= 8'd0;
            else
                current_y <= de_in ? luma(rgb_in) : 8'd0;
        end

        always @(posedge clk or posedge rst) begin
            if (rst) begin
                top_y_1 <= 0; top_y_2 <= 0; top_y_3 <= 0;
                mid_y_1 <= 0; mid_y_2 <= 0; mid_y_3 <= 0;
                bot_y_1 <= 0; bot_y_2 <= 0; bot_y_3 <= 0;
                mid_rgb_1 <= 0; mid_rgb_2 <= 0;
                gx_q <= 0; gy_q <= 0;
                sharpen_luma_q <= 0; sharpen_center_y_q <= 0;
                sharpen_center_rgb_q <= 0;
                border_q <= 1'b1;
                cv_rgb_q <= 24'd0;
            end else begin
                top_y_3 <= top_y_2; top_y_2 <= top_y_1; top_y_1 <= q_top_y;
                mid_y_3 <= mid_y_2; mid_y_2 <= mid_y_1; mid_y_1 <= q_mid_y;
                bot_y_3 <= bot_y_2; bot_y_2 <= bot_y_1; bot_y_1 <= current_y;
                mid_rgb_2 <= mid_rgb_1; mid_rgb_1 <= q_mid_pixel;

                // Stage 1: neighborhood arithmetic. Stage 2: magnitude or
                // luma-delta color reconstruction, followed by an output register.
                gx_q <= gx_calc;
                gy_q <= gy_calc;
                sharpen_luma_q <= sharpen_luma;
                sharpen_center_y_q <= mid_y_2;
                sharpen_center_rgb_q <= mid_rgb_2;
                border_q <= border_row;
                cv_rgb_q <= border_q ? 24'd0 :
                            ((MODE == 3) || ((MODE == 6) && (mode_in == 3))) ?
                            sobel_rgb : sharpen_rgb;
            end
        end

        assign de_out = (sync_count > SYNC_DELAY) && sync_q[0];
        assign vs_out = (sync_count > SYNC_DELAY) && sync_q[1];
        assign rgb_out = de_out ? cv_rgb_q : 24'd0;
    end else begin : g_unknown_mode
        assign rgb_out = rgb_in;
        assign de_out  = de_in;
        assign vs_out  = vs_in;
    end
endgenerate

endmodule

// Delay point effects by the exact convolution-path latency. A circular
// synchronous RAM keeps point effects pixel-aligned with convolution modes
// without changing the HDMI raster phase.
module cv_point_line_delay #(
    parameter integer H_TOTAL = 1650,
    parameter integer SYNC_DEPTH = 2048
)(
    input wire clk, rst,
    input wire [23:0] rgb_in,
    input wire de_sync, vs_sync,
    output wire [23:0] rgb_out,
    output wire de_out, vs_out
);
    // MODE=7 registers RGB once before this synchronous RAM. The RAM and
    // output register together therefore match the existing H_TOTAL+4
    // convolution phase plus its final output register.
    localparam integer PIXEL_DELAY = H_TOTAL + 4;
    localparam integer PTR_WIDTH = $clog2(SYNC_DEPTH);
    localparam integer RD_INIT = SYNC_DEPTH - PIXEL_DELAY;
    reg [15:0] point_mem [0:SYNC_DEPTH-1]; /* fehdl force_ram=1, ram_style="bram_32k" */
    reg [PTR_WIDTH-1:0] wr_ptr, rd_ptr;
    reg [15:0] pixel_q;
    reg de_sync_q, vs_sync_q;

    function [15:0] pack565(input [23:0] rgb);
        begin pack565 = {rgb[23:19], rgb[15:10], rgb[7:3]}; end
    endfunction
    function [23:0] expand565(input [15:0] rgb);
        reg [4:0] r,b; reg [5:0] g;
        begin r=rgb[15:11]; g=rgb[10:5]; b=rgb[4:0];
            expand565={r,r[4:2],g,g[5:4],b,b[4:2]}; end
    endfunction

    // One synchronous read and one write at distinct addresses. The pointer
    // offset is exactly PIXEL_DELAY, matching the convolution DE/VS ring.
    // The RAM is intentionally not reset; output is masked by delayed DE.
    always @(posedge clk)
        if (!rst)
            point_mem[wr_ptr] <= pack565(rgb_in);
    always @(posedge clk)
        pixel_q <= point_mem[rd_ptr];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wr_ptr <= {PTR_WIDTH{1'b0}};
            rd_ptr <= RD_INIT[PTR_WIDTH-1:0];
            de_sync_q <= 1'b0;
            vs_sync_q <= 1'b0;
        end else begin
            wr_ptr <= (wr_ptr == SYNC_DEPTH - 1) ? {PTR_WIDTH{1'b0}} : wr_ptr + 1'b1;
            rd_ptr <= (rd_ptr == SYNC_DEPTH - 1) ? {PTR_WIDTH{1'b0}} : rd_ptr + 1'b1;
            de_sync_q <= de_sync;
            vs_sync_q <= vs_sync;
        end
    end

    assign de_out = de_sync_q;
    assign vs_out = vs_sync_q;
    assign rgb_out = de_sync_q ? expand565(pixel_q) : 24'd0;
endmodule


// Runtime selector for the display product. Every mode uses the same
// H_TOTAL+4 sync phase: convolution modes use their three kernel line stores;
// point modes use one shared RGB565 delay line. Switching modes never changes
// HDMI DE/VS timing. The selected mode is latched at input VS rising.
module cv_pixel_effects_runtime #(
    parameter integer H_ACTIVE = 1280,
    parameter integer H_TOTAL = 1650,
    parameter integer V_ACTIVE = 720,
    parameter integer SYNC_DEPTH = 2048,
    parameter [2:0] MODE_DEFAULT = 3'd0
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [23:0] rgb_in,
    input  wire        de_in,
    input  wire        vs_in,
    input  wire [2:0]  mode_raw,
    output reg  [23:0] rgb_out,
    output reg         de_out,
    output reg         vs_out
);
    reg [2:0] mode_active;
    reg [2:0] mode_output;
    reg vs_input_d, vs_conv_d;

    wire [23:0] rgb_point, rgb_point_aligned, rgb_conv;
    wire de_point, vs_point, de_point_aligned, vs_point_aligned;
    wire de_conv, vs_conv;
    reg [23:0] rgb_conv_d;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mode_active <= MODE_DEFAULT;
            mode_output <= MODE_DEFAULT;
            vs_input_d <= 1'b0;
            vs_conv_d <= 1'b0;
            rgb_conv_d <= 24'd0;
        end else begin
            vs_input_d <= vs_in;
            vs_conv_d <= vs_conv;
            rgb_conv_d <= rgb_conv;
            if (vs_in && !vs_input_d)
                mode_active <= (mode_raw <= 5) ? mode_raw : MODE_DEFAULT;
            // rgb_conv and point RGB are both delayed by one final register.
            // Capture the selected mode on the matching delayed frame edge.
            if (vs_conv && !vs_conv_d)
                mode_output <= mode_active;
        end
    end

    cv_pixel_effects #(.MODE(7), .H_ACTIVE(H_ACTIVE), .H_TOTAL(H_TOTAL), .V_ACTIVE(V_ACTIVE), .SYNC_DEPTH(SYNC_DEPTH)) u_point_effects
        (.clk(clk), .rst(rst), .rgb_in(rgb_in), .de_in(de_in), .vs_in(vs_in), .mode_in(mode_active),
         .rgb_out(rgb_point), .de_out(de_point), .vs_out(vs_point));
    cv_point_line_delay #(.H_TOTAL(H_TOTAL), .SYNC_DEPTH(SYNC_DEPTH)) u_point_line_delay
        (.clk(clk), .rst(rst), .rgb_in(rgb_point),
         .de_sync(de_conv), .vs_sync(vs_conv),
         .rgb_out(rgb_point_aligned), .de_out(de_point_aligned), .vs_out(vs_point_aligned));
    cv_pixel_effects #(.MODE(6), .H_ACTIVE(H_ACTIVE), .H_TOTAL(H_TOTAL), .V_ACTIVE(V_ACTIVE), .SYNC_DEPTH(SYNC_DEPTH)) u_convolution
        (.clk(clk), .rst(rst), .rgb_in(rgb_in), .de_in(de_in), .vs_in(vs_in), .mode_in(mode_active),
         .rgb_out(rgb_conv), .de_out(de_conv), .vs_out(vs_conv));

    always @* begin
        if ((mode_output == 3'd3) || (mode_output == 3'd4))
            rgb_out = rgb_conv_d;
        else
            rgb_out = rgb_point_aligned;
        de_out = de_point_aligned;
        vs_out = vs_point_aligned;
    end
endmodule
