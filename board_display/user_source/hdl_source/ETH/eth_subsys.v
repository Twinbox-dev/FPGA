`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// eth_subsys.v — 以太网子系统（移植自官方 32_Ethernet_test UDP demo）
//
// 组成（与 demo udp_transmit_test.v 对应）：
//   clk_gen_rst_gen(125/12.5/25M + PLL lock 复位) → udp_clk_gen(按速率选
//   udp_clk，百兆=12.5M) → udp_ip_protocol_stack(UDP/IP/ARP，官方 IP) ↔
//   tx/rx_client_fifo ↔ temac_block(TEMAC_CORE + RGMII) ↔ UDP 栈
// 显示板应用层只接收正式媒体协议，并向媒体板回送结果与状态。
//
// 网络配置：本地 IP 192.168.137.2 / MAC 01:23:45:67:89:ab / UDP 端口 1。
// 显示板所有应用层发送均回媒体板 .3:1；PC 控制和 D 快照由媒体板处理。
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
    output wire        app_clk_out,
    output wire [7:0]  app_rx_data_out,
    output wire        app_rx_data_valid_out,
    output wire [15:0] app_rx_data_length_out,
    output wire        app_rx_packet_start_out,
    output wire        app_rx_packet_end_out,
    output wire [5:0]  link_trace,

    // 正式媒体应用层收发
    input  wire        media_packet_request,
    input  wire        media_packet_valid,
    input  wire [7:0]  media_packet_data,
    input  wire [15:0] media_packet_length,
    input  wire        media_packet_to_source,
    input  wire        media_packet_to_owner,
    input  wire        media_source_claim,
    output wire        media_packet_ack,
    output wire        media_packet_ready,
    input wire digest_req, digest_valid,
    input wire [7:0] digest_data,
    input wire [15:0] digest_length,
    output wire digest_ready, digest_ack
);
    parameter DEVICE           = "EG4";
    parameter LOCAL_UDP_PORT   = 16'h0001;
    parameter LOCAL_IP         = 32'hc0a88902;   // 192.168.137.2（板卡）
    parameter LOCAL_MAC        = 48'h0123456789ab;
    parameter MEDIA_PEER_IP    = 32'hc0a88903;    // 媒体板 .3
    parameter MEDIA_PEER_MAC   = 48'h020000000003; // 媒体板固定 MAC
    parameter MEDIA_PEER_UDP_PORT = 16'h0001;     // 媒体应用端口
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
    assign app_clk_out = udp_clk;

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

    // ================= 应用层（媒体协议，udp_clk 域）=================
    wire [7:0]  app_rx_data;
    wire        app_rx_data_valid;
    wire        ip_rx_error;
    wire [15:0] app_rx_data_length;
    wire        app_rx_packet_start, app_rx_packet_end;
    wire        udp_tx_ready, app_tx_ack;
    wire [7:0]  app_tx_data;
    wire        app_tx_data_request, app_tx_data_valid;
    wire [15:0] udp_data_length;
    wire digest_chunk_active;
    wire [47:0] app_rx_source_mac;
    wire [31:0] app_rx_source_ip;
    wire [15:0] app_rx_source_port;
    wire [47:0] pc_peer_mac;
    wire pc_peer_valid;
    reg [47:0] owner_mac;
    reg [31:0] owner_ip;
    reg [15:0] owner_port;
    reg owner_valid;
    wire route_chunk_to_source = media_packet_to_source && (app_rx_source_ip != 0) &&
                                 (app_rx_source_port != 0);
    wire route_chunk_to_owner = media_packet_to_owner && owner_valid;
    wire [31:0] tx_dst_ip = digest_chunk_active ?
                            (route_chunk_to_owner ? owner_ip :
                             (route_chunk_to_source ? app_rx_source_ip : MEDIA_PEER_IP)) : 32'hc0a88901;
    wire [15:0] tx_dst_port = digest_chunk_active ?
                              (route_chunk_to_owner ? owner_port :
                               (route_chunk_to_source ? app_rx_source_port : MEDIA_PEER_UDP_PORT)) : 16'd4;
    // Choose MAC by the already-resolved packet route. Avoid a second cascade
    // of 32-bit destination-IP comparisons on the UDP transmit timing path.
    wire [47:0] tx_dst_mac = digest_chunk_active ?
                             (route_chunk_to_owner ? owner_mac :
                              (route_chunk_to_source ? app_rx_source_mac : MEDIA_PEER_MAC)) :
                             (pc_peer_valid ? pc_peer_mac : MEDIA_PEER_MAC);

    always @(posedge udp_clk or posedge reset) begin
        if (reset) begin
            owner_mac <= 0; owner_ip <= 0; owner_port <= 0; owner_valid <= 1'b0;
        end else if (media_source_claim && app_rx_source_ip != 0 && app_rx_source_port != 0) begin
            owner_mac <= app_rx_source_mac;
            owner_ip <= app_rx_source_ip;
            owner_port <= app_rx_source_port;
            owner_valid <= 1'b1;
        end
    end

    media_tx_mux u_tx_mux (
        .clk          (udp_clk), .rst(reset),
        .stack_ready  (udp_tx_ready), .stack_ack(app_tx_ack),
        .ctrl_req     (digest_req), .ctrl_valid(digest_valid),
        .ctrl_data    (digest_data), .ctrl_length(digest_length),
        .ctrl_ready   (digest_ready), .ctrl_ack(digest_ack),
        .chunk_req    (media_packet_request), .chunk_valid(media_packet_valid),
        .chunk_data   (media_packet_data), .chunk_length(media_packet_length),
        .chunk_ack    (media_packet_ack), .chunk_ready(media_packet_ready),
        .chunk_active(), .chunk_owner(digest_chunk_active),
        .stack_req    (app_tx_data_request), .stack_valid(app_tx_data_valid),
        .stack_data   (app_tx_data), .stack_length(udp_data_length)
    );

    assign app_rx_data_out = app_rx_data;
    assign app_rx_data_valid_out = app_rx_data_valid;
    assign app_rx_data_length_out = app_rx_data_length;
    assign app_rx_packet_start_out = app_rx_packet_start;
    assign app_rx_packet_end_out = app_rx_packet_end;

    // ================= TEMAC MAC + RGMII 的连线声明 =================
    // 必须在协议层例化之前声明：否则例化端口上的名字会被
    // 隐式声明成 1bit 线网（TD 报 HDL-7225 critical），与后面的显式声明冲突，
    // 且隐式线网会静默截断位宽。
    wire        temac_tx_ready, temac_tx_valid, temac_tx_sof, temac_tx_eof;
    wire [7:0]  temac_tx_data;
    wire        temac_rx_ready, temac_rx_valid_n, temac_rx_sof, temac_rx_eof;
    wire [7:0]  temac_rx_data;
    wire        tx_collision, tx_retransmit, tx_rdy_w;
    wire        tx_clk_int, rx_clk_int;
    wire        rx_valid, tx_valid, rx_correct_frame, rx_error_frame;
    wire [28:0] tx_status_vector;
    wire tx_status_vld;
    // Optional top-level link diagnostics. Unused trace logic is removed when
    // VIDEO_LINK_DIAGNOSTICS=0; it never feeds the networking state machines.
    reg trace_bad_frame,trace_ip_error,trace_tx_status;
    always @(posedge rx_clk_int or posedge reset)
        if(reset)trace_bad_frame<=1'b0;
        else if(rx_error_frame)trace_bad_frame<=1'b1;
    always @(posedge udp_clk or posedge reset)
        if(reset)trace_ip_error<=1'b0;
        else if(ip_rx_error)trace_ip_error<=1'b1;
    always @(posedge clk_125_out or posedge reset)
        if(reset)trace_tx_status<=1'b0;
        else if(tx_status_vld)trace_tx_status<=1'b1;
    assign link_trace={trace_tx_status,trace_ip_error,reset,trace_bad_frame,!temac_tx_valid,!temac_rx_valid_n};
    wire [7:0]  tx_ifg_val = 8'h00;
    wire        pause_req  = 1'b0;
    wire [15:0] pause_val  = 16'h0;
    wire [47:0] pause_source_addr = 48'h5af1f2f3f4f5;
    wire [47:0] unicast_address = {
        LOCAL_MAC[7:0], LOCAL_MAC[15:8], LOCAL_MAC[23:16],
        LOCAL_MAC[31:24], LOCAL_MAC[39:32], LOCAL_MAC[47:40]};
    wire [19:0] mac_cfg_vector = {1'b0, 2'b00, TRI_SPEED, 8'b00000010, 7'b0000010};
    wire [7:0]  rx_data, tx_data;
    wire        rx_clk_en_int_w, tx_clk_en_int_w;

    // The display side only exchanges IPv4/UDP with the fixed media peer.
    // Its lightweight stack replies to ARP and intentionally omits ICMP echo.
    display_udp_lite #(
        .LOCAL_IP  (LOCAL_IP),
        .LOCAL_MAC (LOCAL_MAC),
        .PEER_IP   (MEDIA_PEER_IP),
        .PEER_MAC  (MEDIA_PEER_MAC),
        .LOCAL_PORT(LOCAL_UDP_PORT),
        .ISOLATE_VIDEO_PEER(1)
    ) u_udp_stack (
        .clk                    (udp_clk),
        .reset                  (reset),
        .udp2app_tx_ready      (udp_tx_ready),
        .udp2app_tx_ack        (app_tx_ack),
        .app_tx_request        (app_tx_data_request),
        .app_tx_data_valid     (app_tx_data_valid),
        .app_tx_data           (app_tx_data),
        .app_tx_data_length    (udp_data_length),
        .app_tx_dst_port       (tx_dst_port),
        .ip_tx_dst_address     (tx_dst_ip),
        .ip_tx_dst_mac         (tx_dst_mac),
        .app_rx_data_valid     (app_rx_data_valid),
        .app_rx_data           (app_rx_data),
        .app_rx_data_length    (app_rx_data_length),
        .app_rx_packet_start   (app_rx_packet_start),
        .app_rx_packet_end     (app_rx_packet_end),
        .app_rx_port_num       (),
        .app_rx_source_mac     (app_rx_source_mac),
        .app_rx_source_ip      (app_rx_source_ip),
        .app_rx_source_port    (app_rx_source_port),
        .pc_peer_mac_out       (pc_peer_mac),
        .pc_peer_valid_out     (pc_peer_valid),
        .temac_rx_ready        (temac_rx_ready),
        .temac_rx_valid        (!temac_rx_valid_n),
        .temac_rx_data         (temac_rx_data),
        .temac_rx_sof          (temac_rx_sof),
        .temac_rx_eof          (temac_rx_eof),
        .temac_tx_ready        (temac_tx_ready),
        .temac_tx_valid        (temac_tx_valid),
        .temac_tx_data         (temac_tx_data),
        .temac_tx_sof          (temac_tx_sof),
        .temac_tx_eof          (temac_tx_eof),
        .ip_rx_error           (ip_rx_error),
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
        .tx_status_vector     (tx_status_vector),
        .tx_status_vld        (tx_status_vld),
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
