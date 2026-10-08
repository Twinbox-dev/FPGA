`timescale 1ns/1ps
module tb_subtitle_store;
    reg sd_clk = 1'b0, video_clk = 1'b0;
    always #5 sd_clk = ~sd_clk;
    always #6.667 video_clk = ~video_clk;
    reg rst = 1'b1, wr_en = 1'b0, commit = 1'b0, vs = 1'b0;
    reg [7:0] wr_index = 0, wr_char = 0, rd_index = 0, commit_len = 0;
    wire ack, changed;
    wire [7:0] rd_char, active_len;
    subtitle_store dut (
        .sd_clk(sd_clk), .video_clk(video_clk), .rst(rst),
        .wr_en(wr_en), .wr_index(wr_index), .wr_char(wr_char),
        .commit_toggle(commit), .commit_len(commit_len),
        .swap_ack_toggle(ack), .vs(vs), .rd_index(rd_index),
        .rd_char(rd_char), .active_len(active_len),
        .text_changed_pulse(changed)
    );
    task automatic write_char(input [7:0] idx, input [7:0] ch);
        begin
            @(negedge sd_clk); wr_index = idx; wr_char = ch; wr_en = 1'b1;
            @(negedge sd_clk); wr_en = 1'b0;
        end
    endtask
    task automatic pulse_vs;
        begin
            @(negedge video_clk); vs = 1'b1;
            @(negedge video_clk); vs = 1'b0;
        end
    endtask
    task automatic expect_char(input [7:0] idx, input [7:0] ch);
        begin
            @(negedge video_clk); rd_index = idx;
            @(negedge video_clk);
            if (rd_char !== ch)
                $fatal(1, "text char %0d expected %h got %h", idx, ch, rd_char);
        end
    endtask
    initial begin
        repeat (4) @(negedge video_clk); rst = 1'b0;
        write_char(0, "A");
        write_char(1, "B");
        @(negedge sd_clk); commit_len = 2; commit = 1'b1;
        repeat (8) @(negedge video_clk);
        if (active_len != 0 || ack) $fatal(1, "text changed before VS");
        pulse_vs();
        repeat (3) @(negedge video_clk);
        if (active_len != 2 || !ack) $fatal(1, "first bank swap failed");
        expect_char(0, "A"); expect_char(1, "B");

        repeat (5) @(negedge sd_clk);
        write_char(0, "C");
        expect_char(0, "A"); // active bank remains intact during the next upload
        @(negedge sd_clk); commit_len = 1; commit = 1'b0;
        repeat (8) @(negedge video_clk);
        if (active_len != 2) $fatal(1, "second text leaked before VS");
        pulse_vs();
        repeat (3) @(negedge video_clk);
        if (active_len != 1 || ack) $fatal(1, "second bank swap failed");
        expect_char(0, "C");

        @(negedge sd_clk); commit_len = 0; commit = 1'b1;
        repeat (8) @(negedge video_clk);
        pulse_vs();
        repeat (3) @(negedge video_clk);
        if (active_len != 0 || !ack) $fatal(1, "clear subtitle failed");
        $display("PASS subtitle store: dual clock, atomic VS swaps and clear");
        $finish;
    end
endmodule
