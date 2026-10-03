
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 手动下一张
    input                       key2,           // 自动播放 开/关
    input                       key3,           // 手动上一张
    input                       uart_rx,        // CH340G USB-UART（1Mbaud 8N1）
    output                      uart_tx,

    // 以太网 RGMII（板载 RTL8211 PHY，引脚见 pin.adc）
    input                       eth_rgmii_rxc,
    input                       eth_rgmii_rx_ctl,
    input  [3:0]                eth_rgmii_rxd,
    output                      eth_rgmii_txc,
    output                      eth_rgmii_tx_ctl,
    output [3:0]                eth_rgmii_txd,
    output                      eth_phy_reset,

	output [5:0]                seg_sel,
	output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
// 720p + RGB565：1 字 = 2 像素，帧缓冲 = 1280*720/2 = 460800 字
// SDRAM 布局（21 位地址 = 2M 字 = 8MB，恰好用满）：
//   BUF0/1 = 视频 A/B（各 460800 字），BUF2/3 = 音频 A/B（各 587776 字 ≈ 98s）
parameter FRAME_WORDS   = 24'd460800;
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = 24'd460800;
parameter BUF2_ADDR     = 24'd921600;
parameter BUF3_ADDR     = 24'd1509376;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire        display_valid;

wire [3:0]  state_code;
wire [4:0]  img_idx_w;        // UART 遥测：当前图索引
wire        img_wav_w;        // UART 遥测：该图是否配同名 WAV
wire        auto_play_w;      // 遥测：自动轮播开关当前状态
// ---- 板级调试面板（数码管 6 位，只读，不影响功能）----
wire [7:0]  dbg_fat_state;   // fat32_ro FSM 状态（0=RST 1=ISSUE 2=STREAM 3=MOUNT
                             //  4=BPBDEC 5=FATDEC 6=DIRDONE 7=DATADONE 8=MOUNTED
                             //  9=ERR 10=OPEN 11=LBA 12=BPB2）
wire        dbg_fat_err;     // fat32 错误锁存（1=进了 S_ERR）
wire        hdmi_locked;

// ---- d0 诊断位：视频 FIFO 下溢 / 音频欠载粘滞标志（置位后保持，复位才清）----
wire        vid_rd_empty;    // frame_read_write 视频读 FIFO 空标志（video_clk 域）
reg         vid_und_stick_v; // video_clk 域粘滞
reg  [1:0]  vid_und_sync;    // 2FF 同步进 clk 域
reg         vid_und_stick;   // clk 域粘滞
reg         aud_und_stick;   // clk 域音频欠载粘滞
wire [3:0]  dbg_underrun;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire [20:0] sd_card_write_len;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;

// ---- 音频播放（S4：sd_card_clk 域输出，aud_valid 每样本保持 2084 clk，跨 25M 采样安全）----
wire        aud_valid;
wire [23:0] aud_l;
wire [23:0] aud_r;
wire        aud_play_done;
wire        aud_underrun;
wire        aud_pair_on;
wire        sd_aud_rd_req;
wire        sd_aud_rd_en;
wire [1:0]  sd_aud_rd_addr_idx;
wire [20:0] sd_aud_rd_len;
wire        sd_aud_rd_req_ack;
wire        sd_aud_rd_finish;
wire [31:0] sd_aud_rd_data;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b 相关
wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 统一复位：TF 图像链路 + HDMI 链路
wire sys_pll_lock;
wire video_pll_lock;
wire rst_all;

reg [19:0] rst_cnt = 20'd0;
reg rst_all_reg = 1'b1;

always @(posedge clk) begin
    if (!rst_n) begin
        rst_cnt <= 20'd0;
        rst_all_reg <= 1'b1;
    end else if (!rst_all_reg) begin
        // 一旦复位释放，忽略后续微小的 PLL 抖动，防止系统在使用时随机复位
        rst_all_reg <= 1'b0;
    end else if (sys_pll_lock && video_pll_lock) begin
        // 等待 PLL 连续稳定 20ms @ 50MHz
        if (rst_cnt < 20'd1_000_000) begin
            rst_cnt <= rst_cnt + 1'b1;
            rst_all_reg <= 1'b1;
        end else begin
            rst_all_reg <= 1'b0;
        end
    end else begin
        rst_cnt <= 20'd0;
        rst_all_reg <= 1'b1;
    end
end

assign rst_all = rst_all_reg;

// 视频读 FIFO 下溢粘滞：显示活动期（de 高）而 FIFO 空 = 带宽不够。
// 跳过每帧第一条活动行：帧首 SDRAM 突发尚未填满 FIFO 属正常竞态，不算下溢。
// 另加开机稳态窗口：前 4 帧不检测——display_valid 拉高时读 FIFO 可能整帧
// 未填起（读引擎第一笔 SDRAM 突发未落地），第 2 行起短暂空一次即永久钉住
// 粘滞位，属开机正常过渡而非欠载。窗口过后真欠载照常置位。
reg de_0_d, line_seen;
reg vs_0_d;
reg [2:0] vf_cnt;              // 帧计数（vs 上升沿）
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        vid_und_stick_v <= 1'b0;
        de_0_d   <= 1'b0;
        line_seen <= 1'b0;
        vs_0_d   <= 1'b0;
        vf_cnt   <= 3'd0;
    end else begin
        de_0_d <= de_0;
        vs_0_d <= vs_0;
        if (vs_0 && !vs_0_d)
            vf_cnt <= (vf_cnt == 3'd7) ? 3'd7 : vf_cnt + 1'b1;
        if (vs_0)
            line_seen <= 1'b0;
        else if (de_0_d && !de_0)
            line_seen <= 1'b1;
        if (de_0 && vid_rd_empty && line_seen && (vf_cnt >= 3'd4))
            vid_und_stick_v <= 1'b1;
    end
end
// 2FF 同步 video_clk → clk（同步复位，与本文件 rst_cnt 块同风格）
always @(posedge clk) begin
    if (!rst_n) begin
        vid_und_sync <= 2'b00;
        vid_und_stick <= 1'b0;
        aud_und_stick <= 1'b0;
    end else begin
        vid_und_sync  <= {vid_und_sync[0], vid_und_stick_v};
        if (vid_und_sync[1])
            vid_und_stick <= 1'b1;
        if (aud_underrun)
            aud_und_stick <= 1'b1;
    end
end
assign dbg_underrun = {vid_und_stick, aud_und_stick, 2'b00};

// ===================== 控制通道（分层：传输前端 + 传输无关核心）=====================
// ctrl_core 持有命令语义与控制参数（虚拟按键/音量），任何传输前端（现在的 UART、
// 将来的以太网）只要把命令翻译成「字节 + valid」即可复用；详见 ctrl_core.v。
wire vk_next_n, vk_auto_n, vk_prev_n;
wire [7:0]  cmd_byte;
wire        cmd_val_w, tx_req_w;
wire [63:0] tx_pkt_w;
wire [7:0]  uart_cmd;        // UART 前端命令出口
wire        uart_cmd_val;
// 以太网（RGMII ↔ 板载 RTL8211 PHY）
// ⚠ 这些名字**已经是模块端口（ANSI 端口自带线网）**，不能再 wire 声明一遍
//（TD 报 HDL-5372 "redeclaration of ANSI port"）。
wire [3:0]  vol_gain;
wire [3:0]  auto_period_s;   // 轮播周期（秒），ctrl_core 可调
wire [3:0]  bri_gray;        // 亮度档位（格雷码，跨时钟域到 video_clk）
wire [3:0]  ct_gray;         // 对比度档位（格雷码，跨时钟域到 video_clk）

ctrl_core #(
    .VK_PULSE_CYC   (10_000_000)       // 100ms，须明显大于 sd_card_bmp 的 50ms 去抖窗
) ctrl_core_m0(
    .clk            (sd_card_clk),
    .rst            (rst_all),
    .cmd            (cmd_byte),
    .cmd_val        (cmd_val_w),
    .vk_next_n      (vk_next_n),
    .vk_auto_n      (vk_auto_n),
    .vk_prev_n      (vk_prev_n),
    .tx_req         (tx_req_w),
    .tx_pkt         (tx_pkt_w),
    .vol_gain       (vol_gain),
    .auto_period_s  (auto_period_s),
    .bri_gray       (bri_gray),
    .ct_gray        (ct_gray),
    .state_code     (state_code),
    .dbg_fat_state  (dbg_fat_state),
    .flag_a         ({video_pll_lock, sys_pll_lock, Sdr_init_done, display_valid}),
    .flag_b         ({hdmi_locked, dbg_fat_err, disp_buf_idx[1], disp_buf_idx[0]}),
    .dbg_underrun   (dbg_underrun),
    .img_idx        (img_idx_w),
    .img_wav        (img_wav_w),
    .auto_on        (auto_play_w)
);

// UART 前端：只管 8N1 收发与 [CMD,~CMD] 成帧（命令表在 ctrl_core.v）
uart_link #(
    .CLK_FREQ_HZ    (100_000_000),
    .BAUD           (1_000_000)
) uart_link_m0(
    .clk            (sd_card_clk),
    .rst            (rst_all),
    .rx             (uart_rx),
    .tx             (uart_tx),
    .cmd            (uart_cmd),
    .cmd_val        (uart_cmd_val),
    .tx_req         (tx_req_w),
    .tx_pkt         (tx_pkt_w)
);

// ===================== 以太网前端（官方 TEMAC + UDP 栈，RGMII PHY）=====================
// 子系统内 udp_clk（千兆 125M / 百兆 12.5M，见 eth_subsys 的 GIGABIT）与
// ctrl_core(sd_card_clk) 的命令/应答用握手/toggle 跨域。
wire        eth_cmd_pending;
wire [7:0]  eth_cmd;
// ⚠ 这些信号都必须在例化**之前**声明（否则端口上的名字会被隐式声明成 1bit 线网，
// 与后面的声明冲突：HDL-7225 critical）。eth_cmd_ack_t 由 cmd_arb 驱动（wire）；
// eth_tx_tog 在下面的 always 块里赋值（reg）。
wire        eth_cmd_ack_t;
reg         eth_tx_tog;

eth_subsys u_eth_subsys(
    .clk_50              (clk),
    .rst_all             (rst_all),
    .phy1_rgmii_rx_clk   (eth_rgmii_rxc),
    .phy1_rgmii_rx_ctl   (eth_rgmii_rx_ctl),
    .phy1_rgmii_rx_data  (eth_rgmii_rxd),
    .phy1_rgmii_tx_clk   (eth_rgmii_txc),
    .phy1_rgmii_tx_ctl   (eth_rgmii_tx_ctl),
    .phy1_rgmii_tx_data  (eth_rgmii_txd),
    .phy_reset           (eth_phy_reset),
    .cmd                 (eth_cmd),
    .cmd_pending         (eth_cmd_pending),
    .cmd_ack_t           (eth_cmd_ack_t),
    .tx_tog              (eth_tx_tog),
    .tx_pkt              (tx_pkt_w)
);

// 命令仲裁 + 以太网命令握手 → 抽成 cmd_arb 模块（在 ctrl_core.v 里）。
// 抽出来的原因：这段胶水原先只在顶层、不在任何仿真范围内，"命令晚一拍"的 bug
// 只能上板发现；现在由 boardtest 的 tb_cmd_arb 覆盖。
// ⚠ 模块内部必须**组合取用** eth_cmd（pending 期间稳定），给数据打拍就会晚一拍。
cmd_arb u_cmd_arb (
    .clk          (sd_card_clk),
    .eth_pending  (eth_cmd_pending),
    .eth_cmd      (eth_cmd),
    .eth_ack_tog  (eth_cmd_ack_t),
    .uart_cmd     (uart_cmd),
    .uart_cmd_val (uart_cmd_val),
    .cmd_val      (cmd_val_w),
    .cmd_byte     (cmd_byte)
);

// 应答 toggle：每条 ctrl_core 应答翻转一次（eth_front 检测变化取包）
always @(posedge sd_card_clk)
    if (tx_req_w) eth_tx_tog <= ~eth_tx_tog;

// 音量增益（ctrl_core 的 vol_gain：0..8，8=原始，0=静音）：24bit 有符号 ×gain>>3。
// gain=8 时 ≡ 原值（现有字节级音频比对用例不受影响）
wire signed [23:0] aud_l_s = $signed(aud_l);
wire signed [23:0] aud_r_s = $signed(aud_r);
wire signed [27:0] aud_l_g = (aud_l_s * $signed({1'b0, vol_gain})) >>> 3;  // 24×4=28bit
wire signed [27:0] aud_r_g = (aud_r_s * $signed({1'b0, vol_gain})) >>> 3;
wire [23:0] aud_l_v = aud_l_g[23:0];
wire [23:0] aud_r_v = aud_r_g[23:0];

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (sys_pll_lock),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (video_pll_lock),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_all) begin
    if (rst_all)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// ===================== TF 多图扫描与缓存（双缓冲）+ 同名 WAV 音画同步（S4） =====================
sd_card_bmp #(
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd4)
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (rst_all),
    .key_next          (key1 & vk_next_n),   // 物理按键与 UART 虚拟键相与（均低有效）
    .key_auto          (key2 & vk_auto_n),
    .key_prev          (key3 & vk_prev_n),
    .auto_period_s     (auto_period_s),
    .img_idx_out       (img_idx_w),
    .img_wav_out       (img_wav_w),
    .auto_play_out     (auto_play_w),   // 自动轮播开关状态 → ctrl_core 打进遥测包
    .state_code        (state_code),
    .bmp_width         (16'd1280),
    .bmp_height        (16'd720),
    .display_valid     (display_valid),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .write_len         (sd_card_write_len),
    // 音频观测/播放口
    .aud_smp           (),
    .aud_sval          (),
    .aud_item_done     (),
    .aud_scan_done     (),
    .wav_hdr_ok        (),
    .wav_fmt_err      (),
    .wav_data_bytes   (),
    .aud_valid         (aud_valid),
    .aud_l             (aud_l),
    .aud_r             (aud_r),
    .aud_play_done     (aud_play_done),
    .aud_underrun      (aud_underrun),
    .aud_tick          (),
    .aud_pair_on       (aud_pair_on),
    // 音频读口（frame_read_write 音频通道）
    .rd_req            (sd_aud_rd_req),
    .rd_en             (sd_aud_rd_en),
    .rd_addr_idx       (sd_aud_rd_addr_idx),
    .rd_len            (sd_aud_rd_len),
    .rd_req_ack        (sd_aud_rd_req_ack),
    .rd_finish         (sd_aud_rd_finish),
    .rd_data           (sd_aud_rd_data),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso),
    .dbg_fat_state     (dbg_fat_state),
    .dbg_fat_err       (dbg_fat_err)
);

// ===================== 七段数码管（预留）=====================
// 原调试面板（state/fat/flags/underrun 六位）已由 UART 状态包取代而退休：
// 遥测同源（state_code/dbg_fat_state/flag_a/flag_b/dbg_underrun 仍喂
// uart_link 状态包）。保留 seg_scan/seg_decoder 与引脚约束供后续模块
// 复用（通用扫描/译码器，与调试语义无关），现显示固定占位 '8'。
// （2026-10-02 以太网定位期间曾临时改为 o_diag 诊断显示，定位完成后已拆，
//   方法见 docs/ethernet.md 的「调试过程记录」。）
wire [6:0] seg_ph;
seg_decoder u_seg_ph (.bin_data(4'h8), .seg_data(seg_ph));
seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,seg_ph}),
    .seg_data_1        ({1'b1,seg_ph}),
    .seg_data_2        ({1'b1,seg_ph}),
    .seg_data_3        ({1'b1,seg_ph}),
    .seg_data_4        ({1'b1,seg_ph}),
    .seg_data_5        ({1'b1,seg_ph})
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_en           (video_read_en),
    .read_data         (video_read_data),      // 32 位：RGB565 双像素字
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
//
// ===================== 图像调节级：对比度 → 亮度 → 一次钳位 =====================
// 两个档位都由 ctrl_core 给出（格雷码）跨时钟域 2FF 同步到 video_clk——
// 格雷码每次步进只变 1 位，同步后恒为合法旧值/新值（二进制多位直传会出现
// 过渡混合值）。这里也是以后"音频脉动条/OSD 叠加"的注入点。
//
//   对比度：围绕中灰 128 的增益 d×(k)（d = c-128），7 档用移位加减精确实现
//   亮度：  偏移 (level-4)×16
reg  [3:0] ct_gray_s0, ct_gray_s1;
always @(posedge video_clk) begin
    ct_gray_s0 <= ct_gray;
    ct_gray_s1 <= ct_gray_s0;
end
wire [3:0] ct_bin_v = {ct_gray_s1[3],
                       ct_gray_s1[3] ^ ct_gray_s1[2],
                       ct_gray_s1[3] ^ ct_gray_s1[2] ^ ct_gray_s1[1],
                       ct_gray_s1[3] ^ ct_gray_s1[2] ^ ct_gray_s1[1] ^ ct_gray_s1[0]};

reg  [3:0] bri_gray_s0, bri_gray_s1;
always @(posedge video_clk) begin
    bri_gray_s0 <= bri_gray;
    bri_gray_s1 <= bri_gray_s0;
end
wire [3:0] bri_bin_v = {bri_gray_s1[3],
                        bri_gray_s1[3] ^ bri_gray_s1[2],
                        bri_gray_s1[3] ^ bri_gray_s1[2] ^ bri_gray_s1[1],
                        bri_gray_s1[3] ^ bri_gray_s1[2] ^ bri_gray_s1[1] ^ bri_gray_s1[0]};
wire signed [9:0] bri_off = $signed({1'b0, bri_bin_v, 4'b0}) - $signed(10'd64);  // (level-4)×16

// 逐像素调节。对比度增益表（档位:增益）：
//   0:0.5   1:0.75   2:1.0(原始)   3:1.25   4:1.5   5:1.75   6:2.0
function [7:0] adj_px;
    input [7:0]        c;
    input [3:0]        lv;              // 对比度档位
    reg signed [10:0]  d, r, t;
    begin
        d = $signed({1'b0, c}) - 11'sd128;          // -128..127
        case (lv)
            4'd0:    r = d >>> 1;                   // 0.5
            4'd1:    r = d - (d >>> 2);             // 0.75
            4'd2:    r = d;                         // 1.0（原始）
            4'd3:    r = d + (d >>> 2);             // 1.25
            4'd4:    r = d + (d >>> 1);             // 1.5
            4'd5:    r = d + (d >>> 1) + (d >>> 2); // 1.75
            4'd6:    r = d <<< 1;                   // 2.0
            default: r = d;
        endcase
        t = r + 11'sd128 + $signed(bri_off);        // 回到中灰 + 亮度偏移
        adj_px = (t < 11'sd0) ? 8'd0 : (t > 11'sd255) ? 8'd255 : t[7:0];
    end
endfunction

wire [23:0] vout_adj = {adj_px(vout_data_raw[23:16], ct_bin_v),
                        adj_px(vout_data_raw[15:8],  ct_bin_v),
                        adj_px(vout_data_raw[7:0],   ct_bin_v)};
assign vout_data = display_valid ? vout_adj : 24'd0;

frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),   // 每行字数（RGB565 两像素/字：1280 像素/行 = 640 字）
    .FRAME_HEIGHT     (720)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (BUF2_ADDR),
    .read_addr_3       (BUF3_ADDR),
    .read_addr_index   (disp_buf_idx),
    .read_len          (FRAME_WORDS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),
    .o_vid_rd_empty    (vid_rd_empty),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (BUF2_ADDR),
    .write_addr_3      (BUF3_ADDR),
    .write_addr_index  (write_buf_idx),
    .write_len         (sd_card_write_len),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),

    .aud_read_req      (sd_aud_rd_req),
    .aud_read_req_ack  (sd_aud_rd_req_ack),
    .aud_read_finish   (sd_aud_rd_finish),
    .aud_read_addr_index(sd_aud_rd_addr_idx),
    .aud_read_len      ({1'b0, sd_aud_rd_len}),
    .aud_rd_en         (sd_aud_rd_en),
    .aud_rd_data       (sd_aud_rd_data)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
// RGB/DE 转 AXIS（模块名带 640x480 仅为历史遗留，逻辑分辨率无关）
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_vs          (vs),
    .I_de          (de),
    .I_rgb         (vout_data),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_all),
    .O_pulse (edid_trig)
);

// ===================== HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 1650       ),
    .HSA                    ( 40         ),
    .HFP                    ( 110        ),
    .HBP                    ( 220        ),
    .HACTIVE                ( 1280       ),
    .VTOTAL                 ( 750        ),
    .VSA                    ( 5          ),
    .VFP                    ( 5          ),
    .VBP                    ( 20         ),
    .VACTIVE                ( 720        ),
    .VIDEO_VIC              ( 4          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_all),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (aud_valid),
    .I_audio_left_data  (aud_l_v),     // 经 vol_gain 缩放（8=原始）
    .I_audio_right_data (aud_r_v),
    .I_acr_valid        (1'b1),
    .I_acr_cts          (20'd75000),   // 实际像素时钟 75MHz（PLL 从 50M 整数分频到不了 74.25），
                                       // CTS = 像素时钟kHz（N=6144、48kHz），保证音频音准
    .I_acr_n            (20'd6144),

    .O_video_locked     (hdmi_locked),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_all),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
