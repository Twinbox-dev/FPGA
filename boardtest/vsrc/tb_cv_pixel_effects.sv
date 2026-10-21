`timescale 1ns/1ps

module tb_cv_pixel_effects;
    localparam integer HA = 8;
    localparam integer HT = 12;
    localparam integer VA = 4;
    localparam integer SYNC_DELAY = HT + 4;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg [23:0] rgb_in = 24'd0;
    reg de_in = 1'b0;
    reg vs_in = 1'b0;
    reg [2:0] runtime_mode = 3'd0;
    reg [2:0] expected_frame_mode = 3'd0;
    integer cycle = 0;
    integer frame_no;
    integer line_no;
    integer hpos;
    integer errors = 0;
    integer snow_pixels = 0;
    integer gray_in;
    reg hist_de [0:511];
    reg hist_vs [0:511];
    reg [23:0] hist_rgb0 [0:511];
    reg [23:0] hist_rgb1 [0:511];
    reg [23:0] hist_rgb2 [0:511];
    reg [23:0] hist_rgb3 [0:511];
    reg [23:0] hist_rgb4 [0:511];
    reg [23:0] hist_rgb5 [0:511];
    reg [2:0] hist_mode [0:511];

    wire [23:0] rgb0, rgb1, rgb2, rgb3, rgb4, rgb5;
    wire de0, vs0, de1, vs1, de2, vs2, de3, vs3, de4, vs4, de5, vs5;
    wire [23:0] rgb_runtime;
    wire de_runtime, vs_runtime;

    always #5 clk = ~clk;

    cv_pixel_effects #(.MODE(0), .H_ACTIVE(HA), .H_TOTAL(HT), .V_ACTIVE(VA), .SYNC_DEPTH(32)) u_bypass
        (.clk(clk), .rst(rst), .rgb_in(rgb_in), .de_in(de_in), .vs_in(vs_in), .mode_in(3'd0), .rgb_out(rgb0), .de_out(de0), .vs_out(vs0));
    cv_pixel_effects #(.MODE(1), .H_ACTIVE(HA), .H_TOTAL(HT), .V_ACTIVE(VA), .SYNC_DEPTH(32)) u_gray
        (.clk(clk), .rst(rst), .rgb_in(rgb_in), .de_in(de_in), .vs_in(vs_in), .mode_in(3'd0), .rgb_out(rgb1), .de_out(de1), .vs_out(vs1));
    cv_pixel_effects #(.MODE(2), .H_ACTIVE(HA), .H_TOTAL(HT), .V_ACTIVE(VA), .SYNC_DEPTH(32)) u_binary
        (.clk(clk), .rst(rst), .rgb_in(rgb_in), .de_in(de_in), .vs_in(vs_in), .mode_in(3'd0), .rgb_out(rgb2), .de_out(de2), .vs_out(vs2));
    cv_pixel_effects #(.MODE(3), .H_ACTIVE(HA), .H_TOTAL(HT), .V_ACTIVE(VA), .SYNC_DEPTH(32)) u_sobel
        (.clk(clk), .rst(rst), .rgb_in(rgb_in), .de_in(de_in), .vs_in(vs_in), .mode_in(3'd0), .rgb_out(rgb3), .de_out(de3), .vs_out(vs3));
    cv_pixel_effects #(.MODE(4), .H_ACTIVE(HA), .H_TOTAL(HT), .V_ACTIVE(VA), .SYNC_DEPTH(32)) u_sharp
        (.clk(clk), .rst(rst), .rgb_in(rgb_in), .de_in(de_in), .vs_in(vs_in), .mode_in(3'd0), .rgb_out(rgb4), .de_out(de4), .vs_out(vs4));
    cv_pixel_effects #(.MODE(5), .H_ACTIVE(HA), .H_TOTAL(HT), .V_ACTIVE(VA), .SYNC_DEPTH(32)) u_snow
        (.clk(clk), .rst(rst), .rgb_in(rgb_in), .de_in(de_in), .vs_in(vs_in), .mode_in(3'd0), .rgb_out(rgb5), .de_out(de5), .vs_out(vs5));
    cv_pixel_effects_runtime #(.H_ACTIVE(HA), .H_TOTAL(HT), .V_ACTIVE(VA), .SYNC_DEPTH(32)) u_runtime
        (.clk(clk), .rst(rst), .rgb_in(rgb_in), .de_in(de_in), .vs_in(vs_in),
         .mode_raw(runtime_mode), .rgb_out(rgb_runtime), .de_out(de_runtime), .vs_out(vs_runtime));

    function integer src_level;
        input integer x;
        input integer y;
        begin
            if ((x < 0) || (x >= HA) || (y < 0) || (y >= VA))
                src_level = 0;
            else if ((x == 4) && (y == 2))
                src_level = 180;
            else if (x >= 6)
                src_level = 200;
            else
                src_level = 100;
        end
    endfunction

    function [23:0] src_rgb;
        input integer x;
        input integer y;
        reg [7:0] level;
        reg [4:0] r5, b5;
        reg [5:0] g6;
        begin
            level = src_level(x,y);
            r5 = level[7:3];
            g6 = level[7:2];
            b5 = level[7:3];
            src_rgb = {r5,r5[4:2],g6,g6[5:4],b5,b5[4:2]};
        end
    endfunction

    function [7:0] luma_ref;
        input [23:0] rgb;
        reg [11:0] total;
        begin
            total = ({4'b0,rgb[23:16]} << 2) + {4'b0,rgb[23:16]} +
                    ({4'b0,rgb[15:8]} << 3) + {4'b0,rgb[15:8]} +
                    ({4'b0,rgb[7:0]} << 1);
            luma_ref = total[11:4];
        end
    endfunction

    function integer src_gray;
        input integer x;
        input integer y;
        reg [23:0] rgb;
        begin
            rgb = src_rgb(x,y);
            src_gray = luma_ref(rgb);
        end
    endfunction

    function [7:0] sobel_ref;
        input integer cx;
        input integer cy;
        integer gx, gy, mag;
        begin
            gx = -src_gray(cx-1, cy-1) + src_gray(cx+1, cy-1)
                 -2*src_gray(cx-1, cy) + 2*src_gray(cx+1, cy)
                 -src_gray(cx-1, cy+1) + src_gray(cx+1, cy+1);
            gy = -src_gray(cx-1, cy-1) - 2*src_gray(cx, cy-1) - src_gray(cx+1, cy-1)
                 +src_gray(cx-1, cy+1) + 2*src_gray(cx, cy+1) + src_gray(cx+1, cy+1);
            mag = ((gx < 0) ? -gx : gx) + ((gy < 0) ? -gy : gy);
            mag = mag >> 3;
            sobel_ref = (mag > 255) ? 8'hff : mag[7:0];
        end
    endfunction

    function [7:0] clamp8_ref;
        input integer value;
        begin
            if (value < 0) clamp8_ref = 8'd0;
            else if (value > 255) clamp8_ref = 8'hff;
            else clamp8_ref = value[7:0];
        end
    endfunction

    function [23:0] quantize565_ref;
        input [23:0] rgb;
        reg [4:0] r,b;
        reg [5:0] g;
        begin
            r=rgb[23:19]; g=rgb[15:10]; b=rgb[7:3];
            quantize565_ref={r,r[4:2],g,g[5:4],b,b[4:2]};
        end
    endfunction

    function [23:0] sharpen_ref;
        input integer cx;
        input integer cy;
        integer y, delta;
        reg [23:0] center;
        begin
            center = src_rgb(cx,cy);
            y = 5*src_gray(cx, cy) - src_gray(cx, cy-1) - src_gray(cx, cy+1)
                - src_gray(cx-1, cy) - src_gray(cx+1, cy);
            if (y < 0) y = 0;
            else if (y > 255) y = 255;
            delta = y - src_gray(cx,cy);
            sharpen_ref = {clamp8_ref(center[23:16] + delta),
                           clamp8_ref(center[15:8] + delta),
                           clamp8_ref(center[7:0] + delta)};
        end
    endfunction

    task check_cycle;
        reg [23:0] expected_rgb;
        reg [7:0] expected_gray;
        reg expected_bit;
        integer cx, cy;
        begin
            if ((cycle > SYNC_DELAY) &&
                ((de_runtime !== hist_de[cycle-SYNC_DELAY-1]) ||
                 (vs_runtime !== hist_vs[cycle-SYNC_DELAY-1]))) begin
                $display("FAIL runtime timing phase cycle=%0d mode=%0d de/vs=%b/%b conv=%b/%b",
                         cycle, expected_frame_mode, de_runtime, vs_runtime, de3, vs3);
                errors = errors + 1;
            end
            if (cycle > SYNC_DELAY) begin
                case (hist_mode[cycle-SYNC_DELAY-1])
                    3'd0: expected_rgb = hist_rgb0[cycle-SYNC_DELAY-1];
                    3'd1: expected_rgb = quantize565_ref(hist_rgb1[cycle-SYNC_DELAY-1]);
                    3'd2: expected_rgb = quantize565_ref(hist_rgb2[cycle-SYNC_DELAY-1]);
                    3'd3: expected_rgb = hist_rgb3[cycle-1];
                    3'd4: expected_rgb = hist_rgb4[cycle-1];
                    3'd5: expected_rgb = quantize565_ref(hist_rgb5[cycle-SYNC_DELAY-1]);
                    default: expected_rgb = 24'd0;
                endcase
                if (rgb_runtime !== expected_rgb) begin
                    $display("FAIL runtime pixel delay cycle=%0d mode=%0d got=%h expected=%h",
                             cycle, expected_frame_mode, rgb_runtime, expected_rgb);
                    errors = errors + 1;
                end
            end

            if ((rgb0 !== rgb_in) || (de0 !== de_in) || (vs0 !== vs_in)) begin
                $display("FAIL bypass cycle=%0d", cycle);
                errors = errors + 1;
            end

            expected_gray = luma_ref(rgb_in);
            expected_rgb = de_in ? {expected_gray,expected_gray,expected_gray} : 24'd0;
            if ((rgb1 !== expected_rgb) || (de1 !== de_in) || (vs1 !== vs_in)) begin
                $display("FAIL grayscale cycle=%0d got=%h expected=%h", cycle, rgb1, expected_rgb);
                errors = errors + 1;
            end

            expected_bit = luma_ref(rgb_in) >= 128;
            expected_rgb = !de_in ? 24'd0 : expected_bit ? 24'hffffff : 24'd0;
            if ((rgb2 !== expected_rgb) || (de2 !== de_in) || (vs2 !== vs_in)) begin
                $display("FAIL binary cycle=%0d got=%h expected=%h", cycle, rgb2, expected_rgb);
                errors = errors + 1;
            end

            if ((cycle >= SYNC_DELAY) &&
                ((de3 !== hist_de[cycle-SYNC_DELAY]) || (vs3 !== hist_vs[cycle-SYNC_DELAY]) ||
                 (de4 !== hist_de[cycle-SYNC_DELAY]) || (vs4 !== hist_vs[cycle-SYNC_DELAY]))) begin
                $display("FAIL conv sync cycle=%0d de=%b/%b vs=%b/%b", cycle,
                         de3, hist_de[cycle-SYNC_DELAY], vs3, hist_vs[cycle-SYNC_DELAY]);
                errors = errors + 1;
            end

            // The two arithmetic stages and three horizontal taps put the
            // output center at the input sync delayed by H_TOTAL+4 clocks.
            // That is previous-line x-4; the last output row is black.
            if (de3 && (line_no >= 2) && (line_no <= 5) &&
                (hpos >= 4) && (hpos <= HA+3)) begin
                cx = hpos - 4;
                cy = line_no - 2;
                if (cy == VA-1)
                    expected_rgb = 24'd0;
                else begin
                    expected_rgb = {sobel_ref(cx,cy),sobel_ref(cx,cy),sobel_ref(cx,cy)};
                end
                if (rgb3 !== expected_rgb) begin
                    $display("FAIL sobel line=%0d h=%0d center=(%0d,%0d) got=%h expected=%h",
                             line_no, hpos, cx, cy, rgb3, expected_rgb);
                    errors = errors + 1;
                end
                if (cy == VA-1)
                    expected_rgb = 24'd0;
                else begin
                    expected_rgb = sharpen_ref(cx,cy);
                end
                if (rgb4 !== expected_rgb) begin
                    $display("FAIL sharpen line=%0d h=%0d center=(%0d,%0d) got=%h expected=%h",
                             line_no, hpos, cx, cy, rgb4, expected_rgb);
                    errors = errors + 1;
                end
            end

            if ((de5 !== de_in) || (vs5 !== vs_in)) begin
                $display("FAIL snow sync cycle=%0d", cycle);
                errors = errors + 1;
            end else if (!de_in && (rgb5 !== 24'd0)) begin
                $display("FAIL snow blank cycle=%0d got=%h", cycle, rgb5);
                errors = errors + 1;
            end else if (de_in && (rgb5 == 24'hffffff)) begin
                snow_pixels = snow_pixels + 1;
            end else if (de_in && (rgb5 !== rgb_in)) begin
                $display("FAIL snow pixel cycle=%0d got=%h input=%h", cycle, rgb5, rgb_in);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        for (cycle = 0; cycle < 512; cycle = cycle + 1) begin
            hist_de[cycle] = 1'b0;
            hist_vs[cycle] = 1'b0;
            hist_rgb0[cycle] = 24'd0;
            hist_rgb1[cycle] = 24'd0;
            hist_rgb2[cycle] = 24'd0;
            hist_rgb3[cycle] = 24'd0;
            hist_rgb4[cycle] = 24'd0;
            hist_rgb5[cycle] = 24'd0;
            hist_mode[cycle] = 3'd0;
        end
        cycle = 0;
        repeat (3) @(negedge clk);
        rst = 1'b0;

        // Repeat the full mode cycle so sharpen/snow are tested in both
        // directions across several frame boundaries, including 4<->5.
        for (frame_no = 0; frame_no < 18; frame_no = frame_no + 1) begin
          runtime_mode = frame_no % 6;
          expected_frame_mode = frame_no % 6;
          for (line_no = 0; line_no < 6; line_no = line_no + 1) begin
            for (hpos = 0; hpos < HT; hpos = hpos + 1) begin
                @(negedge clk);
                if ((line_no == 2) && (hpos == HT/2))
                    runtime_mode = (frame_no + 1) % 6;
                vs_in = (line_no == 0);
                de_in = (line_no >= 1) && (line_no <= VA) && (hpos < HA);
                if (de_in) begin
                    rgb_in = src_rgb(hpos,line_no-1);
                end else
                    rgb_in = 24'd0;
                hist_de[cycle] = de_in;
                hist_vs[cycle] = vs_in;
                hist_mode[cycle] = expected_frame_mode;
                @(posedge clk);
                #1 check_cycle();
                hist_rgb0[cycle] = rgb0;
                hist_rgb1[cycle] = rgb1;
                hist_rgb2[cycle] = rgb2;
                hist_rgb3[cycle] = rgb3;
                hist_rgb4[cycle] = rgb4;
                hist_rgb5[cycle] = rgb5;
                cycle = cycle + 1;
            end
          end
        end

        if (snow_pixels == 0) begin
            $display("FAIL snow pattern generated no flakes");
            errors = errors + 1;
        end
        if (errors != 0)
            $fatal(1, "CV pixel effects failed with %0d errors", errors);
        $display("PASS: fixed effects, runtime selection, frame latching and sync alignment");
        $finish;
    end
endmodule
