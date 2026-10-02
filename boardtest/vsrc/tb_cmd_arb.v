// tb_cmd_arb.v — 命令仲裁（cmd_arb）自检测试台
//
// 为什么单独测它：这段仲裁原先只是顶层里 10 行胶水，**不在任何仿真范围内**，
// 结果"命令晚一拍"的 bug（按 N 回来的却是上一条 A 的 ACK）只能上板才发现。
// 它管的是"多传输前端 → ctrl_core"唯一的汇合点，值得单独有护栏。
//
// 覆盖：
//   T1 以太网命令取走拍：cmd_val 单拍 + cmd_byte 当拍就是**本条**命令
//   T2 连续两条以太网命令不串（"晚一拍"回归，核心用例）
//   T3 串口命令（同域单拍 valid）也能汇出来
//   T4 同拍冲突 → 以太网优先
//   T5 pending 保持高电平只 take 一次（边沿触发，不重复触发）
//   T6 eth_ack_tog 每条以太网命令翻转一次（串口命令不翻转）
`timescale 1ns/1ps
module tb_cmd_arb;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;

    reg        eth_pending  = 1'b0;
    reg  [7:0] eth_cmd      = 8'h00;
    wire       eth_ack_tog;
    reg  [7:0] uart_cmd     = 8'h00;
    reg        uart_cmd_val = 1'b0;
    wire       cmd_val;
    wire [7:0] cmd_byte;

    cmd_arb dut (
        .clk          (clk),
        .eth_pending  (eth_pending),
        .eth_cmd      (eth_cmd),
        .eth_ack_tog  (eth_ack_tog),
        .uart_cmd     (uart_cmd),
        .uart_cmd_val (uart_cmd_val),
        .cmd_val      (cmd_val),
        .cmd_byte     (cmd_byte)
    );

    integer errors = 0;
    task fail_msg(input [255:0] m);
        begin
            errors = errors + 1;
            $display("FAIL t=%0t: %0s", $time, m);
        end
    endtask

    // 采集每次 cmd_val 那一拍的 cmd_byte（关键：必须是当拍值）
    integer   take_n = 0;
    reg [7:0] taken [0:15];
    integer   ack_n  = 0;
    // 按"出口那一拍是谁"直接统计，不靠 TB 手工计数（T4/T5 手工驱动 pending，
    // 手工计数会漏）。同拍冲突按以太网优先归属，与 DUT 的仲裁一致。
    integer   eth_n  = 0;      // 以太网取走次数（应恰好 = ack 翻转次数）
    integer   uart_n = 0;      // 串口取走次数
    reg       ack_d  = 1'b0;
    always @(posedge clk) begin
        if (cmd_val) begin
            taken[take_n] = cmd_byte;
            take_n = take_n + 1;
            if (uart_cmd_val) uart_n = uart_n + 1;
            else              eth_n  = eth_n  + 1;
        end
        if (eth_ack_tog !== ack_d) begin
            ack_n = ack_n + 1;
            ack_d = eth_ack_tog;
        end
    end

    // 模拟以太网前端：置 pending + 稳定命令字节；见到 ack 后清 pending
    task eth_send(input [7:0] c);
        begin
            eth_cmd     = c;
            eth_pending = 1'b1;          // eth_front 里 cmd 与 pending 同拍置起
            repeat (5) @(posedge clk);   // 同步器 2FF + 边沿检测 ≈3 拍
            eth_pending = 1'b0;          // 已取走（ack 已翻转），前端清 pending
            repeat (2) @(posedge clk);
        end
    endtask

    integer n0;
    initial begin
        repeat (10) @(posedge clk);
        rst = 0;
        repeat (10) @(posedge clk);

        // ---- T1：单条以太网命令（先来一条预热，避免"上一条"恰为 0 时看不出错）----
        eth_send(8'h50);                         // 'P' 预热
        n0 = take_n;
        eth_send(8'h4E);                         // 'N'
        if (take_n !== n0 + 1) fail_msg("T1 take 次数不对（应恰好 1 次）");
        else if (taken[take_n-1] !== 8'h4E)
            fail_msg("T1 取走拍送出的命令字节不对（应为本条 0x4E）");
        else $display("T1 单条以太网命令取走拍正确: PASS");

        // ---- T2：连续两条不串（"晚一拍"回归）----
        n0 = take_n;
        eth_send(8'h41);                         // 'A'
        eth_send(8'h4E);                         // 'N'
        if (take_n !== n0 + 2) fail_msg("T2 take 次数不对");
        else if (taken[n0] !== 8'h41 || taken[n0+1] !== 8'h4E) begin
            fail_msg("T2 连续两条命令串了（晚一拍 bug 回归！）");
            $display("      taken[0]=%02x taken[1]=%02x（应 41 4e）",
                     taken[n0], taken[n0+1]);
        end else
            $display("T2 连续两条命令不串（晚一拍回归）: PASS");

        // ---- T3：串口命令（同域单拍 valid）----
        n0 = take_n;
        uart_cmd = 8'h2B; uart_cmd_val = 1'b1;   // '+'
        @(posedge clk);
        uart_cmd_val = 1'b0;
        repeat (2) @(posedge clk);
        if (take_n !== n0 + 1 || taken[take_n-1] !== 8'h2B)
            fail_msg("T3 串口命令未正确汇出");
        else $display("T3 串口命令汇出: PASS");

        // ---- T4：同拍冲突 → 以太网优先 ----
        n0 = take_n;
        eth_cmd = 8'h53; eth_pending = 1'b1;     // 'S'（以太网）
        repeat (3) @(posedge clk);               // 让 pending 同步到 take 拍
        // 在 take 拍附近同时给串口命令（探针：uart 每拍都在报）
        uart_cmd = 8'h41; uart_cmd_val = 1'b1;
        @(posedge clk);
        uart_cmd_val = 1'b0;
        eth_pending = 1'b0;
        repeat (2) @(posedge clk);
        if (take_n <= n0) fail_msg("T4 未取走命令");
        else if (taken[n0] !== 8'h53) begin
            fail_msg("T4 同拍冲突时未按以太网优先");
            $display("      首个 take = %02x（应 53）", taken[n0]);
        end else
            $display("T4 同拍冲突以太网优先: PASS");

        // ---- T5：pending 保持高电平只 take 一次 ----
        n0 = take_n;
        eth_cmd = 8'h3E; eth_pending = 1'b1;     // '>'
        repeat (30) @(posedge clk);              // 一直保持高
        eth_pending = 1'b0;
        repeat (2) @(posedge clk);
        if (take_n !== n0 + 1) fail_msg("T5 pending 保持高电平却重复 take");
        else $display("T5 pending 高电平只 take 一次: PASS");

        // ---- T6：eth_ack_tog 每条以太网命令翻转一次（串口不翻）----
        if (ack_n !== eth_n) begin
            fail_msg("T6 eth_ack_tog 翻转次数与以太网命令条数不符");
            $display("      发 %0d 条以太网命令，ack 翻转 %0d 次（应相等）", eth_n, ack_n);
        end else if (take_n !== eth_n + uart_n) begin
            fail_msg("T6 take 总数与出口归属统计不符");
            $display("      take %0d = eth %0d + uart %0d", take_n, eth_n, uart_n);
        end else if (uart_n !== 2) begin
            fail_msg("T6 串口取走次数应为 2（T3 一条 + T4 冲突一条）");
        end else
            $display("T6 eth_ack_tog 每命令翻转一次（eth %0d 条 / uart %0d 条）: PASS",
                     eth_n, uart_n);

        if (errors == 0) $display("==== ALL PASS ====");
        else             $display("==== %0d FAILED ====", errors);
        $finish;
    end

    initial begin
        #200_000;
        $display("FAIL: 仿真超时");
        $finish;
    end

endmodule
