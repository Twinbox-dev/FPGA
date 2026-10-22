// OSD controls cross from the SD clock as Gray-coded levels. Latch values and
// visibility on VS so all three panel rows show one coherent setting per frame.
module osd_visibility (
    input  wire       video_clk,
    input  wire       rst,
    input  wire       vs,
    input  wire [1:0] mode_raw,  // 0=off, 1=3s after change, 2=always
    input  wire [3:0] bri_gray_raw,
    input  wire [3:0] ct_gray_raw,
    input  wire [3:0] vol_gray_raw,
    input  wire [11:0] image_width_raw,
    input  wire [11:0] image_height_raw,
    output reg        show_panel,
    output reg  [3:0] brightness_level,
    output reg  [3:0] contrast_level,
    output reg  [3:0] volume_level,
    output reg  [11:0] image_width,
    output reg  [11:0] image_height
);
    reg [1:0] mode_s0, mode_s1;
    reg [3:0] bri_s0, bri_s1, ct_s0, ct_s1, vol_s0, vol_s1;
    reg [3:0] bri_frame, ct_frame, vol_frame;
    reg [11:0] width_s0,width_s1,height_s0,height_s1,width_frame,height_frame;
    reg [7:0] show_frames;
    reg vs_d, initialized;
    wire vs_rise = vs && !vs_d;
    wire changed = (bri_s1 != bri_frame) ||
                   (ct_s1 != ct_frame) ||
                   (vol_s1 != vol_frame) ||
                   (width_s1 != width_frame) || (height_s1 != height_frame);

    function [3:0] gray_to_bin;
        input [3:0] g;
        begin
            gray_to_bin[3] = g[3];
            gray_to_bin[2] = gray_to_bin[3] ^ g[2];
            gray_to_bin[1] = gray_to_bin[2] ^ g[1];
            gray_to_bin[0] = gray_to_bin[1] ^ g[0];
        end
    endfunction

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            mode_s0 <= 2'd0; mode_s1 <= 2'd0;
            bri_s0 <= 4'd0; bri_s1 <= 4'd0;
            ct_s0 <= 4'd0; ct_s1 <= 4'd0;
            vol_s0 <= 4'd0; vol_s1 <= 4'd0;
            width_s0 <= 12'd0; width_s1 <= 12'd0;
            height_s0 <= 12'd0; height_s1 <= 12'd0;
            width_frame <= 12'd0; height_frame <= 12'd0;
            bri_frame <= 4'd0; ct_frame <= 4'd0; vol_frame <= 4'd0;
            brightness_level <= 4'd0;
            contrast_level <= 4'd0;
            volume_level <= 4'd0;
            image_width <= 12'd0; image_height <= 12'd0;
            show_frames <= 8'd0;
            show_panel <= 1'b0;
            vs_d <= 1'b0;
            initialized <= 1'b0;
        end else begin
            mode_s0 <= mode_raw; mode_s1 <= mode_s0;
            bri_s0 <= bri_gray_raw; bri_s1 <= bri_s0;
            ct_s0 <= ct_gray_raw; ct_s1 <= ct_s0;
            vol_s0 <= vol_gray_raw; vol_s1 <= vol_s0;
            width_s0 <= image_width_raw; width_s1 <= width_s0;
            height_s0 <= image_height_raw; height_s1 <= height_s0;
            vs_d <= vs;
            if (vs_rise) begin
                bri_frame <= bri_s1;
                ct_frame <= ct_s1;
                vol_frame <= vol_s1;
                width_frame <= width_s1; height_frame <= height_s1;
                brightness_level <= gray_to_bin(bri_s1);
                contrast_level <= gray_to_bin(ct_s1);
                volume_level <= gray_to_bin(vol_s1);
                image_width <= width_s1; image_height <= height_s1;
                initialized <= 1'b1;
                if (initialized && changed)
                    show_frames <= 8'd180;
                else if (show_frames != 8'd0)
                    show_frames <= show_frames - 8'd1;
                case (mode_s1)
                    2'd2: show_panel <= 1'b1;
                    2'd1: show_panel <= initialized &&
                                         (changed || show_frames > 8'd1);
                    default: show_panel <= 1'b0;
                endcase
            end
        end
    end
endmodule
