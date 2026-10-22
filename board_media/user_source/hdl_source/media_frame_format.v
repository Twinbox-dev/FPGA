`timescale 1ns/1ps
// Lossless RGB565 pixel packer for the variable-size image wire format.
// BMP pixels arrive in file order (bottom-up rows). Two consecutive pixels
// are packed low-pixel first; an odd final pixel uses a zero high halfword.
// Centering and black-border generation happen on the display board.
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
    reg [11:0] x;
    reg [10:0] y;
    reg half_valid, word_last;
    reg [15:0] low_pixel;

    wire final_pixel = (x + 12'd1 == image_width) && (y + 11'd1 == image_height);
    wire push = active && pixel_valid && level < 10'd512;
    wire fetch = active && !cache_valid && !read_pending && level != 0;
    wire collect = active && !word_valid && cache_valid;
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
            half_valid <= 0; low_pixel <= 0;
            word_data <= 0; word_valid <= 0; word_last <= 0;
            active <= 0; done <= 0; error <= 0; checksum <= 0;
        end else if (start) begin
            wr_ptr <= 0; rd_ptr <= 0; level <= 0;
            cache_valid <= 0; read_pending <= 0;
            x <= 0; y <= 0;
            half_valid <= 0; word_valid <= 0; word_last <= 0;
            checksum <= 0; done <= 0;
            error <= image_width == 0 || image_width > 1280 ||
                     image_height == 0 || image_height > 720;
            active <= image_width != 0 && image_width <= 1280 &&
                      image_height != 0 && image_height <= 720;
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
                if (word_last) begin
                    active <= 0;
                    done <= 1;
                end
            end
            if (collect) begin
                cache_valid <= 0;
                if (final_pixel && !half_valid) begin
                    // Odd pixel count: preserve the final low RGB565 pixel
                    // and define the unused high halfword as zero.
                    word_data <= {16'd0,cache};
                    word_valid <= 1;
                    word_last <= 1;
                    half_valid <= 0;
                end else if (!half_valid) begin
                    low_pixel <= cache;
                    half_valid <= 1;
                end else begin
                    word_data <= {cache,low_pixel};
                    word_valid <= 1;
                    word_last <= final_pixel;
                    half_valid <= 0;
                end
                if (x + 12'd1 == image_width) begin
                    x <= 0;
                    y <= y + 1'b1;
                end else begin
                    x <= x + 1'b1;
                end
            end
        end
    end
endmodule
