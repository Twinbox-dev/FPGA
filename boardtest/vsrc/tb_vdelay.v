// tb_vdelay.v — video_delay RGB565 解包 / 2:1 串行化的独立自检测试台
//
// 背景（2026-09-27）：boardtest 主仿真不含视频读通道（C++ 模型替代
// frame_read_write，video_delay 完全不在仿真内），video_delay 的
// "相邻像素左右互换" bug（pd 分支对调）即漏网于此。本 TB 用行为级
// FIFO 桩逐拍验证：像素顺序、565→888 位复制、跨行连续性。
//
// 桩语义与真实 rfifo_32_32_512 一致：re 高的下一拍 dout 更新并保持。
`timescale 1ns/1ps
module tb_vdelay;
    localparam W = 1280;         // 每行像素数
    localparam HPER = 1650;      // 行总长（含消隐）
    localparam LINES = 3;        // 连续校验的行数

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;

    reg hs = 0, vs = 0, de = 0;
    wire        read_en;
    reg  [31:0] dout_r = 0;
    wire [31:0] read_data = dout_r;
    wire        hs_r, vs_r, de_r;
    wire [23:0] vout_data;

    video_delay u_dut (
        .video_clk (clk),
        .rst       (rst),
        .read_en   (read_en),
        .read_data (read_data),
        .hs        (hs),
        .vs        (vs),
        .de        (de),
        .hs_r      (hs_r),
        .vs_r      (vs_r),
        .de_r      (de_r),
        .vout_data (vout_data)
    );

    // ---- 行为级读 FIFO：re 高的下一拍 dout 更新并保持 ----
    reg [31:0] mem [0:4095];
    integer rp = 0;
    always @(posedge clk) begin
        if (rst) begin
            rp     <= 0;
            dout_r <= 0;
        end else if (read_en) begin
            dout_r <= mem[rp];
            rp     <= rp + 1;
        end
    end

    // ---- 期望值：word k = {hi16(l,k), lo16(l,k)}，低半字 = 偶数像素 ----
    function [15:0] lo16(input integer l, input integer k);
        lo16 = {l[2:0], k[7:0], 5'b10101};
    endfunction
    function [15:0] hi16(input integer l, input integer k);
        hi16 = {l[2:0], k[7:0], 5'b01010};
    endfunction
    function [23:0] expand565(input [15:0] v);   // 与 video_delay 位复制一致
        expand565 = {v[15:11], v[15:13], v[10:5], v[10:9], v[4:0], v[4:2]};
    endfunction

    integer errors = 0;
    integer l, k;

    // 预载 3 行字流（每行内容含行号，可查跨行错位）
    initial begin
        for (l = 0; l < LINES; l = l + 1)
            for (k = 0; k < W/2; k = k + 1)
                mem[(l * W)/2 + k] = {hi16(l, k), lo16(l, k)};
    end

    // ---- 校验器：de_r 活动期逐拍比对（#1 采样避开竞争）----
    integer off = 0, line_no = 0;
    reg [23:0] exp;
    always @(posedge clk) begin
        #1;
        if (!rst) begin
            if (vs_r)
                line_no = 0;
            if (de_r) begin
                k = off / 2;
                if (off[0]) exp = expand565(hi16(line_no, k));
                else        exp = expand565(lo16(line_no, k));
                if (vout_data !== exp) begin
                    errors = errors + 1;
                    $display("FAIL line=%0d off=%0d got=%06x exp=%06x",
                             line_no, off, vout_data, exp);
                end
                off = off + 1;
            end else if (off != 0) begin
                if (off != W) begin
                    errors = errors + 1;
                    $display("FAIL line=%0d de 计数=%0d 应=%0d", line_no, off, W);
                end
                off = 0;
                line_no = line_no + 1;
            end
        end
    end

    // ---- 驱动：复位 → vs 脉冲 → 3 行（空40 + de1280 + 空330）----
    integer t;
    initial begin
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (4) @(posedge clk);
        #1 vs = 1; repeat (5) @(posedge clk); #1 vs = 0;
        for (l = 0; l < LINES; l = l + 1) begin
            #1 de = 0;
            repeat (40) @(posedge clk);
            #1 de = 1;
            repeat (W) @(posedge clk);
            #1 de = 0;
            repeat (HPER - 40 - W) @(posedge clk);
        end
        repeat (20) @(posedge clk);
        if (errors == 0) $display("==== ALL PASS ====");
        else             $display("==== %0d FAILURES ====", errors);
        $finish;
    end

    initial begin
        #2000000;
        $display("==== GLOBAL TIMEOUT ====");
        $finish;
    end
endmodule
