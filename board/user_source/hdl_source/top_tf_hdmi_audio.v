
// Comment out this macro and resynthesize to restore UART 'L' playlist dumps.
`define FPGA_LEAN_LIST_DIAG
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

    // GT911 touch panel on J1 pins 31/32 (open-drain I2C)
    inout                       gt911_scl,
    inout                       gt911_sda,

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
// D 的采样时钟：1=mem_clk 域（返回数据或请求地址），0=视频 FIFO 读出口。
localparam DUMP_AT_SDRAM_OUTPUT = 1'b1;
// 1=图像写口双流诊断（A 数据/B 地址）；0=正常写侧 A + D 触发的读侧 B。
localparam DUMP_WRITE_PORT = 1'b0;
// 在 mem_clk 域下，D 的 B 源：1=送进 SDRAM IP 的读地址，0=控制器返回数据。
localparam DUMP_READ_REQUEST_ADDR = 1'b0;
// The lean build omits UART 'L' snapshots; all playback and pixel paths stay on.
`ifdef FPGA_LEAN_LIST_DIAG
localparam ENABLE_LIST_DIAG_BUILD = 1'b0;
`else
localparam ENABLE_LIST_DIAG_BUILD = 1'b1;
`endif

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
wire [23:0] osd_rgb;
wire osd_de, osd_vs;
wire [23:0] cursor_rgb;
wire cursor_de, cursor_vs;
wire cursor_online, cursor_req_toggle, cursor_ack_toggle;
wire [10:0] cursor_mailbox_x;
wire [9:0] cursor_mailbox_y;
wire [1:0] osd_mode_cfg;
wire [3:0] vol_gray;
wire panel_show, panel_text_on, panel_band;
wire [3:0] panel_bri_level, panel_ct_level, panel_vol_level;
wire subtitle_text_on, subtitle_band;
wire signed [11:0] subtitle_ox;
wire [9:0] subtitle_oy;
wire [7:0] subtitle_char_index, subtitle_char_data, subtitle_active_len;
wire subtitle_text_changed;
wire subtitle_consume, subtitle_wr_en, subtitle_commit_toggle;
wire subtitle_ack_pulse, subtitle_ack_ok, subtitle_swap_ack;
wire [7:0] subtitle_wr_index, subtitle_wr_char, subtitle_commit_len;
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
wire [31:0] transition_word;
wire        de_word, vs_word;
wire [1:0]  transition_mode_cfg;
wire        transition_start_toggle, transition_target_buf;
wire [1:0]  transition_mode_latched;
wire        transition_prev_latched, transition_done_toggle;
wire        effect_active, effect_row_ready, effect_prev;
wire [1:0]  effect_active_mode;
wire [8:0]  effect_fade_alpha;
wire [10:0] effect_wipe_progress;
wire        line_req_toggle, line_ready_toggle;
wire [9:0]  line_num, line_rd_addr, line_wr_addr;
wire [20:0] line_base;
wire        line_rd_bank, line_wr_bank, line_wr_en;
wire [31:0] line_rd_data, line_wr_data;

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
wire        aud_tick;
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
wire        frame_sdr_rd_valid, transition_line_hold;
wire        mux_app_rd_en;
wire [ADDR_BITS-1:0] mux_app_rd_addr;
wire        frame_rd_busy, frame_wr_busy;
wire [8:0]  vid_fifo_words;
wire mem_rd_audio;
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

assign rst_all = rst_all_reg | wd_rst;

// ---- boot 看门狗（2026-10-03，根因经 UART 遥测确诊）----
// 现象：冷上电有概率黑屏/无图，复位键即愈；黑屏时 `S` 回读 state=0x0
//（SD 卡 init 未完成）——rst_all 释放仅等 PLL+20ms，SD 卡自身上电 boot
// 可长达秒级，init FSM 在卡未就绪时发出的 CMD0 进入不前进的状态，且整条
// boot 链（init→挂载→首图→音频）都是"一次性、无重试"设计。
// 自愈 = 自动替用户按复位键：rst_all 释放后 display_valid 迟迟不来，则
// 重新拉高 rst_all 一段时间（整体重跑，与手动复位等效；以太网不受影响
// ——eth_subsys 只上电复位一次）。限 3 次，防止真坏卡无限循环重置 UART。
reg [27:0] wd_cnt;             // 5s @ 50MHz = 250_000_000
reg [1:0]  wd_att;             // 已重试次数
reg        wd_rst = 1'b0;
reg        wd_armed = 1'b0;    // rst_all 释放后开始值守
reg        disp_v_s0, disp_v_s1;
wire       display_valid_clk;  // display_valid 的 clk 域视图
always @(posedge clk) begin
    if (!rst_n) begin
        disp_v_s0 <= 1'b0; disp_v_s1 <= 1'b0;
    end else begin
        disp_v_s0 <= display_valid;
        disp_v_s1 <= disp_v_s0;
    end
end
assign display_valid_clk = disp_v_s1;
always @(posedge clk or posedge rst_n) begin
    if (!rst_n) begin
        wd_cnt <= 0; wd_att <= 2'd0; wd_rst <= 1'b0; wd_armed <= 1'b0;
    end else if (wd_rst) begin
        // 复位脉冲保持 1ms（50_000 拍）后释放，系统整体重跑
        wd_cnt <= wd_cnt + 1'b1;
        if (wd_cnt >= 28'd50_000) begin
            wd_rst  <= 1'b0;
            wd_cnt  <= 28'd0;
        end
    end else if (rst_all_reg && !wd_armed) begin
        wd_armed <= 1'b1;                  // rst_all（基线部分）释放 → 开始值守
        wd_cnt   <= 28'd0;
    end else if (wd_armed && !display_valid_clk) begin
        if (wd_cnt >= 28'd250_000_000) begin
            wd_cnt <= 28'd0;
            if (wd_att < 2'd2) begin       // 最多 3 次尝试
                wd_att  <= wd_att + 1'b1;
                wd_rst  <= 1'b1;
            end
            // 3 次失败后放弃：真坏卡场景，保持黑屏，用户手动处理
        end else begin
            wd_cnt <= wd_cnt + 1'b1;
        end
    end
    // display_valid 一旦出现 → wd_armed 保持、计数冻结（不再干预运行期）
end

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
wire        bar_en;          // 音频脉动条开关（pulse_bar）
wire [19:0] sd_card_vrow_off;// 信箱行偏移（sd_card_bmp → frame_read_write）
wire [1:0]  bar_sens_gray;   // 脉动灵敏度 0..3（格雷码，跨时钟域）
wire        pl_dump_start_w; // 'L' 播放列表转储：ctrl_core 发起 → sd_card_bmp 吐包
wire [63:0] pl_pkt_w;
wire        pl_pkt_val_w;
wire [7:0]  ld_diag_w;       // 装载诊断快照 → ACK pkt[5]
wire [31:0] tap_word_w;      // 写侧分叉：图像发射字 → 以太网流
wire        tap_val_w;
wire        tap_end_w;       // 图像会话结束脉冲（eth 侧冲洗 FIFO 触发）
wire [31:0] tap2_word_w;     // 读侧 dump：显示读数据捕获 → 以太网流（type 0x0004）
wire        tap2_val_w;
wire        tap2_end_w;
wire        tap2_clk_w;
wire        tap_clk_eth, tap_val_eth, tap_end_eth;
wire [31:0] tap_word_eth;
wire        rdump_start_w;   // 'D' 手动读回触发（ctrl_core）
wire        dmp_trig_w;      // 读回捕获触发（sd_card_clk 域脉冲，'D' 或装载自动）

ctrl_core #(
    .VK_PULSE_CYC   (10_000_000)       // 100ms，须明显大于 sd_card_bmp 的 50ms 去抖窗
) ctrl_core_m0(
    .clk            (sd_card_clk),
    .rst            (rst_all),
    .cmd            (cmd_byte),
    .cmd_val        (cmd_val_w),
    .subtitle_consume (subtitle_consume),
    .subtitle_ack_pulse (subtitle_ack_pulse),
    .subtitle_ack_ok (subtitle_ack_ok),
    .vk_next_n      (vk_next_n),
    .vk_auto_n      (vk_auto_n),
    .vk_prev_n      (vk_prev_n),
    .tx_req         (tx_req_w),
    .tx_pkt         (tx_pkt_w),
    .vol_gain       (vol_gain),
    .auto_period_s  (auto_period_s),
    .transition_mode (transition_mode_cfg),
    .osd_mode       (osd_mode_cfg),
    .vol_gray       (vol_gray),
    .bri_gray       (bri_gray),
    .ct_gray        (ct_gray),
    .bar_en         (bar_en),
    .bar_sens_gray  (bar_sens_gray),
    .state_code     (state_code),
    .dbg_fat_state  (dbg_fat_state),
    .flag_a         ({video_pll_lock, sys_pll_lock, Sdr_init_done, display_valid}),
    .flag_b         ({hdmi_locked, dbg_fat_err, disp_buf_idx[1], disp_buf_idx[0]}),
    .dbg_underrun   (dbg_underrun),
    .img_idx        (img_idx_w),
    .img_wav        (img_wav_w),
    .auto_on        (auto_play_w),
    .pl_pkt         (pl_pkt_w),
    .pl_pkt_val     (pl_pkt_val_w),
    .pl_dump_start  (pl_dump_start_w),
    .rdump_start    (rdump_start_w),
    .ld_diag        (ld_diag_w)
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
    .tx_pkt              (eth_tx_pkt_r),
    .sys_rst             (rst_all),
    .tap_clk             (tap_clk_eth),
    .tap_val             (tap_val_eth),
    .tap_word            (tap_word_eth),
    .tap_end             (tap_end_eth),
    .tap2_clk            (tap2_clk_w),
    .tap2_val            (tap2_val_w),
    .tap2_word           (tap2_word_w),
    .tap2_end            (tap2_end_w)
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

subtitle_cmd u_subtitle_cmd (
    .clk (sd_card_clk), .rst (rst_all),
    .cmd (cmd_byte), .cmd_val (cmd_val_w),
    .swap_ack_toggle_raw (subtitle_swap_ack),
    .consume_cmd (subtitle_consume),
    .wr_en (subtitle_wr_en), .wr_index (subtitle_wr_index),
    .wr_char (subtitle_wr_char),
    .commit_toggle (subtitle_commit_toggle),
    .commit_len (subtitle_commit_len),
    .ack_pulse (subtitle_ack_pulse), .ack_ok (subtitle_ack_ok)
);

// 应答 toggle：每条 ctrl_core 应答翻转一次（eth_front 检测变化取包）。
// 发送数据与 toggle 同拍锁存并**保持**：tx_req/tx_pkt 是 1 拍脉冲，eth_front 的
// toggle 跨域同步晚 ~3 拍才锁存——直接给 tx_pkt_w 会在脉冲回落后锁到 ACK 兜底
// 包（'L' 转储 11 条全变 ACK 的根因；串口同域立即取用从未暴露）。
reg  [63:0] eth_tx_pkt_r;
always @(posedge sd_card_clk)
    if (tx_req_w) begin
        eth_tx_tog   <= ~eth_tx_tog;
        eth_tx_pkt_r <= tx_pkt_w;    // tx_req_w=1 时 tx_pkt_w 恰好有效，同域无竞争
    end

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

// GT911 first stage: discover 0x5D/0x14, poll a single finger and move a
// relative pointer. No INT/RST pin or touch-triggered playback action yet.
gt911_trackpad u_gt911_trackpad (
    .clk (sd_card_clk), .rst (rst_all),
    .scl (gt911_scl), .sda (gt911_sda),
    .cursor_ack_toggle (cursor_ack_toggle),
    .cursor_req_toggle (cursor_req_toggle),
    .cursor_mailbox_x (cursor_mailbox_x),
    .cursor_mailbox_y (cursor_mailbox_y),
    .online (cursor_online),
    .touch_report (), .touch_down (), .cursor_x (), .cursor_y ()
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
    .SCAN_TARGET_COUNT (3'd4),
    .ENABLE_LIST_DIAG  (ENABLE_LIST_DIAG_BUILD)
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
    .effect_mode       (transition_mode_cfg),
    .transition_start_toggle (transition_start_toggle),
    .transition_target_buf (transition_target_buf),
    .transition_mode_latched (transition_mode_latched),
    .transition_prev_latched (transition_prev_latched),
    .transition_done_toggle (transition_done_toggle),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .write_len         (sd_card_write_len),
    .o_wr_vrow_off     (sd_card_vrow_off),
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
    .aud_tick          (aud_tick),
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
    .dbg_fat_err       (dbg_fat_err),
    .pl_dump_start     (pl_dump_start_w),
    .pl_pkt            (pl_pkt_w),
    .pl_pkt_val        (pl_pkt_val_w),
    .ld_diag           (ld_diag_w),
    .tap_word          (tap_word_w),
    .tap_val           (tap_val_w),
    .tap_end           (tap_end_w),
    .rdump_start       (rdump_start_w),
    .dmp_trig          (dmp_trig_w)
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

transition_ctrl #(
    .BUF0_ADDR (BUF0_ADDR[20:0]),
    .BUF1_ADDR (BUF1_ADDR[20:0])
) transition_ctrl_m0 (
    .video_clk (video_clk), .rst (rst_all),
    .start_toggle_raw (transition_start_toggle),
    .target_buf_raw (transition_target_buf),
    .mode_raw (transition_mode_latched),
    .direction_prev_raw (transition_prev_latched),
    .done_toggle (transition_done_toggle),
    .de_word (de_word), .vs_word (vs_word),
    .line_req_toggle (line_req_toggle), .line_num (line_num),
    .line_base (line_base), .line_ready_toggle_raw (line_ready_toggle),
    .line_rd_bank (line_rd_bank), .line_rd_addr (line_rd_addr),
    .row_ready (effect_row_ready), .effect_active (effect_active),
    .active_mode (effect_active_mode), .direction_prev (effect_prev),
    .fade_alpha (effect_fade_alpha), .wipe_progress (effect_wipe_progress)
);

transition_line_buf transition_line_buf_m0 (
    .mem_clk (ext_mem_clk), .wr_en (line_wr_en),
    .wr_bank (line_wr_bank), .wr_addr (line_wr_addr),
    .wr_data (line_wr_data), .video_clk (video_clk),
    .rd_bank (line_rd_bank), .rd_addr (line_rd_addr),
    .rd_data (line_rd_data)
);

transition_blender transition_blender_m0 (
    .video_clk (video_clk), .rst (rst_all),
    .line_de (de_word), .word_pop (video_read_en),
    .old_word (video_read_data), .new_word (line_rd_data),
    .effect_active (effect_active), .row_ready (effect_row_ready),
    .effect_mode (effect_active_mode), .direction_prev (effect_prev),
    .fade_alpha (effect_fade_alpha),
    .wipe_progress (effect_wipe_progress), .mixed_word (transition_word)
);

video_delay #(.MIX_PIPELINE(1)) video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_en           (video_read_en),
    .read_data         (transition_word),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .de_word           (de_word),
    .vs_word           (vs_word),
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

// Genuine selected-bin DFT of the played PCM. The present WAV is 24 kHz,
// 8-bit mono expanded to 24-bit HDMI words; take one of each repeated pair.
// A future native 24-bit source can use the same analyzer input.
wire [127:0] spectrum_levels;
wire spectrum_done_toggle, spectrum_ack_toggle;
wire [23:0] spectrum_rgb;
wire spectrum_hit, spectrum_shade;
spectrum_dft u_spectrum_dft (
    .clk (sd_card_clk), .rst (rst_all),
    .aud_tick (aud_tick), .aud_valid (aud_valid),
    .pcm ($signed(aud_l_v)), .sens_gray (bar_sens_gray),
    .ack_toggle (spectrum_ack_toggle),
    .levels (spectrum_levels), .done_toggle (spectrum_done_toggle)
);
spectrum_overlay u_spectrum_overlay (
    .video_clk (video_clk), .rst (rst_all), .de (de), .vs (vs),
    .enable_raw (bar_en),
    .levels_raw (spectrum_levels), .done_toggle_raw (spectrum_done_toggle),
    .ack_toggle (spectrum_ack_toggle),
    .shade (spectrum_shade), .bar_hit (spectrum_hit), .bar_rgb (spectrum_rgb)
);
wire [23:0] base_video = display_valid ? vout_adj : 24'd0;
wire [23:0] shaded_video = {1'b0, base_video[23:17],
                            1'b0, base_video[15:9],
                            1'b0, base_video[7:1]};
assign vout_data = spectrum_hit ? spectrum_rgb :
                   spectrum_shade ? shaded_video : base_video;

subtitle_store u_subtitle_store (
    .sd_clk (sd_card_clk), .video_clk (video_clk), .rst (rst_all),
    .wr_en (subtitle_wr_en), .wr_index (subtitle_wr_index),
    .wr_char (subtitle_wr_char),
    .commit_toggle (subtitle_commit_toggle),
    .commit_len (subtitle_commit_len),
    .swap_ack_toggle (subtitle_swap_ack),
    .vs (vs), .rd_index (subtitle_char_index),
    .rd_char (subtitle_char_data), .active_len (subtitle_active_len),
    .text_changed_pulse (subtitle_text_changed)
);

subtitle_scroll u_subtitle_scroll (
    .video_clk (video_clk), .rst (rst_all), .vs (vs),
    .text_changed_pulse (subtitle_text_changed),
    .text_len (subtitle_active_len),
    .ox (subtitle_ox), .oy (subtitle_oy)
);

subtitle_text_renderer u_subtitle_renderer (
    .video_clk (video_clk), .rst (rst_all), .de (de), .vs (vs),
    .ox (subtitle_ox), .oy (subtitle_oy),
    .text_len (subtitle_active_len),
    .char_index (subtitle_char_index), .char_data (subtitle_char_data),
    .text_on (subtitle_text_on), .in_band (subtitle_band)
);

osd_visibility u_osd_visibility (
    .video_clk (video_clk), .rst (rst_all), .vs (vs),
    .mode_raw (osd_mode_cfg),
    .bri_gray_raw (bri_gray), .ct_gray_raw (ct_gray),
    .vol_gray_raw (vol_gray), .show_panel (panel_show),
    .brightness_level (panel_bri_level),
    .contrast_level (panel_ct_level),
    .volume_level (panel_vol_level)
);

osd_panel_levels u_osd_panel (
    .video_clk (video_clk), .rst (rst_all), .de (de), .vs (vs),
    .brightness_level (panel_bri_level),
    .contrast_level (panel_ct_level),
    .volume_level (panel_vol_level),
    .text_on (panel_text_on), .in_band (panel_band)
);

osd_composite u_osd_composite (
    .video_clk (video_clk), .rst (rst_all),
    .video_in (vout_data), .de_in (de), .vs_in (vs),
    .panel_show (panel_show), .panel_text_on (panel_text_on),
    .panel_band (panel_band),
    .subtitle_text_on (subtitle_text_on),
    .subtitle_band (subtitle_band),
    .video_out (osd_rgb), .de_out (osd_de), .vs_out (osd_vs)
);

// Cursor is HDMI-only. PC pixel probes still observe the pre-OSD frame data.
gt911_cursor_overlay u_gt911_cursor (
    .video_clk (video_clk), .rst (rst_all),
    .video_in (osd_rgb), .de_in (osd_de), .vs_in (osd_vs),
    .online_raw (cursor_online),
    .cursor_req_toggle (cursor_req_toggle),
    .cursor_mailbox_x (cursor_mailbox_x),
    .cursor_mailbox_y (cursor_mailbox_y),
    .cursor_ack_toggle (cursor_ack_toggle),
    .video_out (cursor_rgb), .de_out (cursor_de), .vs_out (cursor_vs)
);

// ================== 读侧 dump 捕获窗（video_clk 域，第二十一轮）==================
// 触发（'D' 或装载提交自动）后捕获一帧。保留 video FIFO 出口的旧探针；
// DUMP_AT_SDRAM_OUTPUT=1 时取 mem_clk 域，具体选控制器返回或读请求地址
// 由 DUMP_READ_REQUEST_ADDR 决定；上轮的 FIFO 出口探针仍保留。
reg         cap_tog;                    // sd_card_clk 脉冲 → toggle
// display_valid 门控：装载提交瞬间显示流水线尚未起帧（首图提交拍上还是旧值
// 0），那时开窗只能抓到启动期零星几个字（105 字黑帧的根因）
always @(posedge sd_card_clk or posedge rst_all)
    if (rst_all) cap_tog <= 1'b0;
    else if (dmp_trig_w && display_valid) cap_tog <= ~cap_tog;
reg  cap_s0, cap_s1, cap_s2;            // video_clk 域同步 + 边沿
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        cap_s0 <= 1'b0; cap_s1 <= 1'b0; cap_s2 <= 1'b0;
    end else begin
        cap_s0 <= cap_tog; cap_s1 <= cap_s0; cap_s2 <= cap_s1;
    end
end
wire cap_req_v = (cap_s1 != cap_s2);
reg  cap_win, cap_pend, cap_end_r;
// vs_0/vs_0_d 在下方 video_clk 域诊断块维护，此处复用其值（同域读，无竞争）
wire vs_rise_v = vs_0 && !vs_0_d;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        cap_win <= 1'b0; cap_pend <= 1'b0; cap_end_r <= 1'b0;
    end else begin
        if (cap_req_v)
            cap_pend <= 1'b1;           // 窗已开期间的重复触发也记一笔
        cap_end_r <= 1'b0;
        if (vs_rise_v) begin
            if (cap_pend) begin
                cap_win  <= 1'b1;       // vsync 开窗：圈一帧
                cap_pend <= 1'b0;
            end
            else if (cap_win) begin
                cap_win   <= 1'b0;      // 下一 vsync 关窗
                cap_end_r <= 1'b1;      // 通知 eth 侧冲洗 FIFO
            end
        end
    end
end
// rfifo 的 dout 在 read_en 上升沿之后才更新；有效脉冲延后一拍，
// 让以太网 FIFO 采到刚弹出的字，而非上一个字。
reg tap2_val_r;
always @(posedge video_clk or posedge rst_all)
    if (rst_all) tap2_val_r <= 1'b0;
    else         tap2_val_r <= cap_win && video_read_en;
wire        mem_tap_val, mem_tap_end;
wire [31:0] mem_tap_word;
mem_return_dump #(.WORDS(FRAME_WORDS)) u_mem_return_dump (
    .mem_clk      (ext_mem_clk),
    .rst          (rst_all),
    .start_tog    (cap_tog),
    .video_ack    (video_read_req_ack),
    .rd_valid     (DUMP_READ_REQUEST_ADDR ? App_rd_en : frame_sdr_rd_valid),
    .rd_word      (DUMP_READ_REQUEST_ADDR ? {11'd0, App_rd_addr} : Sdr_rd_dout),
    .rd_audio     (mem_rd_audio),
    .tap_val      (mem_tap_val),
    .tap_word     (mem_tap_word),
    .tap_end      (mem_tap_end)
);
wire app_img_val, app_img_end;
wire [31:0] app_img_data, app_img_addr;
write_port_probe u_write_port_probe (
    .src_clk   (sd_card_clk), .mem_clk  (ext_mem_clk), .rst(rst_all),
    .src_val   (tap_val_w),   .src_end  (tap_end_w),
    .wr_en     (App_wr_en),   .wr_data  (App_wr_din),
    .wr_addr   (App_wr_addr), .tap_val  (app_img_val),
    .tap_data  (app_img_data), .tap_addr(app_img_addr),
    .tap_end   (app_img_end)
);
assign tap_clk_eth  = DUMP_WRITE_PORT ? ext_mem_clk : sd_card_clk;
assign tap_val_eth  = DUMP_WRITE_PORT ? app_img_val : tap_val_w;
assign tap_word_eth = DUMP_WRITE_PORT ? app_img_data : tap_word_w;
assign tap_end_eth  = DUMP_WRITE_PORT ? app_img_end : tap_end_w;
assign tap2_clk_w  = DUMP_WRITE_PORT ? ext_mem_clk :
                     (DUMP_AT_SDRAM_OUTPUT ? ext_mem_clk : video_clk);
assign tap2_val_w  = DUMP_WRITE_PORT ? app_img_val :
                     (DUMP_AT_SDRAM_OUTPUT ? mem_tap_val : tap2_val_r);
assign tap2_word_w = DUMP_WRITE_PORT ? app_img_addr :
                     (DUMP_AT_SDRAM_OUTPUT ? mem_tap_word : video_read_data);
assign tap2_end_w  = DUMP_WRITE_PORT ? app_img_end :
                     (DUMP_AT_SDRAM_OUTPUT ? mem_tap_end : cap_end_r);

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
    .Sdr_rd_en         (frame_sdr_rd_valid),
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
    .o_mem_rd_audio    (mem_rd_audio),
    .o_mem_rd_busy     (frame_rd_busy),
    .o_mem_wr_busy     (frame_wr_busy),
    .o_vid_fifo_words  (vid_fifo_words),
    .line_hold         (transition_line_hold),

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
    .vrow_off          (sd_card_vrow_off),
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

transition_line_read transition_line_read_m0 (
    .mem_clk (ext_mem_clk), .rst (rst_all),
    .sdr_init_done (Sdr_init_done), .sdr_busy (Sdr_busy),
    .sdr_refresh (Sdr_init_ref_vld),
    .line_req_toggle (line_req_toggle), .line_num (line_num),
    .line_base (line_base), .line_ready_toggle (line_ready_toggle),
    .frame_rd_en (App_rd_en), .frame_rd_addr (App_rd_addr),
    .frame_wr_en (App_wr_en), .frame_rd_busy (frame_rd_busy),
    .frame_wr_busy (frame_wr_busy), .video_fifo_words (vid_fifo_words),
    .line_hold (transition_line_hold),
    .app_rd_en (mux_app_rd_en), .app_rd_addr (mux_app_rd_addr),
    .sdr_rd_valid (Sdr_rd_en), .sdr_rd_data (Sdr_rd_dout),
    .frame_rd_valid (frame_sdr_rd_valid),
    .line_wr_en (line_wr_en), .line_wr_data (line_wr_data),
    .line_wr_addr (line_wr_addr), .line_wr_bank (line_wr_bank)
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
    .App_rd_en         (mux_app_rd_en),
    .App_rd_addr       (mux_app_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
// RGB/DE 转 AXIS（模块名为历史遗留；行结束位置按当前 1280 宽设置）
video_rgb_to_axis_640x480 #(.H_ACTIVE(1280)) u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_vs          (cursor_vs),
    .I_de          (cursor_de),
    .I_rgb         (cursor_rgb),
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

// 图像写会话的被动端口探针。源侧首字武装（不依赖写端地址），随后在 mem_clk
// 域采样与 SDRAM IP 完全同拍的 App_wr_en/addr/din；会话结束由源侧 tap_end
// 跨域送达，确保最后一个写突发已结束。两个以太网流共享此 val/end：
// type 3 发全量数据，type 4 经 eth_front 的 3:1 抽样发对应地址。
module write_port_probe(
    input  wire        src_clk,
    input  wire        mem_clk,
    input  wire        rst,
    input  wire        src_val,
    input  wire        src_end,
    input  wire        wr_en,
    input  wire [31:0] wr_data,
    input  wire [20:0] wr_addr,
    output wire        tap_val,
    output wire [31:0] tap_data,
    output wire [31:0] tap_addr,
    output wire        tap_end
);
    reg active_src;
    always @(posedge src_clk or posedge rst)
        if (rst)          active_src <= 1'b0;
        else if (src_end) active_src <= 1'b0;
        else if (src_val) active_src <= 1'b1;
    reg m0, m1, m2, prev;
    always @(posedge mem_clk or posedge rst) begin
        if (rst) begin
            m0 <= 1'b0; m1 <= 1'b0; m2 <= 1'b0; prev <= 1'b0;
        end else begin
            m0 <= active_src; m1 <= m0; m2 <= m1; prev <= m2;
        end
    end
    assign tap_val = m2 && wr_en;
    assign tap_data = wr_data;
    assign tap_addr = {11'd0, wr_addr};
    assign tap_end = prev && !m2;
endmodule

// 被动 mem_clk 采样窗：上层可接 SDRAM 控制器返回，或接 App_rd 请求地址。
// D 到达后等待下一次视频读会话 ack，收一帧有效视频字；音频字被排除。
// 异常会话在下一次 ack 冲洗，避免残字污染下一帧。
module mem_return_dump #(
    parameter integer WORDS = 460800
)(
    input  wire        mem_clk,
    input  wire        rst,
    input  wire        start_tog,
    input  wire        video_ack,
    input  wire        rd_valid,
    input  wire [31:0] rd_word,
    input  wire        rd_audio,
    output wire        tap_val,
    output wire [31:0] tap_word,
    output reg         tap_end
);
    reg start_s0, start_s1, start_s2;
    reg ack_d, pending, active;
    reg [18:0] word_count;
    wire start_pulse = start_s1 != start_s2;
    wire ack_rise = video_ack && !ack_d;
    wire take_word = active && rd_valid && !rd_audio;
    assign tap_val = take_word;
    assign tap_word = rd_word;

    always @(posedge mem_clk or posedge rst) begin
        if (rst) begin
            start_s0 <= 1'b0; start_s1 <= 1'b0; start_s2 <= 1'b0;
            ack_d <= 1'b0; pending <= 1'b0; active <= 1'b0;
            word_count <= 19'd0; tap_end <= 1'b0;
        end else begin
            start_s0 <= start_tog; start_s1 <= start_s0; start_s2 <= start_s1;
            ack_d <= video_ack;
            tap_end <= 1'b0;
            if (start_pulse)
                pending <= 1'b1;
            if (active) begin
                if (take_word) begin
                    if (word_count == WORDS - 1) begin
                        active <= 1'b0;
                        tap_end <= 1'b1;
                    end else
                        word_count <= word_count + 19'd1;
                end
                if (ack_rise) begin
                    active <= 1'b0;
                    tap_end <= 1'b1;
                end
            end else if (pending && ack_rise) begin
                active <= 1'b1;
                pending <= 1'b0;
                word_count <= 19'd0;
            end
        end
    end
endmodule
