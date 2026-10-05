// tb_ethfront.v — 以太网应用层（eth_front）自检测试台
//
// 为什么只测 eth_front：以太网子系统下面三层（加密 UDP 栈、TEMAC 门级网表、
// PLL/ODDR 等厂商原语）Verilator 编不了，但**我们写的层**可以——把不可仿真的
// 边界（UDP 栈的"应用侧接口"）用本 TB 直接扮演，就能把整条应用层链路测起来。
// 方法对照：SD 卡的 stub_sd_card_top.v、串口的 tb_uart.v（对端由 TB 扮演）。
//
// 覆盖（每条都对应一个上板踩过的坑或协议不变量）：
//   T1 RX 解命令：8 字节应用头 + [CMD,~CMD] → cmd/cmd_pending
//   T2 握手：cmd_ack_t 翻转 → pending 清除
//   T3 不成对帧（[C,C]）→ 不产生命令
//   T4 pending 未清期间新命令被丢弃（防阻塞）
//   T5 命令字节当拍正确、连续两条不串（"晚一拍"回归）
//   T6 TX 整帧 16 字节 = AA BB CC DD 00 02 00 08 + pkt（pkt[0] 先发）
//   T7 TX 帧长 udp_data_length == 16、valid 拍数 == 16
//   T8 连续两帧：内容随 tx_pkt 变、字节序 LSB 先发
//   T9 应用头里的"伪装命令对"不得被解出（头 8 字节不参与解析）
//   T10 跨包拆分的命令对不得误配（包尾必须清配对状态）
//   T11 栈未就绪（udp_tx_ready=0）时等住、就绪后原样发出（不丢帧）
// 写侧分叉（第二十轮）：
//   T12 tap 灌 300 字 → 满包 seq=0、253 字、头 len=0x03F6、字 LSB 字节先发
//   T13 tap_end → 冲洗尾包 seq=1、N=47、len=0x00BE；冲洗完 seq 归零
//   T14 新会话：尾包 seq 重新从 0 起
//   T15 仲裁：ACK 与流包同时待发 → ACK 先行，且 ACK 不吃 seq
`timescale 1ns/1ps
module tb_ethfront;

    reg clk = 0;
    always #5 clk = ~clk;              // 100MHz（eth 域真实是 125M，测试无关）
    reg tap2_clk = 0;
    always #6.666 tap2_clk = ~tap2_clk; // 独立 75MHz：读回 FIFO 跨时钟
    reg rst = 1;
    reg sys_rst = 1;                   // 流通道复位（与 rst 同步释放）

    // ---- 写侧分叉 tap（tap_clk 同 clk）----
    reg         tap_val = 1'b0;
    reg  [31:0] tap_word = 32'd0;
    reg         tap_end  = 1'b0;
    // ---- 读侧 dump tap2（type 0x0004，与写侧独立 FIFO/seq）----
    reg         tap2_val = 1'b0;
    reg  [31:0] tap2_word = 32'd0;
    reg         tap2_end  = 1'b0;

    // ---- UDP 栈应用侧接口（由本 TB 扮演）----
    reg  [7:0]  rx_data  = 8'd0;
    reg         rx_valid = 1'b0;
    reg  [15:0] rx_len   = 16'd0;
    reg         tx_ready = 1'b1;       // 栈"随时可发"
    reg         tx_ack   = 1'b0;
    wire [7:0]  tx_data;
    wire        tx_request, tx_valid;
    wire [15:0] tx_len;

    // ---- 应用侧：命令握手 / 应答包 ----
    wire [7:0]  cmd;
    wire        cmd_pending;
    reg         cmd_ack_t = 1'b0;
    reg         tx_tog    = 1'b0;
    reg  [63:0] tx_pkt    = 64'd0;

    eth_front dut (
        .app_rx_clk        (clk),
        .app_tx_clk        (clk),
        .reset             (rst),
        .app_rx_data       (rx_data),
        .app_rx_data_valid (rx_valid),
        .app_rx_data_length(rx_len),
        .udp_tx_ready      (tx_ready),
        .app_tx_ack        (tx_ack),
        .app_tx_data       (tx_data),
        .app_tx_data_request(tx_request),
        .app_tx_data_valid (tx_valid),
        .udp_data_length   (tx_len),
        .cmd               (cmd),
        .cmd_pending       (cmd_pending),
        .cmd_ack_t         (cmd_ack_t),
        .tx_tog            (tx_tog),
        .tx_pkt            (tx_pkt),
        .sys_rst           (sys_rst),
        .tap_clk           (clk),
        .tap_val           (tap_val),
        .tap_word          (tap_word),
        .tap_end           (tap_end),
        .tap2_clk          (tap2_clk),
        .tap2_val          (tap2_val),
        .tap2_word         (tap2_word),
        .tap2_end          (tap2_end)
    );

    integer errors = 0;
    task fail_msg(input [255:0] m);
        begin
            errors = errors + 1;
            $display("FAIL t=%0t: %0s", $time, m);
        end
    endtask

    // ---- 发一包 UDP 载荷：8 字节应用头 + 后续字节（payload[0] 紧跟头之后）----
    // 头与 PC 侧 EthTransport 发的完全一致：AA BB CC DD 00 01 00 <len>
    task send_payload(input [7:0] b0, input [7:0] b1, input integer n);   // n = 载荷字节数
        integer i;
        begin
            rx_len = n[15:0];
            @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                rx_data  = {8'hAA, 8'hBB, 8'hCC, 8'hDD, 8'h00, 8'h01, 8'h00, n[7:0]} >> (8*(7-i));
                rx_valid = 1'b1;
                @(posedge clk);
            end
            rx_data  = b0; rx_valid = 1'b1; @(posedge clk);
            rx_data  = b1; rx_valid = 1'b1; @(posedge clk);
            rx_valid = 1'b0; rx_data = 8'd0;   // 包尾：清配对状态
            @(posedge clk);
        end
    endtask

    task send_cmd(input [7:0] c);
        begin
            send_payload(c, ~c, 2);
        end
    endtask

    // ---- 模拟顶层"取走命令"：翻转 cmd_ack_t，等同步链走完 ----
    task take_cmd;
        begin
            @(posedge clk);
            cmd_ack_t = ~cmd_ack_t;      // 顶层在 eth_take 拍翻转
            repeat (6) @(posedge clk);   // 2FF 同步 + 清除
        end
    endtask

    // ---- TX 采集：valid 期间逐拍收字节 ----
    reg [7:0] cap [0:2047];
    integer   cap_n = 0;
    reg       cap_en = 0;
    always @(posedge clk) begin
        if (cap_en && tx_valid) begin
            cap[cap_n] = tx_data;
            cap_n      = cap_n + 1;
        end
    end

    // ---- 等一次完整发送：request → ack → 收 pkt_len 字节 ----
    task tx_collect(input integer pkt_len);
        integer guard;
        begin
            cap_n = 0; cap_en = 1;
            guard = 0;
            while (!tx_request && guard < 40000) begin @(posedge clk); guard = guard + 1; end
            if (!tx_request) fail_msg("TX: request 未拉高");
            tx_ack = 1'b1;
            @(posedge clk);
            tx_ack = 1'b0;
            guard = 0;
            while (cap_n < pkt_len && guard < 40000) begin @(posedge clk); guard = guard + 1; end
            repeat (4) @(posedge clk);
            cap_en = 0;
        end
    endtask

    // ---- 灌 N 个 tap 字（字 i = {i[15:0], ~i[15:0]} 便于校验字节序）----
    task tap_feed(input integer n);
        integer j;
        begin
            for (j = 0; j < n; j = j + 1) begin
                @(posedge clk);
                tap_val  <= 1'b1;
                tap_word <= {j[15:0], ~j[15:0]};
            end
            @(posedge clk);
            tap_val <= 1'b0;
            @(posedge clk);
        end
    endtask

    // ---- tap_end 会话结束脉冲 ----
    task tap_session_end;
        begin
            @(posedge clk); tap_end <= 1'b1;
            @(posedge clk); tap_end <= 1'b0;
            @(posedge clk);
        end
    endtask

    // ---- 灌 N 个 tap2 字（读回源；字 i = {i, ~i}）----
    task tap2_feed(input integer n);
        integer j;
        begin
            for (j = 0; j < n; j = j + 1) begin
                @(negedge tap2_clk);
                tap2_val  = 1'b1;
                tap2_word = {j[15:0], ~j[15:0]};
            end
            @(negedge tap2_clk);
            tap2_val = 1'b0;
            @(posedge tap2_clk);
        end
    endtask

    task tap2_session_end;
        begin
            @(negedge tap2_clk); tap2_end = 1'b1;
            @(negedge tap2_clk); tap2_end = 1'b0;
            @(posedge tap2_clk);
        end
    endtask

    // ---- 模拟栈：接受一次发送（request → ack → 收 16 字节）----
    task tx_round(input [63:0] pkt);
        integer guard;
        begin
            tx_pkt = pkt;
            @(posedge clk);
            tx_tog = ~tx_tog;            // 顶层每应答一次翻转一次
            tx_collect(16);
        end
    endtask

    integer i, g, sample_idx, stream_errs;
    reg [31:0] exp_stream_word;
    reg [7:0] exp_hdr [0:7];
    initial begin
        exp_hdr[0]=8'hAA; exp_hdr[1]=8'hBB; exp_hdr[2]=8'hCC; exp_hdr[3]=8'hDD;
        exp_hdr[4]=8'h00; exp_hdr[5]=8'h02; exp_hdr[6]=8'h00; exp_hdr[7]=8'h08;

        repeat (10) @(posedge clk);
        rst = 0; sys_rst = 0;
        repeat (10) @(posedge clk);

        // ---- T1/T2：解命令 + 握手清除 ----
        send_cmd(8'h4E);                          // 'N'
        if (cmd !== 8'h4E)      fail_msg("T1 cmd 应为 0x4E");
        if (cmd_pending !== 1'b1) fail_msg("T1 cmd_pending 未置位");
        if (errors == 0) $display("T1 RX 解命令 [CMD,~CMD]: PASS");
        take_cmd();
        if (cmd_pending !== 1'b0) fail_msg("T2 ack 后 pending 未清除");
        if (errors == 0) $display("T2 握手（ack 翻转清 pending）: PASS");

        // ---- T3：不成对帧不产生命令 ----
        send_payload(8'h4E, 8'h4E, 2);            // [C,C]：不是 ~C
        if (cmd_pending !== 1'b0) fail_msg("T3 不成对帧产生了命令");
        if (errors == 0) $display("T3 不成对帧拒收: PASS");

        // ---- T4：pending 未清期间的命令被丢弃 ----
        send_cmd(8'h50);                          // 'P' → pending 置位、cmd=0x50
        if (cmd_pending !== 1'b1 || cmd !== 8'h50) fail_msg("T4 前置命令未生效");
        send_cmd(8'h41);                          // 'A'：pending 未清，应被丢弃
        if (cmd !== 8'h50) fail_msg("T4 pending 期间新命令竟改写了 cmd");
        take_cmd();
        if (cmd_pending !== 1'b0) fail_msg("T4 pending 未清除");
        if (errors == 0) $display("T4 pending 未清时新命令丢弃: PASS");

        // ---- T5：连续两条命令不串（"晚一拍"回归）----
        send_cmd(8'h41);                          // 'A'
        if (cmd !== 8'h41) fail_msg("T5 第一条应为 0x41");
        take_cmd();
        send_cmd(8'h4E);                          // 'N'
        if (cmd !== 8'h4E) fail_msg("T5 第二条应为 0x4E（不可是上一条）");
        if (errors == 0) $display("T5 连续命令不串（晚一拍回归）: PASS");
        take_cmd();

        // ---- T6/T7：TX 整帧 ----
        tx_round(64'h0000_0000_0000_005A);        // pkt = 只有 pkt[0]=0x5A
        if (cap_n !== 16) fail_msg("T6 帧长应为 16 字节");
        for (i = 0; i < 8; i = i + 1)
            if (cap[i] !== exp_hdr[i])
                fail_msg("T6 应用头字节错（见下）");
        if (cap[8] !== 8'h5A) fail_msg("T6 载荷首字节应为 tx_pkt[7:0]");
        if (errors == 0)
            $display("T6 TX 整帧（AA BB CC DD 00 02 00 08 + 载荷）: PASS");
        if (tx_len !== 16'd16) fail_msg("T7 udp_data_length 应为 16");
        if (errors == 0) $display("T7 udp_data_length = 16: PASS");

        // ---- T8：再发一帧，内容随 tx_pkt 变化（连续两帧）----
        tx_round(64'h8877_6655_4433_2211);
        if (cap_n !== 16) fail_msg("T8 第二帧长度错");
        if (cap[8] !== 8'h11 || cap[15] !== 8'h88)
            fail_msg("T8 第二帧载荷字节序错（应 LSB 先发）");
        if (errors == 0) $display("T8 连续两帧载荷字节序: PASS");

        // ---- T9：应用头里伪装成命令对的字节不得被解出 ----
        // 头 8 字节刻意放 [0x4E,0xB1]（= 'N' 的合法对），数据段放 'A' 对：
        // 只允许解出 0x41，绝不允许解出 0x4E（否则头会被当成命令）
        rx_len = 16'd2;
        @(posedge clk);
        begin : t9
            integer k;
            for (k = 0; k < 8; k = k + 1) begin
                rx_data = (k == 4) ? 8'h4E : (k == 5) ? 8'hB1 : 8'h00;
                rx_valid = 1'b1;
                @(posedge clk);
            end
            rx_data = 8'h41; rx_valid = 1'b1; @(posedge clk);
            rx_data = 8'hBE; rx_valid = 1'b1; @(posedge clk);
            rx_valid = 1'b0;
            @(posedge clk);
        end
        if (cmd !== 8'h41) fail_msg("T9 应用头伪装字节被解成了命令");
        else $display("T9 应用头不参与命令解析: PASS");
        take_cmd();

        // ---- T10：跨包拆分的命令对不得误配 ----
        // 包 1 尾字节放 0x4E、包 2 首字节放 0xB1：中间有包尾（valid 拉低），
        // 配对状态必须被清掉，不能拼成一条命令
        send_payload(8'h13, 8'h4E, 2);           // 末字节 = 0x4E
        send_payload(8'hB1, 8'h20, 2);           // 首字节 = 0xB1（= ~0x4E）
        if (cmd_pending !== 1'b0) fail_msg("T10 跨包拆分的命令对被误配");
        else $display("T10 跨包不误配命令对: PASS");

        // ---- T11：栈未就绪（udp_tx_ready=0）时必须等住，就绪后原样发出 ----
        tx_ready = 1'b0;
        tx_pkt   = 64'hDEAD_BEEF_0000_00C3;
        @(posedge clk);
        tx_tog = ~tx_tog;
        cap_n = 0; cap_en = 1;
        repeat (30) @(posedge clk);
        if (tx_request !== 1'b0) fail_msg("T11 栈未就绪却已拉 request");
        tx_ready = 1'b1;
        g = 0;
        while (!tx_request && g < 200) begin @(posedge clk); g = g + 1; end
        if (!tx_request) fail_msg("T11 就绪后 request 未拉高");
        tx_ack = 1'b1; @(posedge clk); tx_ack = 1'b0;
        g = 0;
        while (cap_n < 16 && g < 400) begin @(posedge clk); g = g + 1; end
        repeat (4) @(posedge clk);
        cap_en = 0;
        if (cap_n !== 16)                       fail_msg("T11 就绪恢复后帧长错");
        else if (cap[8] !== 8'hC3 || cap[15] !== 8'hDE)
                                                fail_msg("T11 就绪恢复后帧内容错");
        else $display("T11 栈未就绪时等待、就绪后原样发出: PASS");

        // ============ 写侧分叉：流包通道（第二十轮）============

        // ---- T12：tap 灌 300 字 → 满包（seq=0，255 字）----
        // 字 j = {j, ~j}：线序 LSB 先 → 字节流 = ~j[7:0] ~j[15:8] j[7:0] j[15:8]
        tap_feed(300);
        tx_collect(10 + 4*255);
        begin : dbg12
            integer d;
            $write("DBG12 cap[0..31]:");
            for (d = 0; d < 32; d = d + 1) $write(" %02x", cap[d]);
            $write("\n");
            $write("DBG12 cap[1012..1021]:");
            for (d = 1012; d < 1022; d = d + 1) $write(" %02x", cap[d]);
            $write("\n");
        end
        if (cap_n !== 10 + 4*253) fail_msg("T12 满包长度应为 1022 字节");
        if (cap[0] !== 8'hAA || cap[1] !== 8'hBB || cap[2] !== 8'hCC || cap[3] !== 8'hDD)
            fail_msg("T12 流包应用头错");
        if (cap[4] !== 8'h03 || cap[5] !== 8'h00) fail_msg("T12 流包 type 应为 0x0003");
        // 头 length 域 = 2 + 4*253 = 1014 = 0x03F6
        if (cap[6] !== 8'hF6 || cap[7] !== 8'h03) fail_msg("T12 流包头 length 域错");
        if (cap[8] !== 8'h00 || cap[9] !== 8'h00) fail_msg("T12 首包 seq 应为 0");
        // 字 0 = {0x0000,0xFFFF} → FF FF 00 00；字 1 = {0x0001,0xFFFE} → FE FF 01 00
        if (cap[10] !== 8'hFF || cap[11] !== 8'hFF || cap[12] !== 8'h00 || cap[13] !== 8'h00)
            fail_msg("T12 字 0 字节序错（应 LSB 先）");
        if (cap[14] !== 8'hFE || cap[15] !== 8'hFF || cap[16] !== 8'h01 || cap[17] !== 8'h00)
            fail_msg("T12 字 1 内容错");
        // 末字（j=252 = {0x00FC,0xFF03}）→ 03 FF FC 00
        if (cap[1018] !== 8'h03 || cap[1019] !== 8'hFF ||
            cap[1020] !== 8'hFC || cap[1021] !== 8'h00) fail_msg("T12 末字内容/序错");
        if (errors == 0) $display("T12 tap 满包 253 字（头/seq/字节序）: PASS");

        // ---- T13：tap_end → 冲洗尾包（seq=1，47 字）----
        tap_session_end();
        tx_collect(10 + 4*47);
        if (cap_n !== 10 + 4*47) fail_msg("T13 尾包长度应为 198 字节");
        // 头 length 域 = 2 + 188 = 190 = 0x00BE
        if (cap[6] !== 8'hBE || cap[7] !== 8'h00) fail_msg("T13 尾包 length 域错");
        if (cap[8] !== 8'h01 || cap[9] !== 8'h00) fail_msg("T13 尾包 seq 应为 1");
        // 末字 j=299=0x012B：线序 D4 FE 2B 01（地址 10+4*46=194 起）
        if (cap[194] !== 8'hD4 || cap[197] !== 8'h01) fail_msg("T13 尾包末字内容错");
        if (errors == 0) $display("T13 tap_end 冲洗尾包（seq=1，47 字）: PASS");

        // ---- T14：新会话尾包 seq 重新从 0 起 ----
        tap_feed(10);
        tap_session_end();
        tx_collect(10 + 4*10);
        if (cap_n !== 50) fail_msg("T14 新会话尾包长度应为 50 字节");
        if (cap[8] !== 8'h00 || cap[9] !== 8'h00) fail_msg("T14 新会话 seq 应归零");
        if (cap[6] !== 8'h2A || cap[7] !== 8'h00) fail_msg("T14 新会话尾包 length 域错（42）");
        if (errors == 0) $display("T14 新会话 seq 归零: PASS");

        // ---- T15：仲裁与记账——流包在途时 ACK 记账不丢、ACK 先行、不吃 seq ----
        // 流包攒好后栈故意未就绪（流包卡在 TX_RDY），此时到达的 ACK 必须记账，
        // 就绪后流包先发（已获总线），随后 ACK 补发，seq 不受 ACK 影响。
        tx_ready = 1'b0;
        tap_feed(300);
        tx_pkt = 64'h0000_0000_0000_00A5;
        tx_tog = ~tx_tog;                          // ACK 到达（此时流包在等就绪）
        repeat (20) @(posedge clk);
        if (tx_request !== 1'b0) fail_msg("T15 栈未就绪却已拉 request");
        tx_ready = 1'b1;
        tx_collect(10 + 4*253);                    // 流包先走
        if (cap[8] !== 8'h00 || cap[9] !== 8'h00) fail_msg("T15 流包 seq 应为 0");
        tx_collect(16);                            // 随后 ACK 补发
        if (cap_n !== 16) fail_msg("T15 ACK 帧长应为 16");
        if (cap[4] !== 8'h00 || cap[5] !== 8'h02) fail_msg("T15 ACK type 错");
        if (cap[8] !== 8'hA5) fail_msg("T15 ACK 载荷首字节错（记账丢失？）");
        tap_session_end();
        tx_collect(10 + 4*47);                     // 尾包 seq=1：ACK 未吃 seq
        if (cap[8] !== 8'h01 || cap[9] !== 8'h00) fail_msg("T15 ACK 后尾包 seq 应仍为 1");
        if (errors == 0) $display("T15 ACK/流包仲裁与记账（ACK 先行、不吃 seq）: PASS");

        // ---- T16：读回源（tap2/type 0x0004）：独立 FIFO、独立 seq、3:1 抽字 ----
        // 灌 10 字 → thin_cnt==0 保留 j=0,3,6,9 共 4 字；包 = 10 + 4*4 = 26 字节
        tap2_feed(10);
        tap2_session_end();
        tx_collect(26);
        if (cap_n !== 26) fail_msg("T16 读回尾包长度应为 26 字节（3:1 抽字后 4 字）");
        if (cap[4] !== 8'h04 || cap[5] !== 8'h00) fail_msg("T16 读回包 type 应为 0x0004");
        if (cap[8] !== 8'h00 || cap[9] !== 8'h00) fail_msg("T16 读回包 seq 应为 0");
        if (cap[6] !== 8'h12 || cap[7] !== 8'h00) fail_msg("T16 读回尾包 length 域错（18）");
        if (cap[10] !== 8'hFF || cap[13] !== 8'h00) fail_msg("T16 读回字 0（j=0）内容错");
        // 第 2 个保留字 = 灌入的 j=3 = {0x0003,0xFFFC} → 线序 FC FF 03 00
        if (cap[14] !== 8'hFC || cap[17] !== 8'h00) fail_msg("T16 读回字 1（j=3，抽字位置错？）");
        if (errors == 0) $display("T16 读回源 type 0x0004（独立 FIFO/seq/3:1 抽字）: PASS");

        // ---- T17：读回会话之后写侧 seq 仍归零且 type 回 0x0003 ----
        tap_feed(10);
        tap_session_end();
        tx_collect(50);
        if (cap[4] !== 8'h03) fail_msg("T17 写侧包 type 应回 0x0003");
        if (cap[8] !== 8'h00 || cap[9] !== 8'h00) fail_msg("T17 写侧 seq 应归零");
        if (errors == 0) $display("T17 写侧/读回会话互不串扰: PASS");

        // ---- T18：读回跨两个满包后冲洗尾包，序号必须取 seq2 而非写侧 seq ----
        // 1520 个原始字抽成 507 字 = 253 + 253 + 1。
        tap2_feed(1520);
        stream_errs = 0;
        tx_collect(10 + 4*253);
        if (cap_n !== 10 + 4*253 || cap[4] !== 8'h04 ||
            cap[8] !== 8'h00 || cap[9] !== 8'h00)
            fail_msg("T18 读回首满包 type/seq/长度错误");
        for (i = 0; i < 253; i = i + 1) begin
            sample_idx = 3*i;
            exp_stream_word = {sample_idx[15:0], ~sample_idx[15:0]};
            if ({cap[13+4*i], cap[12+4*i], cap[11+4*i], cap[10+4*i]} !== exp_stream_word)
                stream_errs = stream_errs + 1;
        end
        tx_collect(10 + 4*253);
        if (cap_n !== 10 + 4*253 || cap[4] !== 8'h04 ||
            cap[8] !== 8'h01 || cap[9] !== 8'h00)
            fail_msg("T18 读回第二满包 seq 应为 1");
        for (i = 0; i < 253; i = i + 1) begin
            sample_idx = 3*(253+i);
            exp_stream_word = {sample_idx[15:0], ~sample_idx[15:0]};
            if ({cap[13+4*i], cap[12+4*i], cap[11+4*i], cap[10+4*i]} !== exp_stream_word)
                stream_errs = stream_errs + 1;
        end
        if (stream_errs != 0) fail_msg("T18 读回满包内字序或数据错误");
        tap2_session_end();
        tx_collect(14);
        if (cap_n !== 14 || cap[4] !== 8'h04 ||
            cap[8] !== 8'h02 || cap[9] !== 8'h00 ||
            cap[10] !== 8'h11 || cap[11] !== 8'hFA ||
            cap[12] !== 8'hEE || cap[13] !== 8'h05)
            fail_msg("T18 读回尾包 seq=2 / 抽样末字 j=1518 错误");
        if (errors == 0) $display("T18 读回多包独立序号与尾包: PASS");

        // ---- T19：读回新会话的抽样相位和序号一起归零 ----
        tap2_feed(10);
        tap2_session_end();
        tx_collect(26);
        if (cap_n !== 26 || cap[8] !== 8'h00 || cap[9] !== 8'h00 ||
            cap[10] !== 8'hFF || cap[13] !== 8'h00)
            fail_msg("T19 读回新会话相位/序号未归零");
        if (errors == 0) $display("T19 读回会话复位: PASS");

        // ---- T20：写口诊断模式同时使用 A 数据流与 B 抽样地址流 ----
        // 两源分别灌 300/900 字，B 3:1 后也为 300 字；A/B 各满包+47 字尾包。
        fork
            begin tap_feed(300); tap_session_end(); end
            begin tap2_feed(900); tap2_session_end(); end
        join
        tx_collect(10 + 4*253);
        if (cap[4] !== 8'h03 || cap[8] !== 8'h00) fail_msg("T20 A 首包 type/seq 错");
        tx_collect(10 + 4*47);
        if (cap[4] !== 8'h03 || cap[8] !== 8'h01) fail_msg("T20 A 尾包 type/seq 错");
        tx_collect(10 + 4*253);
        if (cap[4] !== 8'h04 || cap[8] !== 8'h00 ||
            cap[10] !== 8'hFF || cap[13] !== 8'h00)
            fail_msg("T20 B 首包 type/seq/首字错");
        tx_collect(10 + 4*47);
        if (cap[4] !== 8'h04 || cap[8] !== 8'h01)
            fail_msg("T20 B 尾包 type/seq 错");
        if (errors == 0) $display("T20 双写口诊断流并发与独立收口: PASS");

        if (errors == 0) $display("==== ALL PASS ====");
        else             $display("==== %0d FAILED ====", errors);
        $finish;
    end

    // 超时兜底
    initial begin
        #2_000_000;
        $display("FAIL: 仿真超时");
        $finish;
    end

endmodule
