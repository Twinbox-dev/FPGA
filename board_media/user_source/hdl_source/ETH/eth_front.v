`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// eth_front.v — 以太网控制前端（传输层=官方 udp_ip_protocol_stack，见
//               udp_transmit_test demo / APUG013）。与 uart_link 同级：
//               只把 UDP 载荷翻译成「命令字节 + valid」喂 ctrl_core；
//               ctrl_core 的 tx_req/tx_pkt 应答包由本模块打成 UDP 发回 PC。
//
// 应用层帧格式（APUG013，UDP payload = 8 字节应用头 + 数据）：
//   [header0=0xAABB][header1=0xCCDD][type][length] + 数据
//   PC→板 命令帧：type=0x0001, length=0x0002, 数据=[CMD,~CMD]（与串口同款）
//   命令转发帧：本工程令 TX_TYPE=0x0001，length=0x0008，首两字节
//               [CMD,~CMD]；默认 type=0x0002 仍可用于 PC 应答。
//                （5A|cmd回显|vol|period|img|wav|bri|00 或 A5 状态包）
//   板→PC 流包  ：type=0x0003, length=2+4N（写侧分叉，第二十轮）：
//                seq[15:0]（LSB 先，每会话从 0 起）+ N×32bit 发射字
//                （LSB 字节先；字低 16bit=左像素 RGB565，高 16bit=右像素）。
//                UDP payload = 8 + 2 + 4N（N=253 满包，会话尾短包；253 上限
//                来自攒包 BRAM 深度 1024 = TD 推断上限）。
//                tap 数据路径：tap_clk(sd_card_clk) 域 Gray 异步 FIFO →
//                udp_clk 域攒包 BRAM → 与 ACK 包共用 TX FSM（ACK 优先）。
//
// 时钟：udp_clk（千兆 125M / 百兆 12.5M，由 udp_clk_gen 按 tri_speed 选）。
// 复位：reset 高有效（接 eth 子系统复位，上电锁存一次）。流通道另用 sys_rst
//（rst_all）同步到两域——eth 的 reset 按键复位不覆盖，Gray FIFO 两侧必须随
// 系统复位一起清零，否则指针错位。
//
// 注意：demo 的 udp_loopback 依赖 TD 库宏 ram_fifo（工程里无源码），本模块
// 自带解析/组包逻辑，不依赖 ram_fifo。
// ---------------------------------------------------------------------------
module eth_front #(
    parameter [15:0] TX_TYPE = 16'h0002
)(
    input  wire        app_rx_clk,
    input  wire        app_tx_clk,
    input  wire        reset,
    input  wire        sys_rst,        // rst_all：流通道复位（两域各自同步）

    // UDP 栈 RX：payload 字节流（含 8 字节应用头）
    input  wire [7:0]  app_rx_data,
    input  wire        app_rx_data_valid,
    input  wire [15:0] app_rx_data_length,

    // UDP 栈 TX
    input  wire        udp_tx_ready,
    input  wire        app_tx_ack,
    output wire [7:0]  app_tx_data,
    output reg         app_tx_data_request,
    output wire        app_tx_data_valid,
    output reg  [15:0] udp_data_length,

    // 应用出口：命令握手（跨时钟域，udp_clk ↔ sd_card_clk 由顶层完成）——
    // 命中命令置 cmd_pending 并锁存 cmd（保持稳定）；顶层取走后翻转 cmd_ack_t
    // 清除 pending。pending 未清期间新命令被丢弃（人手速度不可能）。
    output reg  [7:0]  cmd,
    output reg         cmd_pending,
    input  wire        cmd_ack_t,
    // 应用入口：ctrl_core 应答包（顶层每应答一次翻转 tx_tog；tx_pkt 在翻转
    // 前后稳定）
    input  wire        tx_tog,
    input  wire [63:0] tx_pkt,

    // 应用入口（写侧分叉）：图像发射流旁路（tap_clk = sd_card_clk 域）
    input  wire        tap_clk,
    input  wire        tap_val,
    input  wire [31:0] tap_word,
    input  wire        tap_end,         // 写会话结束脉冲（离开 LD_STREAM）
    // 应用入口（读侧 dump，第二十一轮）：显示读数据捕获流（video_clk 域源）
    input  wire        tap2_clk,        // 捕获源时钟 = video_clk
    input  wire        tap2_val,
    input  wire [31:0] tap2_word,
    input  wire        tap2_end         // 捕获会话结束脉冲
);
    localparam HDR0   = 16'hAABB;        // 应用头（APUG013 demo 同款）
    localparam HDR1   = 16'hCCDD;
    localparam TYPE_ACK = TX_TYPE;       // media command relay uses type 0x0001
    localparam [15:0] PKT_BYTES = 16'd16; // 应答帧数据长度 = 8 头 + 8 包

    // ================= RX：跳过 8 字节头 → [CMD,~CMD] 配对 =================
    reg [15:0] rx_cnt;
    reg [15:0] rx_type;
    reg [7:0]  prev_byte;
    reg        prev_val;

    always @(posedge app_rx_clk or posedge reset) begin
        if (reset) begin
            rx_cnt <= 16'd0; rx_type <= 16'd0;
            prev_byte <= 8'd0; prev_val <= 1'b0;
            cmd <= 8'd0; cmd_pending <= 1'b0;
        end else begin
            if (app_rx_data_valid) begin
                rx_cnt <= rx_cnt + 16'd1;
                if (rx_cnt == 16'd4) rx_type[15:8] <= app_rx_data;
                if (rx_cnt == 16'd5) rx_type[7:0]  <= app_rx_data;
                // 前 8 字节为应用头，其后才是命令数据
                // 数据块可能恰好含有 [CMD,~CMD]，只解析 type=1 控制帧。
                if (rx_cnt >= 16'd8 && rx_type == 16'h0001) begin
                    if (prev_val && (prev_byte == ~app_rx_data)) begin
                        prev_val <= 1'b0;
                        if (!cmd_pending) begin   // 上条未取走则丢弃（防阻塞）
                            cmd        <= prev_byte;
                            cmd_pending <= 1'b1;
                        end
                    end else begin
                        prev_byte <= app_rx_data;
                        prev_val  <= 1'b1;
                    end
                end else if (rx_cnt >= 16'd8)
                    prev_val <= 1'b0;
            end else begin
                rx_cnt   <= 16'd0;       // 包尾：清配对状态，防跨包误配
                rx_type  <= 16'd0;
                prev_val <= 1'b0;
            end
            if (ack_seen)
                cmd_pending <= 1'b0;     // 顶层已取走命令
        end
    end

    // ---- 命令握手：cmd_ack_t toggle 同步（取走确认）----
    reg ack_s0, ack_s1, ack_loc;
    always @(posedge app_rx_clk or posedge reset) begin
        if (reset) begin
            ack_s0 <= 1'b0; ack_s1 <= 1'b0; ack_loc <= 1'b0;
        end else begin
            ack_s0  <= cmd_ack_t;
            ack_s1  <= ack_s0;
            ack_loc <= ack_s1;
        end
    end
    wire ack_seen = (ack_s1 != ack_loc);

    // ---- 应答包入口：tx_tog toggle 同步（新包到达）----
    reg tog_s0, tog_s1, tog_loc;
    always @(posedge app_tx_clk or posedge reset) begin
        if (reset) begin
            tog_s0 <= 1'b0; tog_s1 <= 1'b0; tog_loc <= 1'b0;
        end else begin
            tog_s0  <= tx_tog;
            tog_s1  <= tog_s0;
            tog_loc <= tog_s1;
        end
    end
    wire tx_pulse = (tog_s1 != tog_loc);

    // ================= 写侧分叉：sys_rst 两域同步 + Gray 异步 FIFO ==========
    reg tap_rst_s0, tap_rst_s1;          // tap_clk 域
    always @(posedge tap_clk or posedge sys_rst) begin
        if (sys_rst) begin
            tap_rst_s0 <= 1'b1; tap_rst_s1 <= 1'b1;
        end else begin
            tap_rst_s0 <= 1'b0; tap_rst_s1 <= tap_rst_s0;
        end
    end
    reg urst_s0, urst_s1;                // udp_clk 域
    always @(posedge app_tx_clk or posedge sys_rst) begin
        if (sys_rst) begin
            urst_s0 <= 1'b1; urst_s1 <= 1'b1;
        end else begin
            urst_s0 <= 1'b0; urst_s1 <= urst_s0;
        end
    end
    wire udp_rst = urst_s1;
    reg vrst_s0, vrst_s1;                // tap2_clk（video_clk）域
    always @(posedge tap2_clk or posedge sys_rst) begin
        if (sys_rst) begin
            vrst_s0 <= 1'b1; vrst_s1 <= 1'b1;
        end else begin
            vrst_s0 <= 1'b0; vrst_s1 <= vrst_s0;
        end
    end

    // 会话结束：tap_clk 脉冲 → toggle → udp_clk 边沿（写侧/读回各一路）
    reg end_tog, end2_tog;
    always @(posedge tap_clk) begin
        if (tap_rst_s1)    end_tog <= 1'b0;
        else if (tap_end)  end_tog <= ~end_tog;
    end
    always @(posedge tap2_clk) begin
        if (vrst_s1)       end2_tog <= 1'b0;
        else if (tap2_end) end2_tog <= ~end2_tog;
    end
    reg end_s0, end_s1, end_loc, end2_s0, end2_s1, end2_loc;
    always @(posedge app_tx_clk or posedge reset) begin
        if (reset) begin
            end_s0 <= 1'b0; end_s1 <= 1'b0; end_loc <= 1'b0;
            end2_s0 <= 1'b0; end2_s1 <= 1'b0; end2_loc <= 1'b0;
        end else begin
            end_s0  <= end_tog;  end_s1  <= end_s0;  end_loc  <= end_s1;
            end2_s0 <= end2_tog; end2_s1 <= end2_s0; end2_loc <= end2_s1;
        end
    end
    wire end_pulse  = (end_s1  != end_loc);    // 写侧会话结束
    wire end2_pulse = (end2_s1 != end2_loc);   // 读回会话结束

    // 两条独立流 FIFO：A(type 0x0003)/B(type 0x0004)。写口诊断时两源
    // 可同时输入，共用 TX FSM（A 优先）；各自 seq 独立归零，PC 按 type 重组。
    wire        fifo_rd_en, fifo2_rd_en, fifo_rd_empty, fifo2_rd_empty;
    wire        fifo_full, fifo2_full;
    wire [31:0] fifo_rd_data, fifo2_rd_data;
    wire [9:0]  fifo_avail, fifo2_avail;     // 读侧可见字数（滞后 2 拍，悲观）
    tap_afifo #(.AW(9), .DW(32)) u_tap_afifo (
        .wr_clk   (tap_clk),
        .wr_rst   (tap_rst_s1),
        .wr_en    (tap_val && !fifo_full),  // 满则丢字：纯旁路观察不反压主路
        .wr_data  (tap_word),
        .wr_full  (fifo_full),
        .rd_clk   (app_tx_clk),
        .rd_rst   (udp_rst),
        .rd_en    (fifo_rd_en),
        .rd_data  (fifo_rd_data),
        .rd_empty (fifo_rd_empty),
        .rd_avail (fifo_avail)
    );
    // 读回通道 3:1 抽字：显示读满帧 27.6M 字/s 的原速突发会以 94MB/s 砸向 PC，
    // 而 Windows UDP 内核接收缓冲有 64KB 硬上限（SO_RCVBUF 钳制）必丢。抽走 1/3
    // 后 9.2M 字/s ≈ 31MB/s，Python 稳接；位置确定——收到的第 j 字 = 显存第 3j 字。
    reg [1:0] thin_cnt;
    always @(posedge tap2_clk) begin
        if (vrst_s1 || tap2_end) thin_cnt <= 2'd0;
        else if (tap2_val) thin_cnt <= (thin_cnt == 2'd2) ? 2'd0 : thin_cnt + 2'd1;
    end
    wire tap2_take = (thin_cnt == 2'd0);
    tap_afifo #(.AW(9), .DW(32)) u_tap2_afifo (
        .wr_clk   (tap2_clk),
        .wr_rst   (vrst_s1),
        .wr_en    (tap2_val && tap2_take && !fifo2_full),
        .wr_data  (tap2_word),
        .wr_full  (fifo2_full),
        .rd_clk   (app_tx_clk),
        .rd_rst   (udp_rst),
        .rd_en    (fifo2_rd_en),
        .rd_data  (fifo2_rd_data),
        .rd_empty (fifo2_rd_empty),
        .rd_avail (fifo2_avail)
    );

    // ================= TX：ACK 包 / 流包共用一条 FSM =================
    // 时序照抄 demo udp_loopback：request 拉高 → 等 app_tx_ack → 逐拍
    // valid+data（udp_data_length 保持）→ 发完回 WAIT。仲裁：ACK 优先
    //（人控路径延迟小），流包攒满/冲洗时补位。
    localparam TX_WAIT = 3'd0, TX_RDY  = 3'd1, TX_ACK  = 3'd2, TX_SEND = 3'd4,
               S_BUILD = 3'd3;
    reg [2:0]  st;
    reg        tx_sel;                   // 0=ACK 包（tx_buf）1=流包（str_mem）
    reg        ack_pend;                 // tx_pulse 到达但总线忙 → 记账
    // 16 字节整帧：字节 0..7 = 应用头，字节 8..15 = tx_pkt（pkt[0] 先发）。
    // ⚠ 曾写成 64 位（只锁 tx_pkt、按 16 字节索引）→ **应用头根本没发出去**，
    //   且 tx_i≥8 读越界位（=0）；PC 侧能看到 ACK 只是走了"没有头"的兜底分支。
    //   头常量按"字节 0 在最低位"写：0xAA BB CC DD 00 02 00 08 → 08_00_02_00_DD_CC_BB_AA
    reg [127:0] tx_buf;
    reg [10:0] tx_i;                     // 当前输出字节序号（流包最大 1029）
    reg        valid_r;                  // ACK 路径 valid
    reg        out_valid;                // 流包路径 valid（str_q 打一拍配套）
    // ---- 流包攒包区：1022 字节 = 8 头 + 2 seq + 253×4 字 ----
    // ⚠ TD BRAM 推断三要素缺一不可（force_ram pragma / 无复位独立 always /
    //   深度 ≤1024）：首版把存储写进带复位的 FSM 大 always 且深度 1030 →
    //   推断失败落成 8240 个 FF + 千位读 mux，mslice 6870 超限综合报错。
    //   深度 1024 封顶 → 满包字数 = (1024-10)/4 = 253。
    localparam [8:0] STR_PKT_WORDS = 9'd253;
    reg [7:0]  str_mem [0:1023]; /* fehdl force_ram=1, ram_style="bram" */
    reg [7:0]  str_q;
    reg [10:0] bi;                       // 攒包字节计数
    reg [8:0]  pkt_words;                // 本包字数 N（≤255）
    reg [31:0] word_hold;
    reg        flush_pend, flush2_pend;  // 会话结束待冲洗（写侧/读回）
    reg        str_sel;                  // 本包来源：0=写侧 FIFO 1=读回 FIFO
    reg [4:0]  settle_cnt;               // 等 Gray 写指针跨域同步沉降
    reg [15:0] seq, seq2;                // 每源独立计数（各自会话内递增、收口归零）

    wire [15:0] pkt_len_w = {5'd0, pkt_words, 2'b00} + 16'd10;   // 10+4N
    wire [15:0] plen_w    = pkt_len_w - 16'd8;                   // 应用头 length 域
    wire [10:0] bi_pop_end  = {2'b00, pkt_words, 2'b00} + 11'd5;  // 末字弹出拍 4N+5
    wire [10:0] bi_latch_end= {2'b00, pkt_words, 2'b00} + 11'd6;  // 末字锁存拍 4N+6
    wire [10:0] bi_build_end= {2'b00, pkt_words, 2'b00} + 11'd10; // 末字节写拍 4N+10
    wire        settle_done = (settle_cnt == 5'd31);
    wire        goA = (fifo_avail  >= {7'd0, STR_PKT_WORDS}) ||
                      (flush_pend  && settle_done && (fifo_avail  != 10'd0));
    wire        goB = (fifo2_avail >= {7'd0, STR_PKT_WORDS}) ||
                      (flush2_pend && settle_done && (fifo2_avail != 10'd0));
    wire        str_go = goA || goB;

    // 攒包读口：bi≡1 (mod 4) 拍弹字（1 拍延迟后 bi≡2 拍进 word_hold，
    // 写 BRAM 落后一拍——时间线见 S_BUILD 注释）。弹哪条 FIFO 由 str_sel 定。
    assign fifo_rd_en  = (st == S_BUILD) && !str_sel && (bi >= 11'd9) &&
                         (bi <= bi_pop_end) && (bi[1:0] == 2'b01);
    assign fifo2_rd_en = (st == S_BUILD) &&  str_sel && (bi >= 11'd9) &&
                         (bi <= bi_pop_end) && (bi[1:0] == 2'b01);
    wire [10:0] boff = bi - 11'd11;      // 当前写地址 = bi-1 的字内偏移 = bi-11
    wire [7:0]  wb_byte = word_hold[{boff[1:0], 3'b000} +: 8];

    // ---- str_mem 写/读口（无复位独立 always，BRAM 推断要素之二）----
    // bi 0..9 直写头+seq（地址=bi）；bi 11..4N+10 写字数据（地址=bi-1）；bi=10 空拍
    wire        str_we = (st == S_BUILD) && ((bi <= 11'd9) ||
                         ((bi >= 11'd11) && (bi <= bi_build_end)));
    wire [9:0]  str_wa = (bi <= 11'd9) ? bi[9:0] : (bi[9:0] - 10'd1);
    wire [15:0] pkt_seq = str_sel ? seq2 : seq;
    wire [7:0]  str_wd = (bi <= 11'd9)
                         ? ((bi < 11'd8) ? hdr_b
                           : (bi == 11'd8) ? pkt_seq[7:0] : pkt_seq[15:8])
                         : wb_byte;
    // 读口：TX_ACK 应答拍预取首字节；SEND 期预取下一字节（末拍不读）
    wire        str_rd = tx_sel && ((st == TX_ACK && app_tx_ack) ||
                         (st == TX_SEND && (tx_i < pkt_len_w - 16'd1)));
    wire [9:0]  str_ra = (st == TX_ACK) ? 10'd0 : (tx_i[9:0] + 10'd1);

    always @(posedge app_tx_clk)
        if (str_we) str_mem[str_wa] <= str_wd;
    always @(posedge app_tx_clk)
        if (str_rd) str_q <= str_mem[str_ra];

    // 应用头常量（流包，字节 0..7）：AA BB CC DD 03 00 len_lo len_hi
    reg [7:0] hdr_b;
    always @* begin
        case (bi[3:0])
            4'd0: hdr_b = 8'hAA;
            4'd1: hdr_b = 8'hBB;
            4'd2: hdr_b = 8'hCC;
            4'd3: hdr_b = 8'hDD;
            4'd4: hdr_b = str_sel ? 8'h04 : 8'h03;  // type LSB：03=写侧 04=读回
            4'd5: hdr_b = 8'h00;
            4'd6: hdr_b = plen_w[7:0];
            4'd7: hdr_b = plen_w[15:8];
            default: hdr_b = 8'h00;
        endcase
    end

    // 应用头常量：字节序 AA BB CC DD 00 02 00 08（**低字节先发**，所以按字节
    // 从低到高拼：byte0=AA … byte7=08）。用 HDR0/HDR1/TYPE_ACK 拼装避免手写常数出错。
    localparam [63:0] TX_HDR = {8'h08, 8'h00,                    // length = 0x0008
                                TYPE_ACK[7:0], TYPE_ACK[15:8],   // type   = 0x0002
                                HDR1[7:0], HDR1[15:8],           // CC DD
                                HDR0[7:0], HDR0[15:8]};          // AA BB

    always @(posedge app_tx_clk or posedge reset) begin
        if (reset || udp_rst) begin
            st <= TX_WAIT; app_tx_data_request <= 1'b0;
            valid_r <= 1'b0; out_valid <= 1'b0;
            udp_data_length <= 16'd0;
            tx_i <= 11'd0; tx_buf <= 128'd0;
            tx_sel <= 1'b0; ack_pend <= 1'b0;
            bi <= 11'd0; pkt_words <= 9'd0;
            word_hold <= 32'd0;
            flush_pend <= 1'b0; flush2_pend <= 1'b0;
            str_sel <= 1'b0; settle_cnt <= 5'd0;
            seq <= 16'd0; seq2 <= 16'd0;
        end else begin
            // ---- 会话结束冲洗：end_pulse 记账 → 等 Gray 写指针沉降 → 攒尾包 ----
            // 写侧/读回两路独立记账；settle 计数共用（会话互斥，不会同时结束）
            if (end_pulse || end2_pulse)
                settle_cnt <= 5'd0;
            else if ((flush_pend || flush2_pend) && !settle_done)
                settle_cnt <= settle_cnt + 5'd1;
            if (end_pulse)  flush_pend  <= 1'b1;
            if (end2_pulse) flush2_pend <= 1'b1;
            // 冲洗排空（读侧 avail==0 且无包在攒）→ 该源会话收口：对应 seq 归零
            if (flush_pend && settle_done && (st == TX_WAIT) &&
                (fifo_avail == 10'd0)) begin
                flush_pend <= 1'b0;
                seq        <= 16'd0;
            end
            if (flush2_pend && settle_done && (st == TX_WAIT) &&
                (fifo2_avail == 10'd0)) begin
                flush2_pend <= 1'b0;
                seq2        <= 16'd0;
            end

            // 总线空闲期到达的 tx_pulse 记账（正在发包时不丢）
            if (tx_pulse && (st != TX_WAIT))
                ack_pend <= 1'b1;

            case (st)
                TX_WAIT: begin
                    if (ack_pend || tx_pulse) begin
                        // 两笔待发：发一笔、留一笔（ack_pend 保持）
                        ack_pend <= tx_pulse & ack_pend;
                        // 锁存整帧（toggle 到达时 tx_pkt 已稳定）
                        tx_buf <= {tx_pkt, TX_HDR};
                        tx_sel <= 1'b0;
                        tx_i   <= 11'd0;
                        if (udp_tx_ready) begin
                            app_tx_data_request <= 1'b1;
                            st <= TX_ACK;
                        end else
                            st <= TX_RDY;
                    end
                    else if (str_go) begin
                        str_sel   <= goB && !goA;    // 源选择（A 优先）
                        pkt_words <= (goB && !goA)
                                     ? ((fifo2_avail >= {7'd0, STR_PKT_WORDS})
                                        ? STR_PKT_WORDS : fifo2_avail[8:0])
                                     : ((fifo_avail >= {7'd0, STR_PKT_WORDS})
                                        ? STR_PKT_WORDS : fifo_avail[8:0]);
                        tx_sel <= 1'b1;
                        bi     <= 11'd0;
                        st <= S_BUILD;
                    end
                end
                TX_RDY:                      // 等协议栈就绪
                    if (udp_tx_ready) begin
                        app_tx_data_request <= 1'b1;
                        st <= TX_ACK;
                    end
                TX_ACK:
                    if (app_tx_ack) begin
                        app_tx_data_request <= 1'b0;
                        udp_data_length     <= tx_sel ? pkt_len_w : PKT_BYTES;
                        tx_i <= 11'd0;
                        if (tx_sel)
                            out_valid <= 1'b1;    // 首字节由 str_rd 口预取
                        else
                            valid_r <= 1'b1;      // 首字节本拍起有效
                        st <= TX_SEND;
                    end else
                        app_tx_data_request <= 1'b1;
                TX_SEND:
                    if (tx_sel) begin
                        // 线序字节 k = str_mem[k]（str_q 前拍预取，str_rd 口负责）
                        if (tx_i == pkt_len_w - 16'd1) begin
                            out_valid <= 1'b0;
                            tx_i <= 11'd0;
                            // 每流包 +1（PC 缺口检测），按源独立计数
                            if (str_sel) seq2 <= seq2 + 16'd1;
                            else         seq  <= seq  + 16'd1;
                            st <= TX_WAIT;
                        end else
                            tx_i <= tx_i + 11'd1;
                    end
                    else begin
                        if (tx_i == PKT_BYTES - 1) begin
                            valid_r <= 1'b0; // 末字节（tx_i=15）已输出
                            // 只清"已发出那笔"的记账；本拍恰好又有新 pulse 则保留
                            if (!tx_pulse)
                                ack_pend <= 1'b0;
                            tx_i <= 11'd0;
                            st <= TX_WAIT;
                        end else begin
                            tx_i <= tx_i + 11'd1;
                        end
                    end
                // 攒包：字节落 BRAM 由独立 str_we 口完成（bi 0..9 头+seq、
                // bi≥11 写字数据滞后一拍）。弹字 bi≡1(mod4)、锁存 bi≡2、
                // 末写拍 4N+10（地址 4N+9）。
                S_BUILD: begin
                    if ((bi[1:0] == 2'b10) && (bi >= 11'd10) && (bi <= bi_latch_end))
                        word_hold <= str_sel ? fifo2_rd_data : fifo_rd_data;
                    if (bi >= bi_build_end) begin
                        if (udp_tx_ready) begin
                            app_tx_data_request <= 1'b1;
                            st <= TX_ACK;
                        end else
                            st <= TX_RDY;
                    end else
                        bi <= bi + 11'd1;
                end
                default: st <= TX_WAIT;
            endcase
        end
    end
    assign app_tx_data       = tx_sel ? str_q : tx_buf[8*tx_i[3:0] +: 8];
    assign app_tx_data_valid = tx_sel ? out_valid : valid_r;

endmodule

// ---------------------------------------------------------------------------
// tap_afifo — 写侧分叉 Gray 异步 FIFO（512×32，tap_clk → udp_clk）。
// Cummings 经典结构：格雷码指针 2 级同步跨域；读侧寄存读出（rd_en 次拍出数）；
// rd_avail = 同步回来的写指针 − 读指针（寄存输出，滞后 2 拍且悲观——只用作
// 攒包触发阈值与冲洗判空，冲洗前有 32 拍沉降窗，不受滞后影响）。
// ---------------------------------------------------------------------------
module tap_afifo #(
    parameter AW = 9,                    // 2^AW = 512 深
    parameter DW = 32
)(
    input  wire          wr_clk,
    input  wire          wr_rst,        // 各域已同步化的高有效复位
    input  wire          wr_en,
    input  wire [DW-1:0] wr_data,
    output reg           wr_full,       // 寄存输出（悲观一拍）
    input  wire          rd_clk,
    input  wire          rd_rst,
    input  wire          rd_en,
    output reg  [DW-1:0] rd_data,       // rd_en 次拍有效
    output reg           rd_empty,      // 寄存输出（悲观一拍）
    output reg  [AW:0]   rd_avail
);
    reg [AW:0] wbin, wgray;
    reg [AW:0] rbin, rgray;
    reg [AW:0] rgray_w1, rgray_w2;       // 读指针 → 写域
    reg [AW:0] wgray_r1, wgray_r2;       // 写指针 → 读域
    reg [DW-1:0] mem [0:(1<<AW)-1]; /* fehdl force_ram=1, ram_style="bram" */

    // ⚠ full/empty 必须**寄存**：组合式 `next == 对侧同步指针` 判据与指针推进
    //   互为组合环（"恰好剩一个字且使能有效"时振荡——Verilator 直接拒绝收敛）。
    //   寄存化后只可能悲观（多丢一个写/少弹一个读），不可能越过指针。
    wire        push_go     = wr_en && !wr_full;
    wire [AW:0] wbin_next   = wbin + {{AW{1'b0}}, push_go};
    wire [AW:0] wgray_next  = (wbin_next >> 1) ^ wbin_next;
    wire        wr_full_next = (wgray_next == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});

    // 存储阵列读写独立无复位 always（BRAM 推断要素之二；寄存器本体 full/empty
    // /指针的复位在下方各自 always 内，互不混写）
    always @(posedge wr_clk)
        if (push_go) mem[wbin[AW-1:0]] <= wr_data;
    always @(posedge rd_clk)
        if (pop_go) rd_data <= mem[rbin[AW-1:0]];   // 弹的是当前队头（rbin 非 rbin_next）

    always @(posedge wr_clk) begin
        if (wr_rst) begin
            wbin <= {(AW+1){1'b0}}; wgray <= {(AW+1){1'b0}};
            wr_full <= 1'b1;             // 复位期视为满：不许写
            rgray_w1 <= {(AW+1){1'b0}}; rgray_w2 <= {(AW+1){1'b0}};
        end else begin
            wbin <= wbin_next; wgray <= wgray_next;
            wr_full <= wr_full_next;
            rgray_w1 <= rgray; rgray_w2 <= rgray_w1;
        end
    end

    wire        pop_go      = rd_en && !rd_empty;
    wire [AW:0] rbin_next   = rbin + {{AW{1'b0}}, pop_go};
    wire [AW:0] rgray_next  = (rbin_next >> 1) ^ rbin_next;
    wire        rd_empty_next = (rgray_next == wgray_r2);

    // 同步回来的写指针 gray → binary
    reg [AW:0] wbin_rd;
    integer i;
    always @* begin
        wbin_rd[AW] = wgray_r2[AW];
        for (i = AW-1; i >= 0; i = i - 1)
            wbin_rd[i] = wbin_rd[i+1] ^ wgray_r2[i];
    end

    always @(posedge rd_clk) begin
        if (rd_rst) begin
            rbin <= {(AW+1){1'b0}}; rgray <= {(AW+1){1'b0}};
            rd_empty <= 1'b1;            // 复位期视为空：不许读
            wgray_r1 <= {(AW+1){1'b0}}; wgray_r2 <= {(AW+1){1'b0}};
            rd_avail <= {(AW+1){1'b0}};
        end else begin
            rbin <= rbin_next; rgray <= rgray_next;
            rd_empty <= rd_empty_next;
            wgray_r1 <= wgray; wgray_r2 <= wgray_r1;
            rd_avail <= wbin_rd - rbin;
        end
    end
endmodule
