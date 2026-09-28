// tb_uart.v — uart_link 独立自检测试台
//
// 覆盖：RX 位中心采样、[CMD,~CMD] 成对校验（含不成对/未知命令拒收）、
// 虚拟按键脉冲宽度、状态包内容、毛刺拒收，以及全真实参数（10M）脉宽
// 位宽截断回归。
// TB 用缩短参数（VK_PULSE_CYC=5000 拍）加速，波特率与协议语义不变；
// 宽度类问题由第二实例 dut_full（全部真实默认参数）的 T7 覆盖。
`timescale 1ns/1ps
module tb_uart;
    localparam BIT_NS = 1000;             // 1Mbaud @100MHz = 1us/bit

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;

    reg  rx = 1;
    wire tx;
    wire vk_next_n, vk_auto_n;

    reg  [3:0] state_code    = 4'h2;
    reg  [7:0] dbg_fat_state = 8'h08;
    reg  [3:0] flag_a        = 4'hF;
    reg  [3:0] flag_b        = 4'h9;
    reg  [3:0] dbg_underrun  = 4'h0;

    uart_link #(
        .CLK_FREQ_HZ    (100_000_000),
        .BAUD           (1_000_000),
        .VK_PULSE_CYC   (5000)            // TB: 50us（原 50ms）
    ) dut (
        .clk           (clk),
        .rst           (rst),
        .rx            (rx),
        .tx            (tx),
        .vk_next_n     (vk_next_n),
        .vk_auto_n     (vk_auto_n),
        .state_code    (state_code),
        .dbg_fat_state (dbg_fat_state),
        .flag_a        (flag_a),
        .flag_b        (flag_b),
        .dbg_underrun  (dbg_underrun)
    );

    // 第二实例：全部真实默认参数（VK_PULSE_CYC=10M），专测计数器位宽——
    // 短参数测试测不出 vk_cnt 位宽截断（23 位时 10M 被截成 16ms，板上
    // 永远过不了 50ms 去抖，仿真却全绿）
    wire tx_full, vk_next_n_full, vk_auto_n_full;
    uart_link dut_full (
        .clk           (clk),
        .rst           (rst),
        .rx            (rx),
        .tx            (tx_full),
        .vk_next_n     (vk_next_n_full),
        .vk_auto_n     (vk_auto_n_full),
        .state_code    (state_code),
        .dbg_fat_state (dbg_fat_state),
        .flag_a        (flag_a),
        .flag_b        (flag_b),
        .dbg_underrun  (dbg_underrun)
    );

    integer errors = 0;
    task fail_msg(input [255:0] m);
        begin
            errors = errors + 1;
            $display("FAIL t=%0t: %0s", $time, m);
        end
    endtask

    // ---- 发一个字节（LSB first，1 位帧间隔）----
    task uart_send(input [7:0] b);
        integer i;
        begin
            rx = 0;                       // 起始位
            #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin
                rx = b[i];
                #(BIT_NS);
            end
            rx = 1;                       // 停止位
            #(BIT_NS);
            #(BIT_NS);                    // 帧间隔 ≥1 位
        end
    endtask

    task uart_send_pair(input [7:0] cmd);
        begin
            uart_send(cmd);
            uart_send(~cmd);
        end
    endtask

    // ---- 收 n_bytes 个字节（下降沿对齐位中心采样）----
    reg [7:0] rxq [0:255];
    integer   rxq_n = 0;
    task uart_recv(input integer n_bytes);
        integer i, j;
        reg [7:0] b;
        begin
            for (i = 0; i < n_bytes; i = i + 1) begin
                @(negedge tx);
                #(BIT_NS/2 + BIT_NS);     // 1.5 位 → bit0 中心
                b = 0;
                for (j = 0; j < 8; j = j + 1) begin
                    b[j] = tx;
                    #(BIT_NS);
                end
                if (tx !== 1'b1) fail_msg("TX 停止位不为 1");
                if (rxq_n < 256) begin
                    rxq[rxq_n] = b;
                    rxq_n = rxq_n + 1;
                end
            end
        end
    endtask

    // ---- 虚拟按键脉冲宽度测量（which: 0=next 1=auto）----
    integer cyc;
    task wait_pulse_low(input integer which);
        begin
            if (which == 0) @(negedge vk_next_n);
            else            @(negedge vk_auto_n);
            cyc = 0;
            while (which == 0 ? !vk_next_n : !vk_auto_n) begin
                @(posedge clk);
                cyc = cyc + 1;
            end
        end
    endtask

    initial begin
        repeat (10) @(posedge clk);
        rst = 0;
        repeat (10) @(posedge clk);

        // T1: 'N' 对 → vk_next_n 低脉冲 ≈5000 拍
        fork
            uart_send_pair(8'h4E);
            wait_pulse_low(0);
        join
        // 实际脉宽 = VK_PULSE_CYC-1 拍（vk_cnt 从 CYC-1 递减），测量含 +1 对齐
        // 偏移 → 期望恰为 VK_PULSE_CYC。上板 bug：脉冲曾设 50ms 与去抖窗等长，
        // 差 1 拍永远过不了去抖——此断言防止再把宽度缩回去
        if (cyc < 4998 || cyc > 5000) fail_msg("T1 vk_next 脉冲宽度异常");
        else $display("T1 vk_next pulse=%0d cyc: PASS", cyc);

        // T2: 不成对 'N','N' 不触发（等 2ms ≫ 50us 脉冲窗）
        uart_send(8'h4E);
        uart_send(8'h4E);
        repeat (200000) @(posedge clk);
        if (vk_next_n === 1'b0) fail_msg("T2 不成对命令误触发");
        else $display("T2 unpaired rejected: PASS");

        // T3: 未知命令对不触发
        uart_send_pair(8'h5A);
        repeat (200000) @(posedge clk);
        if (vk_next_n === 1'b0 || vk_auto_n === 1'b0) fail_msg("T3 未知命令误触发");
        else $display("T3 unknown cmd rejected: PASS");

        // T4: 'A' 对 → vk_auto_n 脉冲
        fork
            uart_send_pair(8'h41);
            wait_pulse_low(1);
        join
        if (cyc < 4998 || cyc > 5000) fail_msg("T4 vk_auto 脉冲宽度异常");
        else $display("T4 vk_auto pulse=%0d cyc: PASS", cyc);

        // T5: 'S' 对 → 8 字节状态包（recv 与 send 并发：命令在第二字节停止位
        // 中心即解码发包，若等 send 返回再收会错过首字节起始位）
        fork
            uart_send_pair(8'h53);
            uart_recv(8);
        join
        if (rxq_n != 8) begin
            fail_msg("T5 状态包字节数不对");
        end else if (rxq[0] !== 8'hA5 || rxq[1] !== {4'b0, state_code}
                  || rxq[2] !== dbg_fat_state || rxq[3] !== {4'b0, flag_a}
                  || rxq[4] !== {4'b0, flag_b} || rxq[5] !== {4'b0, dbg_underrun}
                  || rxq[6] !== 8'h00     || rxq[7] !== 8'h00) begin
            fail_msg("T5 状态包内容不对");
            for (integer i = 0; i < 8; i = i + 1)
                $display("      pkt[%0d]=%02x", i, rxq[i]);
        end else
            $display("T5 status packet: PASS");

        // T6: RX 毛刺（1/4 位低脉冲）不触发任何动作
        rx = 0; #(BIT_NS/4); rx = 1;
        repeat (50000) @(posedge clk);
        if (vk_next_n === 1'b0 || vk_auto_n === 1'b0) fail_msg("T6 毛刺误触发");
        else $display("T6 glitch rejected: PASS");

        // T7: 真实参数（VK_PULSE_CYC=10M）脉宽——专测计数器位宽截断。
        // 板上去抖要求连续 5,000,000 个低采样沿（DEBOUNCE_MS=50@100MHz），
        // 脉冲必须显著长于此。
        // 注意：dut_full 共享 rx，T1 的 'N' 已触发它拉出 100ms 脉冲且脉冲
        // 期间新命令被忽略——必须先等残留脉冲结束再发 T7 的命令
        wait (vk_next_n_full === 1'b1);
        fork
            uart_send_pair(8'h4E);
            begin
                @(negedge vk_next_n_full);
                cyc = 0;
                while (!vk_next_n_full) begin
                    @(posedge clk);
                    cyc = cyc + 1;
                end
            end
        join
        if (cyc < 9_999_000 || cyc > 10_001_000)
            fail_msg("T7 全参数 vk_next 脉宽异常（疑位宽截断）");
        else if (cyc <= 5_000_000)
            fail_msg("T7 脉宽未超过 50ms 去抖窗");
        else
            $display("T7 full-param pulse=%0d cyc (>5M debounce): PASS", cyc);

        if (errors == 0) $display("==== ALL PASS ====");
        else             $display("==== %0d FAILURES ====", errors);
        $finish;
    end

    initial begin
        #600_000_000;                     // 600ms 硬超时（T7 需 ~100ms）
        $display("==== GLOBAL TIMEOUT ====");
        $finish;
    end
endmodule
