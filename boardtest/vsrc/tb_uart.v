// tb_uart.v — UART 前端（uart_link）+ 控制核心（ctrl_core）自检测试台
//
// 覆盖：RX 位中心采样、[CMD,~CMD] 成对校验（含不成对/未知命令拒收）、
// 虚拟按键脉冲宽度（N/A/P 三向）、状态包内容（含 img_idx/wav 遥测）、
// 毛刺拒收，以及全真实参数（10M）脉宽位宽截断回归。
// TB 用缩短参数（VK_PULSE_CYC=5000 拍）加速，波特率与协议语义不变；
// 宽度类问题由第二实例 dut_full（全部真实默认参数）的 T7 覆盖。
`timescale 1ns/1ps
module tb_uart;
    localparam BIT_NS = 1000;             // 1Mbaud @100MHz = 1us/bit

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;

    reg  rx = 1;
    reg  touch_next = 0, touch_prev = 0;
    wire tx;
    wire vk_next_n, vk_auto_n, vk_prev_n;

    reg  [3:0] state_code    = 4'h2;
    reg  [7:0] dbg_fat_state = 8'h08;
    reg  [3:0] flag_a        = 4'hF;
    reg  [3:0] flag_b        = 4'h9;
    reg  [3:0] dbg_underrun  = 4'h0;
    reg  [4:0] img_idx       = 5'd3;
    reg        img_wav       = 1'b1;
    reg  auto_on_r = 1'b0;                 // 自动轮播状态遥测（T12 驱动，两实例共用）

    // 前端：UART 成帧 → cmd；核心：ctrl_core（命令语义 + 应答/状态包内容）
    wire [7:0]  cmd_w;
    wire        cmd_val_w, tx_req_w;
    wire [63:0] tx_pkt_w;
    wire [3:0]  vol_gain_w, ap_s_w, bri_gray_w, ct_gray_w;
    wire [1:0]  transition_mode_w;
    wire        bar_en_w;  wire [1:0] bar_sens_gray_w;   // 脉动条遥测（T14）

    uart_link #(
        .CLK_FREQ_HZ    (100_000_000),
        .BAUD           (1_000_000)
    ) dut (
        .clk           (clk),
        .rst           (rst),
        .rx            (rx),
        .tx            (tx),
        .cmd           (cmd_w),
        .cmd_val       (cmd_val_w),
        .tx_req        (tx_req_w),
        .tx_pkt        (tx_pkt_w)
    );

    ctrl_core #(
        .VK_PULSE_CYC   (5000)            // TB: 50us（原 100ms）
    ) core (
        .clk           (clk),
        .rst           (rst),
        .cmd           (cmd_w),
        .cmd_val       (cmd_val_w),
        .set_valid     (1'b0), .set_op(8'd0), .set_value(8'd0),
        .touch_next    (touch_next),
        .touch_prev    (touch_prev),
        .subtitle_consume (1'b0),
        .subtitle_ack_pulse (1'b0),
        .subtitle_ack_ok (1'b0),
        .vk_next_n     (vk_next_n),
        .vk_auto_n     (vk_auto_n),
        .vk_prev_n     (vk_prev_n),
        .tx_req        (tx_req_w),
        .tx_pkt        (tx_pkt_w),
        .vol_gain      (vol_gain_w),
        .brightness_value(), .contrast_value(), .sensitivity_value(),
        .auto_period_s (ap_s_w),
        .transition_mode (transition_mode_w),
        .bri_gray      (bri_gray_w),
        .ct_gray       (ct_gray_w),
        .bar_en        (bar_en_w),
        .bar_sens_gray (bar_sens_gray_w),
        .state_code    (state_code),
        .dbg_fat_state (dbg_fat_state),
        .flag_a        (flag_a),
        .flag_b        (flag_b),
        .dbg_underrun  (dbg_underrun),
        .img_idx       (img_idx),
        .img_wav       (img_wav),
        .auto_on       (auto_on_r)
    );

    // 第二实例：全部真实默认参数（VK_PULSE_CYC=10M），专测计数器位宽——
    // 短参数测试测不出 vk_cnt 位宽截断（23 位时 10M 被截成 16ms，板上
    // 永远过不了 50ms 去抖，仿真却全绿）
    wire tx_full, vk_next_n_full, vk_auto_n_full, vk_prev_n_full;
    wire [7:0]  cmd_f;  wire cmd_val_f, txr_f;  wire [63:0] pkt_f;  wire [3:0] vg_f, ap_f, bg_f, ctg_f;
    uart_link dut_full (
        .clk           (clk),
        .rst           (rst),
        .rx            (rx),
        .tx            (tx_full),
        .cmd           (cmd_f),
        .cmd_val       (cmd_val_f),
        .tx_req        (txr_f),
        .tx_pkt        (pkt_f)
    );
    ctrl_core core_full (
        .clk           (clk),
        .rst           (rst),
        .cmd           (cmd_f),
        .cmd_val       (cmd_val_f),
        .set_valid     (1'b0), .set_op(8'd0), .set_value(8'd0),
        .touch_next    (1'b0),
        .touch_prev    (1'b0),
        .subtitle_consume (1'b0),
        .subtitle_ack_pulse (1'b0),
        .subtitle_ack_ok (1'b0),
        .vk_next_n     (vk_next_n_full),
        .vk_auto_n     (vk_auto_n_full),
        .vk_prev_n     (vk_prev_n_full),
        .tx_req        (txr_f),
        .tx_pkt        (pkt_f),
        .vol_gain      (vg_f),
        .brightness_value(), .contrast_value(), .sensitivity_value(),
        .auto_period_s (ap_f),
        .bri_gray      (bg_f),
        .ct_gray       (ctg_f),
        .state_code    (state_code),
        .dbg_fat_state (dbg_fat_state),
        .flag_a        (flag_a),
        .flag_b        (flag_b),
        .dbg_underrun  (dbg_underrun),
        .img_idx       (img_idx),
        .img_wav       (img_wav),
        .auto_on       (auto_on_r)
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

    // ---- 虚拟按键脉冲宽度测量（which: 0=next 1=auto 2=prev）----
    integer cyc;
    task wait_pulse_low(input integer which);
        begin
            if      (which == 0) @(negedge vk_next_n);
            else if (which == 1) @(negedge vk_auto_n);
            else                 @(negedge vk_prev_n);
            cyc = 0;
            while (which == 0 ? !vk_next_n :
                   which == 1 ? !vk_auto_n : !vk_prev_n) begin
                @(posedge clk);
                cyc = cyc + 1;
            end
        end
    endtask

    // ---- 排空在途应答包：每条命令现在都会回一包（ACK/状态，解码最早发生在
    // pair 结束前 ~10us，一包 8B×10us=80us），后续 recv 类用例前必须等它发完，
    // 否则会错收上一包。固定等 140us 兜底（解码延迟 + 一整包 + 余量）----
    task drain_tx;
        begin
            #140_000;
        end
    endtask

    // 强版排空：等到 TX 线连续空闲 200us（> 任何字节间隔），确保所有在途包发完。
    // 固定 140us 只够 ~1.7 个包；像 T11b 那样连发 12 条命令会留下多个在途 ACK，
    // 后续 recv 就会错收旧包（T12b 曾因此误判）。
    integer idle_cyc;
    task drain_tx_idle;
        begin
            idle_cyc = 0;
            while (idle_cyc < 20_000) begin
                @(posedge clk);
                idle_cyc = tx ? idle_cyc + 1 : 0;
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

        drain_tx;   // 排空 T4 'A' 的 ACK 应答包，否则 T5 的 recv 会错收它

        // T5: 'S' 对 → 8 字节状态包（recv 与 send 并发：命令在第二字节停止位
        // 中心即解码发包，若等 send 返回再收会错过首字节起始位）
        fork
            uart_send_pair(8'h53);
            uart_recv(8);
        join
        if (rxq_n != 8) begin
            fail_msg("T5 状态包字节数不对");
        end else if (rxq[0] !== 8'hA5 || rxq[1] !== {4'b0, state_code}
                  || rxq[2] !== dbg_fat_state || rxq[3] !== {core.ct_level, flag_a}
                  || rxq[4] !== {3'b0, auto_on_r, flag_b} || rxq[5] !== {2'b0, core.osd_mode, dbg_underrun}
                  || rxq[6] !== {3'b0, img_idx} || rxq[7] !== {7'b0, img_wav}) begin
            fail_msg("T5 状态包内容不对");
            for (integer i = 0; i < 8; i = i + 1)
                $display("      pkt[%0d]=%02x", i, rxq[i]);
        end else
            $display("T5 status packet: PASS");

        // T6: RX 毛刺（1/4 位低脉冲）不触发任何动作
        rx = 0; #(BIT_NS/4); rx = 1;
        repeat (50000) @(posedge clk);
        if (vk_next_n === 1'b0 || vk_auto_n === 1'b0 || vk_prev_n === 1'b0)
            fail_msg("T6 毛刺误触发");
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

        // T8: 'P' 对 → vk_prev_n 脉冲（宽度同 N/A）
        fork
            uart_send_pair(8'h50);
            wait_pulse_low(2);
        join
        if (cyc < 4998 || cyc > 5000) fail_msg("T8 vk_prev 脉冲宽度异常");
        else $display("T8 vk_prev pulse=%0d cyc: PASS", cyc);

        // T9: 音量命令（'+'/'+'）——8 档、边界钳位
        if (vol_gain_w !== 4'd8) fail_msg("T9 上电音量不是 8（原始）");
        uart_send_pair(8'h2D);                     // '-' → 7
        repeat (100) @(posedge clk);
        if (vol_gain_w !== 4'd7) fail_msg("T9 音量- 未生效");
        uart_send_pair(8'h2B);                     // '+' → 8
        repeat (100) @(posedge clk);
        if (vol_gain_w !== 4'd8) fail_msg("T9 音量+ 未生效");
        uart_send_pair(8'h2B);                     // 上界钳位
        repeat (100) @(posedge clk);
        if (vol_gain_w !== 4'd8) fail_msg("T9 音量上界未钳位");
        for (int k = 0; k < 10; k++) uart_send_pair(8'h2D);   // 下界钳位
        repeat (100) @(posedge clk);
        if (vol_gain_w !== 4'd0) fail_msg("T9 音量下界未钳位（应到 0 停住）");
        else $display("T9 volume cmd (8档/钳位): PASS");

        // T10: 轮播周期命令（'>'/'<'）——1..10s、边界钳位、上电=1s
        if (core.auto_period_s !== 4'd1) fail_msg("T10 上电周期不是 1s");
        uart_send_pair(8'h3E);                     // '>' → 2s
        repeat (100) @(posedge clk);
        if (core.auto_period_s !== 4'd2) fail_msg("T10 周期+ 未生效");
        uart_send_pair(8'h3C);                     // '<' → 1s
        repeat (100) @(posedge clk);
        if (core.auto_period_s !== 4'd1) fail_msg("T10 周期- 未生效");
        uart_send_pair(8'h3C);                     // 下界钳位
        repeat (100) @(posedge clk);
        if (core.auto_period_s !== 4'd1) fail_msg("T10 周期下界未钳位");
        for (int k = 0; k < 12; k++) uart_send_pair(8'h3E);   // 上界钳位
        repeat (100) @(posedge clk);
        if (core.auto_period_s !== 4'd10) fail_msg("T10 周期上界未钳位（应到 10 停住）");
        else $display("T10 auto-period cmd (1..10s/钳位): PASS");

        // T11: 亮度命令（']'/'['）——9 档、上电=4（原始 0 偏移）、边界钳位；
        // 且每条命令现在都会回 ACK 包（5A | 回显 | vol | period | img | wav | bri | 00），
        // 端到端校验一包 ACK 的内容
        drain_tx;
        if (core.bri_level !== 4'd4) fail_msg("T11 上电亮度不是 4（原始）");
        // 注意：ACK 在 pair 结束前（解码拍）就开始发送，recv 必须与 send 并发
        // 才能从首字节起始位收起——与 T5 同款竞态
        fork
            uart_send_pair(8'h5D);                 // ']' → 5
            uart_recv(8);
            begin
                repeat (3000) @(posedge clk);   // 命令在 pair 末尾（~22us）才解码
                if (core.bri_level !== 4'd5) fail_msg("T11 亮度+ 未生效");
            end
        join
        if (rxq[rxq_n-8] !== 8'h5A || rxq[rxq_n-7] !== 8'h5D
            || rxq[rxq_n-2] !== {core.osd_mode, core.transition_mode, 4'd5}) begin
            fail_msg("T11 ACK 包内容不对（应为 5A|5D|vol|per|img|wav|05|00）");
            for (int k = 8; k > 0; k--)
                $display("      pkt[-%0d]=%02x", k, rxq[rxq_n-k]);
        end
        else
            $display("T11a 亮度+ 生效 + ACK 包正确: PASS");

        uart_send_pair(8'h5B);                     // '[' → 4
        repeat (100) @(posedge clk);
        if (core.bri_level !== 4'd4) fail_msg("T11 亮度- 未生效");
        for (int k = 0; k < 10; k++) uart_send_pair(8'h5B);   // 下界钳位 → 0
        repeat (100) @(posedge clk);
        if (core.bri_level !== 4'd0) fail_msg("T11 亮度下界未钳位（应到 0 停住）");
        for (int k = 0; k < 12; k++) uart_send_pair(8'h5D);   // 上界钳位 → 8
        repeat (100) @(posedge clk);
        if (core.bri_level !== 4'd8) fail_msg("T11 亮度上界未钳位（应到 8 停住）");
        else $display("T11b brightness cmd (9档/钳位): PASS");
        drain_tx;

        // T12: 自动轮播状态遥测——状态包 flagB 字节 bit4 + ACK 的 flags 字节 bit0
        //（Web 控制台据此显示"自动轮播 开/关"，见 docs/web_console.md）
        auto_on_r = 1'b1;
        drain_tx_idle;                             // T11b 连发留下的在途 ACK 必须排干净
        fork
            uart_send_pair(8'h53);                 // 'S' → 状态包
            uart_recv(8);
        join
        if ((rxq[rxq_n-4] & 8'h10) !== 8'h10) begin
            fail_msg("T12 状态包 flagB bit4 未反映自动轮播=开");
            $display("      pkt[4]=%02x（应为 ??1?，即 bit4=1）", rxq[rxq_n-4]);
        end else
            $display("T12a 状态包 自动轮播=开（flagB bit4）: PASS");

        drain_tx_idle;
        fork
            uart_send_pair(8'h4E);                 // 'N' → ACK
            uart_recv(8);
        join
        if ((rxq[rxq_n-1] & 8'h01) !== 8'h01) begin
            fail_msg("T12 ACK flags 字节 bit0 未反映自动轮播=开");
            $display("      pkt[7]=%02x（应为 ??1）", rxq[rxq_n-1]);
        end else
            $display("T12b ACK flags 字节 自动轮播=开: PASS");

        // 关掉再验一次（反向断言：确认不是恒 1）
        auto_on_r = 1'b0;
        drain_tx_idle;
        fork
            uart_send_pair(8'h4E);
            uart_recv(8);
        join
        if ((rxq[rxq_n-1] & 8'h01) !== 8'h00) fail_msg("T12 ACK flags 字节 bit0 应为 0");
        else $display("T12c ACK flags 字节 自动轮播=关: PASS");
        drain_tx_idle;

        // T13: 对比度（'.'升 ','降）——7 档、边界钳位、遥测位
        //（ACK flags bit[4:1] 与状态包 flagA 高 4 位）
        if (core.ct_level !== 4'd2) fail_msg("T13 上电对比度不是 2（原始）");
        uart_send_pair(8'h2E);                                  // '.' -> 3
        repeat (100) @(posedge clk);
        if (core.ct_level !== 4'd3) fail_msg("T13 对比度+ 未生效");
        for (int k = 0; k < 6; k++) uart_send_pair(8'h2E);      // 上界钳位 -> 6
        repeat (100) @(posedge clk);
        if (core.ct_level !== 4'd6) fail_msg("T13 对比度上界未钳位（应到 6 停住）");
        for (int k = 0; k < 8; k++) uart_send_pair(8'h2C);      // ',' 下界钳位 -> 0
        repeat (100) @(posedge clk);
        if (core.ct_level !== 4'd0) fail_msg("T13 对比度下界未钳位（应到 0 停住）");
        else $display("T13a 对比度命令 7 档/钳位: PASS");

        // 遥测：升到 1 档后，ACK flags bit[4:1] = 1（auto_on_r 此时为 0）
        drain_tx_idle;
        fork
            uart_send_pair(8'h2E);                              // '.' -> 1
            uart_recv(8);
        join
        if ((rxq[rxq_n-1] & 8'h0E) !== 8'h02) begin
            fail_msg("T13 ACK flags 的对比度位不对（bit[3:1] 应为 001）");
            $display("      pkt[7]=%02x", rxq[rxq_n-1]);
        end else
            $display("T13b ACK flags 对比度遥测: PASS");

        drain_tx_idle;
        fork
            uart_send_pair(8'h53);                              // 'S' -> 状态包
            uart_recv(8);
        join
        if ((rxq[rxq_n-5] >> 4) !== 4'd1) begin                 // pkt[3] = flagA 字节
            fail_msg("T13 状态包 flagA 高 4 位的对比度不对");
            $display("      pkt[3]=%02x（高 4 位应为 1）", rxq[rxq_n-5]);
        end else
            $display("T13c 状态包对比度遥测: PASS");
        drain_tx_idle;

        // T14: 音频脉动条（'Q' 开关 / ';' ''' 灵敏度 4 档）
        //      ACK flags：bit4=bar_en，bit[6:5]=灵敏度（格雷 2 位）
        if (core_full.bar_en_r !== 1'b0) fail_msg("T14 上电脉动条应为关");
        if (core_full.bar_sens !== 2'd1) fail_msg("T14 上电灵敏度应为 1");
        uart_send_pair(8'h51);                                  // 'Q' -> 开
        repeat (100) @(posedge clk);
        if (core_full.bar_en_r !== 1'b1) fail_msg("T14 'Q' 开关未生效");
        else $display("T14a 'Q' 开启脉动条: PASS");
        uart_send_pair(8'h51);                                  // 'Q' -> 关
        repeat (100) @(posedge clk);
        if (core_full.bar_en_r !== 1'b0) fail_msg("T14 'Q' 再次按下未关闭");
        else $display("T14b 'Q' 关闭脉动条: PASS");
        for (int k = 0; k < 5; k++) uart_send_pair(8'h27);      // ''' 上界钳位 -> 3
        repeat (100) @(posedge clk);
        if (core_full.bar_sens !== 2'd3) fail_msg("T14 灵敏度上界未钳位（应到 3 停住）");
        for (int k = 0; k < 5; k++) uart_send_pair(8'h3B);      // ';' 下界钳位 -> 0
        repeat (100) @(posedge clk);
        if (core_full.bar_sens !== 2'd0) fail_msg("T14 灵敏度下界未钳位（应到 0 停住）");
        else $display("T14c 灵敏度 4 档/钳位: PASS");

        // 遥测：开 + 灵敏度 2（格雷 3），ACK flags = {0, 11, 1, ccc, a}
        uart_send_pair(8'h27);                                  // ''' -> 1
        uart_send_pair(8'h27);                                  // ''' -> 2
        uart_send_pair(8'h51);                                  // 'Q' -> 开
        repeat (100) @(posedge clk);
        drain_tx_idle;
        fork
            uart_send_pair(8'h4E);                              // 'N' -> ACK
            uart_recv(8);
        join
        if ((rxq[rxq_n-1] & 8'h70) !== 8'h50
            || (rxq[rxq_n-1] & 8'h10) !== 8'h10) begin
            fail_msg("T14 ACK flags 遥测不对（bit4=1、bit[6:5]=格雷11）");
            $display("      pkt[7]=%02x", rxq[rxq_n-1]);
        end else
            $display("T14d ACK flags 脉动遥测: PASS");
        uart_send_pair(8'h3B);                                  // ';' 回灵敏度 1
        uart_send_pair(8'h51);                                  // 'Q' 回关
        repeat (100) @(posedge clk);
        drain_tx_idle;

        // T15: explicit effect mode commands survive UART framing and report
        // the selected mode in both ACK brightness high bits and status flagB.
        if (core_full.transition_mode !== 2'd0) fail_msg("T15 default effect must be cut");
        drain_tx_idle;
        fork
            uart_send_pair(8'h31);                              // '1' crossfade
            uart_recv(8);
        join
        if (core_full.transition_mode !== 2'd1 ||
            ((rxq[rxq_n-2] >> 4) & 8'h03) !== 8'd1)
            fail_msg("T15 crossfade command or ACK mode wrong");
        drain_tx_idle;
        fork
            uart_send_pair(8'h32);                              // '2' soft wipe
            uart_recv(8);
        join
        if (core_full.transition_mode !== 2'd2 ||
            ((rxq[rxq_n-2] >> 4) & 8'h03) !== 8'd2)
            fail_msg("T15 wipe command or ACK mode wrong");
        drain_tx_idle;
        fork
            uart_send_pair(8'h53);                              // 'S' status
            uart_recv(8);
        join
        if (((rxq[rxq_n-4] >> 5) & 8'h03) !== 8'd2)
            fail_msg("T15 status flagB effect mode wrong");
        uart_send_pair(8'h30);                                  // '0' direct cut
        repeat (100) @(posedge clk);
        if (core_full.transition_mode !== 2'd0)
            fail_msg("T15 direct-cut command wrong");
        else
            $display("T15 explicit transition modes and telemetry: PASS");
        drain_tx_idle;

        // T16: OSD mode uses the spare high bits and does not alter effect.
        if (core.osd_mode !== 2'd1) fail_msg("T16 default OSD mode wrong");
        fork
            uart_send_pair(8'h35);
            uart_recv(8);
        join
        if (core.osd_mode !== 2'd2 || rxq[rxq_n-2][7:6] !== 2'd2)
            fail_msg("T16 always-on OSD ACK wrong");
        drain_tx_idle;
        fork
            uart_send_pair(8'h33);
            uart_recv(8);
        join
        if (core.osd_mode !== 2'd0 || rxq[rxq_n-2][7:6] !== 2'd0)
            fail_msg("T16 OSD off ACK wrong");
        drain_tx_idle;
        fork
            uart_send_pair(8'h34);
            uart_recv(8);
        join
        if (core.osd_mode !== 2'd1 || rxq[rxq_n-2][7:6] !== 2'd1)
            fail_msg("T16 transient OSD ACK wrong");
        drain_tx_idle;
        fork
            uart_send_pair(8'h53);
            uart_recv(8);
        join
        if (rxq[rxq_n-3][5:4] !== 2'd1)
            fail_msg("T16 status OSD mode wrong");
        else
            $display("T16 OSD modes and telemetry: PASS");

        // T17: local touch gestures reuse the debounced 100 ms virtual key
        // route without injecting a serial/Ethernet command or ACK.
        wait (vk_next_n && vk_auto_n && vk_prev_n);
        @(negedge clk); touch_next = 1'b1;
        @(negedge clk); touch_next = 1'b0;
        repeat (2) @(posedge clk);
        if (vk_next_n !== 1'b0) fail_msg("T17 touch next did not press virtual key");
        wait (vk_next_n === 1'b1);
        @(negedge clk); touch_prev = 1'b1;
        @(negedge clk); touch_prev = 1'b0;
        repeat (2) @(posedge clk);
        if (vk_prev_n !== 1'b0) fail_msg("T17 touch previous did not press virtual key");
        wait (vk_prev_n === 1'b1);
        if (errors == 0) $display("T17 touch swipe to virtual keys: PASS");

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
