`timescale 1ns/1ps
module tb_transition_blender;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;
    reg line_de = 1'b0, pop = 1'b0;
    reg [31:0] old_word = 32'd0, new_word = 32'hffffffff;
    reg active = 1'b1, ready = 1'b1, prev = 1'b0;
    reg [1:0] mode = 2'd1;
    reg [8:0] alpha = 9'd128;
    reg [10:0] progress = 11'd640;
    wire [31:0] mixed;
    transition_blender dut (
        .video_clk(clk), .rst(rst), .line_de(line_de), .word_pop(pop),
        .old_word(old_word), .new_word(new_word),
        .effect_active(active), .row_ready(ready), .effect_mode(mode),
        .direction_prev(prev), .fade_alpha(alpha),
        .wipe_progress(progress), .mixed_word(mixed)
    );

    task automatic send_word;
        begin
            @(negedge clk); line_de = 1'b1; pop = 1'b1;
            @(negedge clk); pop = 1'b0;
            @(negedge clk);
        end
    endtask

    integer i;
    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;
        send_word();
        if (mixed !== 32'h7bef7bef)
            $fatal(1, "half fade expected 7bef7bef got %h", mixed);

        ready = 1'b0;
        old_word = 32'h12345678;
        send_word();
        if (mixed !== old_word)
            $fatal(1, "missing row must use old pixels");

        @(negedge clk); line_de = 1'b0;
        ready = 1'b1; mode = 2'd2; prev = 1'b0;
        old_word = 32'd0; new_word = 32'hffffffff;
        @(negedge clk);
        send_word();
        if (mixed !== 32'd0)
            $fatal(1, "right-to-left wipe changed the left edge");
        for (i = 1; i < 337; i = i + 1) begin
            send_word();
            if (i == 320 && mixed !== 32'h00200000)
                $fatal(1, "soft edge must use separate alpha for both pixels: %h", mixed);
        end
        if (mixed !== 32'hffffffff)
            $fatal(1, "right-to-left wipe failed past the 32-pixel feather");

        @(negedge clk); line_de = 1'b0;
        prev = 1'b1;
        @(negedge clk);
        send_word();
        if (mixed !== 32'hffffffff)
            $fatal(1, "left-to-right wipe did not reveal the left edge");
        $display("PASS transition blender: fade, missing row, both wipe directions");
        $finish;
    end
endmodule
