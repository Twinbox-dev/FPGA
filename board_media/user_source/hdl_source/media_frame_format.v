`timescale 1ns/1ps
// Source-order (bottom-up) RGB565 frame, including every black border pixel.
// Pixel input is unthrottled within a sector; pause reserves > one sector.
// Word output is lossless ready/valid. No SDRAM or whole-frame storage.
module media_frame_format (
    input wire clk, rst, start, abort,
    input wire [11:0] image_width, image_height,
    input wire pixel_valid,
    input wire [15:0] pixel_data,
    output wire pixel_pause,
    output reg [31:0] word_data,
    output reg word_valid,
    input wire word_ready,
    output reg active, done, error,
    output reg [31:0] checksum
);
    reg [15:0] pixels [0:511]; /* fehdl force_ram=1, ram_style="bram" */
    reg [8:0] wr_ptr, rd_ptr;
    reg [9:0] level;
    reg [15:0] ram_q, cache;
    reg cache_valid, read_pending;
    reg [10:0] x;
    reg [9:0] y;
    reg [11:0] left_edge, right_edge, bottom_edge, top_edge;
    reg half_valid, word_last;
    reg [15:0] low_pixel;
    wire inside_image = (x >= left_edge && x < right_edge &&
                         y >= bottom_edge && y < top_edge);
    wire push = active && pixel_valid && level < 10'd512;
    wire fetch = active && !cache_valid && !read_pending && level != 0;
    wire collect = active && !word_valid && (!inside_image || cache_valid);
    wire [15:0] next_pixel = inside_image ? cache : 16'd0;
    assign pixel_pause = level >= 10'd256;

    always @(posedge clk) begin
        if (push) pixels[wr_ptr] <= pixel_data;
        if (fetch) ram_q <= pixels[rd_ptr];
    end
    always @(posedge clk) begin
        if (rst || abort) begin
            wr_ptr <= 0; rd_ptr <= 0; level <= 0;
            cache <= 0; cache_valid <= 0; read_pending <= 0;
            x <= 0; y <= 0;
            left_edge <= 0; right_edge <= 0; bottom_edge <= 0; top_edge <= 0;
            half_valid <= 0; low_pixel <= 0;
            word_data <= 0; word_valid <= 0; word_last <= 0;
            active <= 0; done <= 0; error <= 0; checksum <= 0;
        end else if (start) begin
            wr_ptr <= 0; rd_ptr <= 0; level <= 0;
            cache_valid <= 0; read_pending <= 0;
            x <= 0; y <= 0;
            left_edge <= (12'd1280 - image_width) >> 1;
            right_edge <= ((12'd1280 - image_width) >> 1) + image_width;
            bottom_edge <= (12'd720 - image_height) - ((12'd720 - image_height) >> 1);
            top_edge <= (12'd720 - image_height) - ((12'd720 - image_height) >> 1) + image_height;
            half_valid <= 0; word_valid <= 0; word_last <= 0;
            checksum <= 0; done <= 0;
            error <= image_width == 0 || image_width > 1280 || image_height == 0 || image_height > 720;
            active <= image_width != 0 && image_width <= 1280 && image_height != 0 && image_height <= 720;
        end else begin
            done <= 0;
            read_pending <= fetch;
            if (push) wr_ptr <= wr_ptr + 1'b1;
            if (fetch) rd_ptr <= rd_ptr + 1'b1;
            case ({push,fetch})
                2'b10: level <= level + 1'b1;
                2'b01: level <= level - 1'b1;
                default: ;
            endcase
            if (active && pixel_valid && !push) error <= 1;
            if (read_pending) begin
                cache <= ram_q;
                cache_valid <= 1;
            end
            if (word_valid && word_ready) begin
                word_valid <= 0;
                checksum <= checksum + word_data;
                if (word_last) begin active <= 0; done <= 1; end
            end
            if (collect) begin
                if (inside_image) cache_valid <= 0;
                if (!half_valid) begin
                    low_pixel <= next_pixel;
                    half_valid <= 1;
                end else begin
                    word_data <= {next_pixel,low_pixel};
                    word_valid <= 1;
                    word_last <= x == 1279 && y == 719;
                    half_valid <= 0;
                end
                if (x == 1279) begin x <= 0; y <= y + 1'b1; end
                else x <= x + 1'b1;
            end
        end
    end
endmodule
