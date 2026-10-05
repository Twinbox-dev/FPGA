`timescale 1ns/1ps
module tb_memdump;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, start_tog = 0, video_ack = 0;
    reg rd_valid = 0, rd_audio = 0;
    reg [31:0] rd_word = 0;
    wire tap_val, tap_end;
    wire [31:0] tap_word;
    mem_return_dump #(.WORDS(12)) dut (
        .mem_clk(clk), .rst(rst), .start_tog(start_tog),
        .video_ack(video_ack), .rd_valid(rd_valid),
        .rd_word(rd_word), .rd_audio(rd_audio),
        .tap_val(tap_val), .tap_word(tap_word), .tap_end(tap_end)
    );

    integer got = 0, ends = 0, errors = 0, i;
    reg [31:0] captured [0:31];
    always @(posedge clk) begin
        if (tap_val) begin
            captured[got] = tap_word;
            got = got + 1;
        end
        if (tap_end) ends = ends + 1;
    end

    task trigger;
        begin
            @(negedge clk); start_tog = ~start_tog;
            repeat (5) @(negedge clk);
            video_ack = 1;
            @(negedge clk); video_ack = 0;
            repeat (2) @(negedge clk);
        end
    endtask
    task send_word(input [31:0] word, input audio_word);
        begin
            @(negedge clk); rd_word = word; rd_audio = audio_word; rd_valid = 1;
            @(negedge clk); rd_valid = 0; rd_audio = 0;
        end
    endtask

    initial begin
        repeat (5) @(negedge clk);
        rst = 0;
        trigger();
        for (i = 0; i < 12; i = i + 1) begin
            if (i % 4 == 0) send_word(32'hDEAD0000 | i, 1);
            send_word(32'hA5000000 | i, 0);
        end
        repeat (4) @(negedge clk);
        if (got != 12 || ends != 1) errors = errors + 1;
        for (i = 0; i < 12; i = i + 1)
            if (captured[i] !== (32'hA5000000 | i)) errors = errors + 1;

        // 不足一帧时下一次视频 ack 强制冲洗，避免后续会话被残字污染。
        trigger();
        for (i = 0; i < 5; i = i + 1)
            send_word(32'hB6000000 | i, 0);
        @(negedge clk); video_ack = 1;
        @(negedge clk); video_ack = 0;
        repeat (4) @(negedge clk);
        if (got != 17 || ends != 2) errors = errors + 1;
        for (i = 0; i < 5; i = i + 1)
            if (captured[12+i] !== (32'hB6000000 | i)) errors = errors + 1;
        if (errors) $fatal(1, "mem_return_dump failed: errors=%0d got=%0d ends=%0d", errors, got, ends);
        $display("SDRAM-return dump window: PASS");
        $finish;
    end
endmodule
