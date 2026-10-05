`timescale 1ns/1ps
module tb_writeprobe;
    reg src_clk = 0, mem_clk = 0;
    always #5 src_clk = ~src_clk;
    always #4 mem_clk = ~mem_clk;
    reg rst = 1, src_val = 0, src_end = 0, wr_en = 0;
    reg [31:0] wr_data = 0;
    reg [20:0] wr_addr = 0;
    wire tap_val, tap_end;
    wire [31:0] tap_data, tap_addr;
    write_port_probe dut (
        .src_clk(src_clk), .mem_clk(mem_clk), .rst(rst),
        .src_val(src_val), .src_end(src_end),
        .wr_en(wr_en), .wr_data(wr_data), .wr_addr(wr_addr),
        .tap_val(tap_val), .tap_data(tap_data),
        .tap_addr(tap_addr), .tap_end(tap_end)
    );

    integer got = 0, ends = 0, errors = 0, i;
    reg [31:0] data_seen [0:31], addr_seen [0:31];
    always @(posedge mem_clk) begin
        if (tap_val) begin
            data_seen[got] = tap_data;
            addr_seen[got] = tap_addr;
            got = got + 1;
        end
        if (tap_end) ends = ends + 1;
    end

    task write_word(input [31:0] data, input [20:0] addr);
        begin
            @(negedge mem_clk); wr_en = 1; wr_data = data; wr_addr = addr;
            @(negedge mem_clk); wr_en = 0;
        end
    endtask
    task source_pulse(input end_session);
        begin
            @(negedge src_clk); src_val = !end_session; src_end = end_session;
            @(negedge src_clk); src_val = 0; src_end = 0;
        end
    endtask

    initial begin
        repeat (6) @(negedge src_clk);
        rst = 0;
        write_word(32'hDEADBEEF, 21'd100); // 涂黑/其它写会话必须被过滤
        source_pulse(0);
        repeat (6) @(negedge mem_clk); // 等跨域武装
        for (i = 0; i < 12; i = i + 1)
            write_word(32'hA5000000 | i, 21'd460800 + i);
        source_pulse(1);
        repeat (8) @(negedge mem_clk);
        write_word(32'hDEADBEEF, 21'd999); // 结束后的其它写会话亦被过滤

        if (got != 12 || ends != 1) errors = errors + 1;
        for (i = 0; i < 12; i = i + 1)
            if (data_seen[i] !== (32'hA5000000 | i) ||
                addr_seen[i] !== (32'd460800 + i)) errors = errors + 1;
        if (errors) $fatal(1, "write_port_probe failed: errors=%0d got=%0d ends=%0d", errors, got, ends);
        $display("SDRAM-write-port data/address probe: PASS");
        $finish;
    end
endmodule
