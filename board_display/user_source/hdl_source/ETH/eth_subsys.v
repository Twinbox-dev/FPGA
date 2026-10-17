`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// eth_subsys.v — 以太网子系统（移植自官方 32_Ethernet_test UDP demo）
//
// 组成（与 demo udp_transmit_test.v 对应）：
//   clk_gen_rst_gen(125/12.5/25M + PLL lock 复位) → udp_clk_gen(按速率选
//   udp_clk，百兆=12.5M) → udp_ip_protocol_stack(UDP/IP/ARP，官方 IP) ↔
//   tx/rx_client_fifo ↔ temac_block(TEMAC_CORE + RGMII) → eth_front(应用层)
//
// 应用接口（跨时钟域握手，udp_clk 12.5M 域 ↔ sd_card_clk 域由顶层完成）：
//   cmd/cmd_pending/cmd_ack_t：命令握手（pending 置位后 cmd 稳定，直到顶层
//   翻转 cmd_ack_t 表示已取走）
//   tx_tog/tx_pkt：应答包入口（顶层每收到一条 ctrl_core 应答翻转一次 tx_tog，
//   tx_pkt 在翻转前后稳定，本模块同步检测变化后锁存发送）
//
// 网络配置：本地 IP 192.168.137.2 / MAC 01:23:45:67:89:ab / UDP 端口 1
// （PC 侧为 192.168.137.1（笔记本静态/ICS 默认），发往板卡端口 1，监听端口 2——
//   demo 的 DST_UDP_PORT_NUM=2 本模块未实现 PC 端口动态化，回包统一发
//   192.168.137.1:2。板卡 IP 取同网段 .2，子网掩码 255.255.255.0）
// 速率：TRI_SPEED 一处切换（2'b01=百兆 udp_clk=12.5M / 2'b10=千兆 udp_clk=125M，
// 由 udp_clk_gen 自动按 tri_speed 选时钟源）。当前用**千兆**——板载 PHY 与 PC
// 网卡自协商即 1G，且后续数据面（图/音上传）需要带宽。
// ---------------------------------------------------------------------------
module eth_subsys(
    input  wire        clk_50,           // 主输入时钟 50M（pll_gen 参考）
    input  wire        rst_all,          // 高有效系统复位（我们工程统一复位）

    // RGMII ↔ 板载 PHY（RTL8211）
    input  wire        phy1_rgmii_rx_clk,
    input  wire        phy1_rgmii_rx_ctl,
    input  wire [3:0]  phy1_rgmii_rx_data,
    output wire        phy1_rgmii_tx_clk,
    output wire        phy1_rgmii_tx_ctl,
    output wire [3:0]  phy1_rgmii_tx_data,
    output wire        phy_reset,

    // 应用层（跨域握手，见头注释）
    output wire [7:0]  cmd,
    output wire        cmd_pending,
    input  wire        cmd_ack_t,
    input  wire        tx_tog,
    input  wire [63:0] tx_pkt,

    // 写侧分叉：图像发射流旁路（tap_clk = sd_card_clk 域；sys_rst = rst_all）
    input  wire        sys_rst,
    input  wire        tap_clk,
    input  wire        tap_val,
    input  wire [31:0] tap_word,
    input  wire        tap_end,
    // 读侧 dump：显示读数据捕获流（独立源时钟 video_clk，type=0x0004）
    input  wire        tap2_clk,
    input  wire        tap2_val,
    input  wire [31:0] tap2_word,
    input  wire        tap2_end
);
    parameter DEVICE           = "EG4";
    parameter LOCAL_UDP_PORT   = 16'h0001;
    parameter LOCAL_IP         = 32'hc0a88902;   // 192.168.137.2（板卡）
    parameter LOCAL_MAC        = 48'h0123456789ab;
    parameter DST_IP           = 32'hc0a88901;   // 192.168.137.1（PC 侧）
    // 速率开关（2026-10-02 定）：**当前=千兆**（GIGABIT=1）。
    // 已知风险（用户明确接受）：综合时序过不了——厂商加密 UDP 栈内部（ARP 缓存）
    // 在 125MHz 下实测 Fmax 只有 44MHz（setup 差 5.3ns，281 个端点），
    // 还把 SDRAM 域一起拖违例。判断依据：**功能能跑通**（ping + 全部命令实测通过），
    // 且最坏情况只是以太网模块本身不稳，不影响显示/串口/按键主线。
    // 若将来要换百兆：GIGABIT=0（rx_pll 自动不例化、时钟直通）+ pin.adc 换回
    // 注释里那份（DS=8/无 OUTDEL）。细节见 docs/ethernet.md。
    parameter GIGABIT          = 1'b1;
    parameter TRI_SPEED        = GIGABIT ? 2'b10 : 2'b01;   // 2'b10=千兆 2'b01=百兆

    // ================= 复位（demo 模式：PLL lock + 软复位计数）=================
    // ⚠ 极性：clk_gen_rst_gen 的 reset 是**高有效**（直连 EG_PHY_PLL.reset），
    // demo 写 `.reset(~key1)` 是因为 key1 按键平时为高、按下为低，故"不按"= 0。
    // rst_all 平时已经是 0（复位期才是 1），所以这里必须直接接 rst_all——
    // 曾经误接成 `~rst_all`，导致平时恒 1 = **整个以太网子系统被永久钉在复位**
    //（首次上板 ping 完全不通的根因：PHY 链路照常协商成功，FPGA 侧一字不发）。
    //
    // ⚠ 只**上电**复位一次，之后按复位键不再打断以太网（2026-10-02 二次上板）：
    //   现象——烧录后 ping 和网络控制都正常，但按复位键后以太网再也回不来。
    //   线索——厂商例程把 eth 的 reset 全接 1'b0（**从不复位**），说明这套
    //   MAC/UDP 栈 IP 不为"运行中复位再恢复"设计。
    //   做法——上电跟随 rst_all（含 PLL 锁定等待），rst_all 首次释放即锁定为
    //   永久释放；之后按键复位只影响显示/SD 主线，eth 不再被复位。
    //   （若 eth 真的卡死，用断电重上电恢复。）
    reg eth_rst_latch = 1'b1;
    always @(posedge clk_50)
        if (eth_rst_latch && !rst_all)
            eth_rst_latch <= 1'b0;
    wire        eth_rst_in = eth_rst_latch;
    wire        reset_reg;
    wire        temac_clk, clk_125_out, temac_clk90;
    wire        clk_12_5_out, clk_1_25_out, clk_25_out;
    wire        udp_clk;

    clk_gen_rst_gen #(.DEVICE(DEVICE)) u_clk_gen(
        .reset          (eth_rst_in),
        .clk_in         (clk_50),        // 50M（demo 同款）
        .rst_out        (reset_reg),     // = !extlock，锁后为 0
        .clk_125_out0   (temac_clk),
        .clk_125_out1   (clk_125_out),
        .clk_125_out2   (temac_clk90),
        .clk_12_5_out   (clk_12_5_out),
        .clk_1_25_out   (clk_1_25_out),
        .clk_25_out     (clk_25_out)
    );

    // 软复位计数（udp_clk 域，照 demo soft_reset_cnt）：PLL 锁定后 UDP 栈
    // 再被复位 255 拍，保证栈在时钟稳定后干净启动
    reg [7:0] soft_cnt = 8'hff;
    always @(posedge udp_clk or posedge eth_rst_in)
        if (eth_rst_in) soft_cnt <= 8'hff;
        else if (soft_cnt > 0) soft_cnt <= soft_cnt - 1'b1;

    wire reset = eth_rst_in || reset_reg || (soft_cnt != 8'd0);

    // PHY 复位：上电后保持一段（clk_25_out 域计数），然后释放（demo 同款）
    reg [7:0] phy_rst_cnt = 8'd0;
    always @(posedge clk_25_out or posedge eth_rst_in)
        if (eth_rst_in) phy_rst_cnt <= 8'd0;
        else if (phy_rst_cnt < 8'd255) phy_rst_cnt <= phy_rst_cnt + 1'b1;
    assign phy_reset = phy_rst_cnt[7];

    // ================= 应用层（eth_front，udp_clk 域）=================
    wire [7:0]  app_rx_data;
    wire        app_rx_data_valid;
    wire [15:0] app_rx_data_length;
    wire        udp_tx_ready, app_tx_ack;
    wire [7:0]  app_tx_data;
    wire        app_tx_data_request, app_tx_data_valid;
    wire [15:0] udp_data_length;

    eth_front u_eth_front (
        .app_rx_clk        (udp_clk),
        .app_tx_clk        (udp_clk),
        .reset             (reset),
        .app_rx_data       (app_rx_data),
        .app_rx_data_valid (app_rx_data_valid),
        .app_rx_data_length(app_rx_data_length),
        .udp_tx_ready      (udp_tx_ready),
        .app_tx_ack        (app_tx_ack),
        .app_tx_data       (app_tx_data),
        .app_tx_data_request(app_tx_data_request),
        .app_tx_data_valid (app_tx_data_valid),
        .udp_data_length   (udp_data_length),
        .cmd               (cmd),
        .cmd_pending       (cmd_pending),
        .cmd_ack_t         (cmd_ack_t),
        .tx_tog            (tx_tog),
        .tx_pkt            (tx_pkt),
        .sys_rst           (sys_rst),
        .tap_clk           (tap_clk),
        .tap_val           (tap_val),
        .tap_word          (tap_word),
        .tap_end           (tap_end),
        .tap2_clk          (tap2_clk),
        .tap2_val          (tap2_val),
        .tap2_word         (tap2_word),
        .tap2_end          (tap2_end)
    );

    // ================= UDP/IP 协议栈（官方 IP）=================
    // 静态 IP/端口：地址/端口给常量，**valid 必须"复位期间 0、释放后 1"**——
    // 官方栈在 valid 的上升沿装载 input_*。demo（udp_transmit_test.v）正是这么做的：
    //   if(reset) valid<=0;  else valid<=1;      ← 复位后产生一次 0→1 边沿
    // 教训：①接恒 0 → 永不装载；②接恒 1（上电即 1）→ 复位释放时**没有边沿**，
    // 同样可能不装载。两者都会表现为"收到包但从不回包"。
    reg local_cfg_valid;
    always @(posedge udp_clk)
        local_cfg_valid <= ~reset;
    wire [31:0] local_ip_dyn     = LOCAL_IP;
    wire [15:0] local_port_dyn   = LOCAL_UDP_PORT;
    // ================= TEMAC MAC + RGMII 的连线声明 =================
    // 必须在 udp_ip_protocol_stack 例化之前声明：否则例化端口上的名字会被
    // 隐式声明成 1bit 线网（TD 报 HDL-7225 critical），与后面的显式声明冲突，
    // 且隐式线网会静默截断位宽。
    wire        temac_tx_ready, temac_tx_valid, temac_tx_sof, temac_tx_eof;
    wire [7:0]  temac_tx_data;
    wire        temac_rx_ready, temac_rx_valid_n, temac_rx_sof, temac_rx_eof;
    wire [7:0]  temac_rx_data;
    wire        tx_collision, tx_retransmit, tx_rdy_w;
    wire        tx_clk_int, rx_clk_int;
    wire [7:0]  tx_ifg_val = 8'h00;
    wire        pause_req  = 1'b0;
    wire [15:0] pause_val  = 16'h0;
    wire [47:0] pause_source_addr = 48'h5af1f2f3f4f5;
    wire [47:0] unicast_address = {
        LOCAL_MAC[7:0], LOCAL_MAC[15:8], LOCAL_MAC[23:16],
        LOCAL_MAC[31:24], LOCAL_MAC[39:32], LOCAL_MAC[47:40]};
    wire [19:0] mac_cfg_vector = {1'b0, 2'b00, TRI_SPEED, 8'b00000010, 7'b0000010};
    wire [7:0]  rx_data, tx_data;
    wire        rx_valid, tx_valid, rx_correct_frame, rx_error_frame;
    wire        rx_clk_en_int_w, tx_clk_en_int_w;

    wire [7:0]  app_tx_data_dummy;   // 占位（栈要求常量目的端口/地址）
    udp_ip_protocol_stack #(
        .DEVICE             (DEVICE),
        .LOCAL_UDP_PORT_NUM (LOCAL_UDP_PORT),
        .LOCAL_IP_ADDRESS   (LOCAL_IP),
        .LOCAL_MAC_ADDRESS  (LOCAL_MAC)
    ) u_udp_stack (
        .udp_rx_clk            (udp_clk),
        .udp_tx_clk            (udp_clk),
        .reset                 (reset),
        .udp2app_tx_ready      (udp_tx_ready),
        .udp2app_tx_ack        (app_tx_ack),
        .app_tx_request        (app_tx_data_request),
        .app_tx_data_valid     (app_tx_data_valid),
        .app_tx_data           (app_tx_data),
        .app_tx_data_length    (udp_data_length),
        .app_tx_dst_port       (16'h0002),          // PC 侧端口（demo 同款）
        .ip_tx_dst_address     (DST_IP),            // PC 侧 IP
        .input_local_udp_port_num       (local_port_dyn),
        .input_local_udp_port_num_valid (local_cfg_valid),
        .input_local_ip_address         (local_ip_dyn),
        .input_local_ip_address_valid   (local_cfg_valid),
        .app_rx_data_valid      (app_rx_data_valid),
        .app_rx_data            (app_rx_data),
        .app_rx_data_length     (app_rx_data_length),
        .app_rx_port_num        (),
        .temac_rx_ready         (temac_rx_ready),
        .temac_rx_valid         (!temac_rx_valid_n),  // fifo 的 _n 低有效，栈要高有效
        .temac_rx_data          (temac_rx_data),
        .temac_rx_sof           (temac_rx_sof),
        .temac_rx_eof           (temac_rx_eof),
        .temac_tx_ready         (temac_tx_ready),
        .temac_tx_valid         (temac_tx_valid),
        .temac_tx_data          (temac_tx_data),
        .temac_tx_sof           (temac_tx_sof),
        .temac_tx_eof           (temac_tx_eof),
        .ip_rx_error            (),
        .arp_request_no_reply_error ()
    );


    // ============ RGMII 接收时钟：PHY 的 RXC 经 rx_pll 再生 ============
    // 照厂商 **HX4S20 千兆例程**（33_..._final_1000）：百兆 demo 是把
    // phy1_rgmii_rx_clk 直接接给 MAC，125MHz 下采样窗口对不上（表现：字节收得到
    // 但全是垃圾，栈解析不出 ARP，板子也就永远不回包）。rx_pll 的 FIN=125MHz，
    // **只在千兆链路下锁定**——改回百兆需旁路本模块。
    // 参数原样来自厂商千兆例程的 al_ip/rx_pll.v（FIN=125M，C0/C1=125M/C2=250M）。
    // 内联而**不单独建文件**：TD 保存工程时会用内存清单覆盖 .al，新增源文件的
    // 登记容易被抹掉（会报 "xxx is a black box"）；生成出来的 IP 本就是
    // EG_PHY_PLL 原语的包装，内联完全等价。
    // 千兆：RXC(125M) 经 PLL 再生后送 MAC；百兆：直接送原时钟（厂商百兆例程同款，
    // 25MHz 时序宽松）。PLL 用 generate 门控——百兆下不例化，省一个 PLL 也避免
    // TD 报 "primary clock defined on internal clock network"（USR-6133）。
    wire rx_clk_90;                     // 送 MAC 的 RGMII 接收时钟
    generate
    if (GIGABIT) begin : g_gig
        wire rx_clk_0, rx_clk_250, rx_clk_0_buf;
        wire rx_pll_lock, rx_pll_psdone;        // extlock/psdone（未用，保留）
        wire [7:0] rx_pll_do;                   // 动态配置数据（未用）
        wire rx_pll_c3, rx_pll_c4;              // clkc[3]/clkc[4]（未启用）
        // 未使用的输出必须接哑元 wire——TD 不允许输出端口连接里写常量
        EG_LOGIC_BUFG u_rx_pll_bufg (
            .i (rx_clk_0_buf),
            .o (rx_clk_0)
        );
        EG_PHY_PLL #(
            .DPHASE_SOURCE      ("DISABLE"),
            .DYNCFG             ("DISABLE"),
            .FIN                ("125.000"),
            .FEEDBK_MODE        ("NORMAL"),
            .FEEDBK_PATH        ("CLKC0_EXT"),
            .STDBY_ENABLE       ("DISABLE"),
            .PLLRST_ENA         ("ENABLE"),
            .SYNC_ENABLE        ("DISABLE"),
            .GMC_GAIN           (6),
            .GMC_TEST           (15),
            .ICP_CURRENT        (13),
            .KVCO               (4),
            .LPF_CAPACITOR      (1),
            .LPF_RESISTOR       (2),
            .REFCLK_DIV         (1),
            .FBCLK_DIV          (1),
            .CLKC0_ENABLE       ("ENABLE"),
            .CLKC0_DIV          (8),
            .CLKC0_CPHASE       (7),
            .CLKC0_FPHASE       (0),
            .CLKC1_ENABLE       ("ENABLE"),
            .CLKC1_DIV          (8),
            .CLKC1_CPHASE       (7),
            .CLKC1_FPHASE       (0),
            .CLKC2_ENABLE       ("ENABLE"),
            .CLKC2_DIV          (4),
            .CLKC2_CPHASE       (3),
            .CLKC2_FPHASE       (0)
        ) u_rx_pll (
            .refclk   (phy1_rgmii_rx_clk),
            .reset    (reset),
            .stdby    (1'b0),
            .extlock  (rx_pll_lock),
            .load_reg (1'b0),
            .psclk    (1'b0),
            .psdown   (1'b0),
            .psstep   (1'b0),
            .psclksel (3'b000),
            .psdone   (rx_pll_psdone),
            .dclk     (1'b0),
            .dcs      (1'b0),
            .dwe      (1'b0),
            .di       (8'b00000000),
            .daddr    (6'b000000),
            .do       (rx_pll_do),
            .fbclk    (rx_clk_0),
            .clkc     ({rx_pll_c4, rx_pll_c3, rx_clk_250, rx_clk_90, rx_clk_0_buf})
        );
    end else begin : g_mbps
        assign rx_clk_90 = phy1_rgmii_rx_clk;
    end
    endgenerate

    temac_block #(.DEVICE(DEVICE)) u_temac_block (
        .reset                (reset),
        // 千兆须用 clk_125_out + 真 90° 时钟（TXC=125MHz，时钟要相对数据移相~2ns
        // PHY 才采得准，否则"发得出去、PC 全收不到"）；百兆两者同用 temac_clk。
        .gtx_clk              (GIGABIT ? clk_125_out : temac_clk),
        .gtx_clk_90           (GIGABIT ? temac_clk90  : temac_clk),
        .rx_clk               (rx_clk_int),
        .rx_clk_en            (rx_clk_en_int_w),
        .rx_data              (rx_data),
        .rx_data_valid        (rx_valid),
        .rx_correct_frame     (rx_correct_frame),
        .rx_error_frame       (rx_error_frame),
        .rx_status_vector     (),
        .rx_status_vld        (),
        .tx_clk               (tx_clk_int),
        .tx_clk_en            (tx_clk_en_int_w),
        .tx_data              (tx_data),
        .tx_data_en           (tx_valid),
        .tx_rdy               (tx_rdy_w),
        .tx_stop              (1'b0),
        .tx_collision         (tx_collision),
        .tx_retransmit        (tx_retransmit),
        .tx_ifg_val           (tx_ifg_val),
        .tx_status_vector     (),
        .tx_status_vld        (),
        .pause_req            (pause_req),
        .pause_val            (pause_val),
        .pause_source_addr    (pause_source_addr),
        .unicast_address      (unicast_address),
        .mac_cfg_vector       (mac_cfg_vector),
        .rgmii_txd            (phy1_rgmii_tx_data),
        .rgmii_tx_ctl         (phy1_rgmii_tx_ctl),
        .rgmii_txc            (phy1_rgmii_tx_clk),
        .rgmii_rxd            (phy1_rgmii_rx_data),
        .rgmii_rx_ctl         (phy1_rgmii_rx_ctl),
        .rgmii_rxc            (rx_clk_90),        // 千兆=rx_pll 输出；百兆=原时钟
        .inband_link_status   (),
        .inband_clock_speed   (),
        .inband_duplex_status ()
    );

    // ================= UDP 栈 ↔ TEMAC 客户端 FIFO =================
    tx_client_fifo #(.DEVICE(DEVICE)) u_tx_fifo (
        .rd_clk        (tx_clk_int),
        .rd_sreset     (reset),
        .rd_enable     (tx_clk_en_int_w),
        .tx_data       (tx_data),
        .tx_data_valid (tx_valid),
        .tx_ack        (tx_rdy_w),
        .tx_collision  (tx_collision),
        .tx_retransmit (tx_retransmit),
        .overflow      (),
        .wr_clk        (udp_clk),
        .wr_sreset     (reset),
        .wr_data       (temac_tx_data),
        .wr_sof_n      (temac_tx_sof),
        .wr_eof_n      (temac_tx_eof),
        .wr_src_rdy_n  (temac_tx_valid),
        .wr_dst_rdy_n  (temac_tx_ready),
        .wr_fifo_status()
    );

    rx_client_fifo #(.DEVICE(DEVICE)) u_rx_fifo (
        .wr_clk        (rx_clk_int),
        .wr_enable     (rx_clk_en_int_w),
        .wr_sreset     (reset),
        .rx_data       (rx_data),
        .rx_data_valid (rx_valid),
        .rx_good_frame (rx_correct_frame),
        .rx_bad_frame  (rx_error_frame),
        .overflow      (),
        .rd_clk        (udp_clk),
        .rd_sreset     (reset),
        .rd_data_out   (temac_rx_data),
        .rd_sof_n      (temac_rx_sof),
        .rd_eof_n      (temac_rx_eof),
        .rd_src_rdy_n  (temac_rx_valid_n),
        .rd_dst_rdy_n  (temac_rx_ready),
        .rx_fifo_status()
    );

    // ================= udp_clk 选择（百兆 → 12.5M）=================
    udp_clk_gen #(.DEVICE(DEVICE)) u_udp_clk_gen (
        .reset        (eth_rst_in),
        .tri_speed    (TRI_SPEED),
        .clk_125_in   (clk_125_out),
        .clk_12_5_in  (clk_12_5_out),
        .clk_1_25_in  (clk_1_25_out),
        .udp_clk_out  (udp_clk)
    );

endmodule
