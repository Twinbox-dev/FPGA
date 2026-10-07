`timescale 1ns/1ps
module tb_transition_video;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;
    reg de_in = 1'b0;
    reg [31:0] old_word = 32'd0, new_word = 32'd0;
    integer popped = 0, displayed = 0;
    wire pop, de_word, vs_word, de_out;
    wire [31:0] mixed_word;
    wire [23:0] rgb;

    transition_blender blend (
        .video_clk(clk), .rst(rst), .line_de(de_word), .word_pop(pop),
        .old_word(old_word), .new_word(new_word),
        .effect_active(1'b1), .row_ready(1'b1), .effect_mode(2'd1),
        .direction_prev(1'b0), .fade_alpha(9'd256),
        .wipe_progress(11'd0), .mixed_word(mixed_word)
    );
    video_delay #(.MIX_PIPELINE(1)) vdelay (
        .video_clk(clk), .rst(rst), .read_en(pop), .read_data(mixed_word),
        .hs(1'b0), .vs(1'b0), .de(de_in),
        .hs_r(), .vs_r(), .de_r(de_out),
        .de_word(de_word), .vs_word(vs_word), .vout_data(rgb)
    );

    always @(posedge clk) begin
        if (!rst && pop) begin
            old_word <= 32'd0;
            new_word <= (popped == 0) ? {16'h07e0, 16'hf800} :
                                      {16'hffff, 16'h001f};
            popped <= popped + 1;
        end
    end
    always @(negedge clk) begin
        if (!rst && de_out) begin
            case (displayed)
                0: if (rgb !== 24'hff0000) $fatal(1, "pixel 0 %h", rgb);
                1: if (rgb !== 24'h00ff00) $fatal(1, "pixel 1 %h", rgb);
                2: if (rgb !== 24'h0000ff) $fatal(1, "pixel 2 %h", rgb);
                3: if (rgb !== 24'hffffff) $fatal(1, "pixel 3 %h", rgb);
                default: $fatal(1, "extra pixel %0d", displayed);
            endcase
            displayed <= displayed + 1;
        end
    end
    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (4) @(negedge clk);
        de_in = 1'b1;
        repeat (4) @(negedge clk);
        de_in = 1'b0;
        repeat (35) @(negedge clk);
        if (popped != 2 || displayed != 4)
            $fatal(1, "counts popped=%0d displayed=%0d", popped, displayed);
        $display("PASS transition video: word pipeline and four RGB565 pixels align");
        $finish;
    end
endmodule
