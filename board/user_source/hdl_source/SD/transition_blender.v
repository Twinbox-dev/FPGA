// Two RGB565 pixels per word. The FIFO and line RAM both return their word one
// video clock after word_pop. Hold the mixed word for both output pixels.
module transition_blender (
    input  wire        video_clk,
    input  wire        rst,
    input  wire        line_de,
    input  wire        word_pop,
    input  wire [31:0] old_word,
    input  wire [31:0] new_word,
    input  wire        effect_active,
    input  wire        row_ready,
    input  wire [1:0]  effect_mode,       // 1=crossfade, 2=soft wipe
    input  wire        direction_prev,    // 0=right to left, 1=left to right
    input  wire [8:0]  fade_alpha,
    input  wire [10:0] wipe_progress,     // 0..1280 pixels
    output reg  [31:0] mixed_word
);
    reg       pop_d;
    reg [9:0] word_x;
    reg [9:0] word_x_d;

    wire [10:0] x0 = {word_x_d, 1'b0};
    wire [10:0] x1 = x0 + 11'd1;

    function [8:0] wipe_alpha;
        input [10:0] x;
        input [10:0] progress;
        input        prev;
        reg   [10:0] boundary;
        reg   [10:0] distance;
        begin
            if (progress == 11'd0)
                wipe_alpha = 9'd0;
            else if (progress >= 11'd1280)
                wipe_alpha = 9'd256;
            else if (prev) begin
                // New image enters from the left; 32 pixels form the soft edge.
                if (x >= progress) wipe_alpha = 9'd0;
                else begin
                    distance = progress - x;
                    wipe_alpha = (distance >= 11'd32) ? 9'd256 :
                                 {distance[5:0], 3'b000};
                end
            end else begin
                // New image enters from the right.
                boundary = 11'd1280 - progress;
                if (x < boundary) wipe_alpha = 9'd0;
                else begin
                    distance = x - boundary;
                    wipe_alpha = (distance >= 11'd32) ? 9'd256 :
                                 {distance[5:0], 3'b000};
                end
            end
        end
    endfunction

    function [15:0] blend565;
        input [15:0] old_pixel;
        input [15:0] new_pixel;
        input [8:0]  alpha;
        reg [8:0] inv_alpha;
        reg [13:0] red, blue;
        reg [14:0] green;
        begin
            inv_alpha = 9'd256 - alpha;
            red   = old_pixel[15:11] * inv_alpha + new_pixel[15:11] * alpha;
            green = old_pixel[10:5]  * inv_alpha + new_pixel[10:5]  * alpha;
            blue  = old_pixel[4:0]   * inv_alpha + new_pixel[4:0]   * alpha;
            blend565 = {red[12:8], green[13:8], blue[12:8]};
        end
    endfunction

    wire [8:0] alpha0 = effect_mode == 2'd1 ? fade_alpha :
                        effect_mode == 2'd2 ? wipe_alpha(x0, wipe_progress,
                                                          direction_prev) : 9'd0;
    wire [8:0] alpha1 = effect_mode == 2'd1 ? fade_alpha :
                        effect_mode == 2'd2 ? wipe_alpha(x1, wipe_progress,
                                                          direction_prev) : 9'd0;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            pop_d      <= 1'b0;
            word_x     <= 10'd0;
            word_x_d   <= 10'd0;
            mixed_word <= 32'd0;
        end else begin
            pop_d <= word_pop;
            if (!line_de)
                word_x <= 10'd0;
            else if (word_pop) begin
                word_x_d <= word_x;
                word_x   <= word_x + 10'd1;
            end

            if (pop_d)
                mixed_word <= (effect_active && row_ready && effect_mode != 2'd0) ?
                    {blend565(old_word[31:16], new_word[31:16], alpha1),
                     blend565(old_word[15:0],  new_word[15:0],  alpha0)} : old_word;
        end
    end
endmodule
