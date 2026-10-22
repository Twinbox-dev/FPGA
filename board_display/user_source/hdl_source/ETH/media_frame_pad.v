`timescale 1ns/1ps
// Converts a validated variable-size source-pixel stream into the fixed
// 1280x720 RGB565 frame consumed by the existing SDRAM writer. Source pixels
// stay in BMP bottom-up order. The unused canvas area is generated as black.
// Audio DATA bypasses this raster formatter unchanged.
module media_frame_pad #(
    parameter [10:0] FRAME_WIDTH = 11'd1280,
    parameter [9:0]  FRAME_HEIGHT = 10'd720,
    parameter [20:0] FRAME_WORDS = 21'd460800
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_begin,
    input  wire [11:0] image_width,
    input  wire [11:0] image_height,
    input  wire        frame_end,
    input  wire        in_is_audio,
    input  wire        in_start,
    input  wire [8:0]  in_count,
    input  wire [31:0] in_data,
    input  wire        in_valid,
    output wire        in_ready,
    input  wire        in_done,
    output wire        out_start,
    output wire        out_is_audio,
    output wire [8:0]  out_count,
    output wire [31:0] out_data,
    output wire        out_valid,
    input  wire        out_ready,
    output wire        out_done,
    output reg         frame_done
);
    localparam [11:0] FRAME_WIDTH_12 = {1'b0,FRAME_WIDTH};
    localparam [11:0] FRAME_HEIGHT_12 = {2'b00,FRAME_HEIGHT};
    reg frame_active, input_done;
    reg [11:0] width_latched, height_latched;
    reg [19:0] source_pixel_total;
    reg [10:0] x;
    reg [9:0] y;
    reg [11:0] left_edge, right_edge, bottom_edge, top_edge;
    reg [19:0] source_pixels_consumed;
    reg [31:0] source_word;
    reg source_word_valid, source_word_high;
    reg half_valid;
    reg [15:0] low_pixel;
    reg [31:0] image_out_data;
    reg image_out_valid;
    wire [23:0] begin_pixel_count = image_width * image_height;
    // stream_is_audio describes the last drained DATA packet, not the current
    // frame. It remains high after a WAV until the next image DATA arrives.
    // Locally generated borders belong to the image as soon as BEGIN arrives.
    wire image_path = frame_active || image_out_valid;

    wire in_image = {1'b0,x} >= left_edge && {1'b0,x} < right_edge &&
                    {2'b00,y} >= bottom_edge && {2'b00,y} < top_edge;
    wire source_pixel_needed = in_image && source_pixels_consumed < source_pixel_total;
    wire image_in_ready = frame_active && source_pixel_needed &&
                          !source_word_valid && !image_out_valid;
    wire image_in_fire = !in_is_audio && in_valid && image_in_ready;
    wire audio_in_fire = in_is_audio && in_valid && out_ready;
    wire pixel_step = frame_active && (!image_out_valid || out_ready) &&
                      (!in_image || source_word_valid ||
                       (input_done && source_pixel_needed));
    wire [15:0] pixel_value = in_image && source_pixel_needed && source_word_valid ?
                              (source_word_high ? source_word[31:16] : source_word[15:0]) : 16'd0;

    assign in_ready = in_is_audio ? (!image_path && out_ready) : image_in_ready;
    assign out_start = in_start;
    assign out_is_audio = image_path ? 1'b0 : in_is_audio;
    assign out_count = in_count;
    assign out_data = image_path ? image_out_data : in_data;
    assign out_valid = image_path ? image_out_valid : (in_is_audio && in_valid);
    assign out_done = in_done;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            frame_active <= 1'b0; input_done <= 1'b0;
            width_latched <= 12'd0; height_latched <= 12'd0;
            source_pixel_total <= 20'd0;
            x <= 11'd0; y <= 10'd0;
            left_edge <= 12'd0; right_edge <= 12'd0;
            bottom_edge <= 12'd0; top_edge <= 12'd0;
            source_pixels_consumed <= 20'd0;
            source_word <= 32'd0; source_word_valid <= 1'b0; source_word_high <= 1'b0;
            half_valid <= 1'b0; low_pixel <= 16'd0;
            image_out_data <= 32'd0; image_out_valid <= 1'b0;
            frame_done <= 1'b0;
        end else begin
            frame_done <= 1'b0;
            if (frame_begin) begin
                width_latched <= image_width;
                height_latched <= image_height;
                source_pixel_total <= begin_pixel_count[19:0];
                left_edge <= (FRAME_WIDTH_12 - image_width) >> 1;
                right_edge <= ((FRAME_WIDTH_12 - image_width) >> 1) + image_width;
                bottom_edge <= (FRAME_HEIGHT_12 - image_height) -
                               ((FRAME_HEIGHT_12 - image_height) >> 1);
                top_edge <= ((FRAME_HEIGHT_12 - image_height) -
                             ((FRAME_HEIGHT_12 - image_height) >> 1)) + image_height;
                x <= 0; y <= 0;
                source_pixels_consumed <= 0;
                source_word <= 0; source_word_valid <= 0; source_word_high <= 0;
                half_valid <= 0; image_out_valid <= 0;
                input_done <= 0;
                frame_active <= image_width != 0 && image_width <= FRAME_WIDTH_12 &&
                                image_height != 0 && image_height <= FRAME_HEIGHT_12;
            end else begin
                if (frame_end) input_done <= 1'b1;
                if (image_out_valid && out_ready)
                    image_out_valid <= 1'b0;
                if (image_in_fire) begin
                    source_word <= in_data;
                    source_word_valid <= 1'b1;
                    source_word_high <= 1'b0;
                end
                if (pixel_step) begin
                    if (source_pixel_needed && source_word_valid) begin
                        source_pixels_consumed <= source_pixels_consumed + 20'd1;
                        if (source_word_high) begin
                            source_word_valid <= 1'b0;
                            source_word_high <= 1'b0;
                        end else begin
                            source_word_high <= 1'b1;
                        end
                    end else if (source_pixel_needed && input_done) begin
                        // A rejected/incomplete transfer is still drained into
                        // a deterministic black-filled staging frame; RESULT
                        // remains failure, so this buffer is never committed.
                        source_pixels_consumed <= source_pixels_consumed + 20'd1;
                    end

                    if (!half_valid) begin
                        low_pixel <= pixel_value;
                        half_valid <= 1'b1;
                    end else begin
                        image_out_data <= {pixel_value,low_pixel};
                        image_out_valid <= 1'b1;
                        half_valid <= 1'b0;
                    end

                    if (x == FRAME_WIDTH - 1'b1) begin
                        x <= 0;
                        if (y == FRAME_HEIGHT - 1'b1) begin
                            y <= 0;
                            frame_active <= 1'b0;
                            frame_done <= 1'b1;
                        end else begin
                            y <= y + 1'b1;
                        end
                    end else begin
                        x <= x + 1'b1;
                    end
                end
            end
        end
    end

    wire _unused = &{1'b0,FRAME_WORDS,in_count,audio_in_fire,width_latched[11:0],height_latched[11:0]};
endmodule
