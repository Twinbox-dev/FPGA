
module top(
    input                       clk,
    input                       rst_n,

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
    inout                       gt911_sda
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
parameter MEDIA_PEER_IP = 32'hc0a88903;  // 媒体板 UDP 目标地址
parameter MEDIA_PEER_PORT = 16'h0001;    // 媒体板正式应用端口
// Runtime CV effect reset/default: 0 bypass, 1 grayscale, 2 binary,
// 3 Sobel, 4 sharpen, 5 moving snow.
parameter CV_EFFECT_MODE = 0;
// Product D remains the media-board SD snapshot. These two blocks are only
// for acceptance diagnostics (scan digest 0x4c / injected cursor 0x4b).
// Set to 1 in an isolated diagnostic build to restore both without removing
// any historical probe RTL or tests from the repository.
parameter DISPLAY_DIAGNOSTICS = 0;
// First product video profile; these values must match the PC sender.
// HDMI raster remains 1280x720. Video temporarily owns the display.
parameter DIRECT_VIDEO_WIDTH = 720;
parameter DIRECT_VIDEO_HEIGHT = 360;
// Video acceptance counters/readback CRC are optional diagnostics. Product
// CREDIT/READY/NACK and normal media-board S/ACK control remain enabled.
parameter DIRECT_VIDEO_STATUS = 0;
parameter DIRECT_VIDEO_ROWS = 512;
// Temporary full-product diagnostic: sticky link stages on the existing LEDs.
// Restore 0 before accepting the normal product baseline.
parameter VIDEO_LINK_DIAGNOSTICS = 0;
// First integration stage approved by the user. Source and regressions stay
// available; restore these independently after the video baseline is verified.
parameter PRODUCT_CV_ENABLED = 0;
parameter PRODUCT_SPECTRUM_ENABLED = 0;

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
wire [23:0] cv_data;
wire cv_de, cv_vs;
wire [23:0] osd_rgb;
wire osd_de, osd_vs;
wire [23:0] cursor_rgb;
wire cursor_de, cursor_vs;
wire cursor_online, cursor_req_toggle, cursor_ack_toggle;
wire [10:0] cursor_mailbox_x;
wire [9:0] cursor_mailbox_y;
wire [1:0] osd_mode_cfg;
wire [2:0] cv_effect_mode_cfg;
wire [2:0] cv_effect_gray_cfg;
wire [3:0] vol_gray;
wire panel_show, panel_text_on, panel_band;
wire [23:0] panel_text_rgb;
wire [3:0] panel_bri_level, panel_ct_level, panel_vol_level;
wire [11:0] panel_image_width,panel_image_height;
wire subtitle_text_on, subtitle_band;
wire [23:0] subtitle_text_rgb;
wire signed [12:0] subtitle_ox;
wire [9:0] subtitle_oy;
wire [7:0] subtitle_char_index, subtitle_char_data, subtitle_active_len;
wire subtitle_text_changed;
wire [6:0] subtitle_font_ascii, panel_font_ascii;
wire [3:0] subtitle_font_row, panel_font_row;
wire [7:0] subtitle_font_row_data, panel_font_row_data;
wire subtitle_consume = 1'b0;
wire subtitle_ack_pulse = 1'b0;
wire subtitle_ack_ok = 1'b0;
reg subtitle_wr_en, subtitle_commit_toggle;
wire subtitle_swap_ack;
reg [7:0] subtitle_wr_index, subtitle_wr_char, subtitle_commit_len;
wire        display_valid;

wire [3:0]  state_code;
wire [4:0]  img_idx_w;        // 当前媒体图索引（显示状态/数码管）
wire [11:0] displayed_image_width, displayed_image_height;
wire        img_wav_w;        // 当前图是否配同名 WAV
reg         auto_play_w;      // 通过远端媒体元数据同步的自动轮播状态
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
wire        frame_commit_pulse;
wire        effect_active, effect_row_ready, effect_prev;
wire [1:0]  effect_active_mode;
wire [8:0]  effect_fade_alpha;
wire [10:0] effect_wipe_progress;
wire        line_req_toggle, line_ready_toggle;
wire [9:0]  line_num, line_rd_addr, line_wr_addr;
wire [9:0]  transition_row_words;
wire [20:0] line_base;
wire        effect_view_active;
wire [1:0]  effect_view_layout,effect_view_window;
wire        line_rd_bank, line_wr_bank, line_wr_en;
wire [31:0] line_rd_data, line_wr_data;

wire        media_write_en;
wire [31:0] media_write_data;
wire        media_write_req;
wire        media_write_req_ack;
wire        media_write_ready;
wire [20:0] media_write_len;
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
wire [9:0] audio_read_fifo_words;
wire audio_source_toggle;
wire [1:0] audio_buffer_index;
wire [20:0] audio_buffer_length;
wire [31:0] audio_sample_count_out;
wire audio_read_req, audio_read_req_ack, audio_read_finish, audio_read_en;
wire [1:0] audio_read_index;
wire [20:0] audio_read_length;
wire [31:0] audio_read_data;
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

// Output timing is fixed to 1280x720 / VIC 4, and the top does not consume
// EDID data. The EDID read engine can therefore remain idle in this candidate.
wire        edid_trig = 1'b0;
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
reg [30:0] wd_cnt;             // 30s allowance for media-board scan and first frame transfer
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
        if (wd_cnt >= 31'd50_000) begin
            wd_rst  <= 1'b0;
            wd_cnt  <= 31'd0;
        end
    end else if (rst_all_reg && !wd_armed) begin
        wd_armed <= 1'b1;                  // rst_all（基线部分）释放 → 开始值守
        wd_cnt   <= 28'd0;
    end else if (wd_armed && !display_valid_clk) begin
        if (wd_cnt >= 31'd1_500_000_000) begin
            wd_cnt <= 31'd0;
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

// ===================== 显示设置（由媒体板通过正式控制协议下发）=====================
wire touch_swipe_next, touch_swipe_prev;
reg [7:0]   media_cmd_byte;
reg         media_cmd_toggle;
// 以太网（RGMII ↔ 板载 RTL8211 PHY）
// ⚠ 这些名字**已经是模块端口（ANSI 端口自带线网）**，不能再 wire 声明一遍
//（TD 报 HDL-5372 "redeclaration of ANSI port"）。
wire [3:0]  vol_gain;
wire [3:0]  brightness_value, contrast_value;
wire [1:0]  sensitivity_value;
reg         set_valid_sd;
reg [7:0]   set_op_sd, set_value_sd;
wire [3:0]  auto_period_s;   // 轮播周期（秒），ctrl_core 可调
wire [3:0]  bri_gray;        // 亮度档位（格雷码，跨时钟域到 video_clk）
wire [3:0]  ct_gray;         // 对比度档位（格雷码，跨时钟域到 video_clk）
wire        bar_en;          // 音频脉动条开关（pulse_bar）
wire [19:0] media_row_offset; // Full-frame network transfer uses row offset zero.
wire [1:0]  bar_sens_gray;   // 脉动灵敏度 0..3（格雷码，跨时钟域）

ctrl_core #(
    .VK_PULSE_CYC   (10_000_000)
) ctrl_core_m0(
    .clk            (sd_card_clk),
    .rst            (rst_all),
    .cmd            (8'd0),
    .cmd_val        (1'b0),
    .set_valid      (set_valid_sd),
    .set_op         (set_op_sd),
    .set_value      (set_value_sd),
    .touch_next     (1'b0),
    .touch_prev     (1'b0),
    .subtitle_consume (subtitle_consume),
    .subtitle_ack_pulse (subtitle_ack_pulse),
    .subtitle_ack_ok (subtitle_ack_ok),
    .vk_next_n      (),
    .vk_auto_n      (),
    .vk_prev_n      (),
    .tx_req         (),
    .tx_pkt         (),
    .vol_gain       (vol_gain),
    .brightness_value (brightness_value),
    .contrast_value (contrast_value),
    .sensitivity_value (sensitivity_value),
    .auto_period_s  (auto_period_s),
    .transition_mode (transition_mode_cfg),
    .osd_mode       (osd_mode_cfg),
    .cv_effect_mode (cv_effect_mode_cfg),
    .cv_effect_gray (cv_effect_gray_cfg),
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
    .pl_pkt         (64'd0),
    .pl_pkt_val     (1'b0),
    .pl_dump_start  (),
    .rdump_start    (),
    .ld_diag        (8'd0)
);

always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        media_cmd_byte <= 8'd0;
        media_cmd_toggle <= 1'b0;
    end else if (touch_swipe_next) begin
        media_cmd_byte <= 8'h4e;
        media_cmd_toggle <= ~media_cmd_toggle;
    end else if (touch_swipe_prev) begin
        media_cmd_byte <= 8'h50;
        media_cmd_toggle <= ~media_cmd_toggle;
    end
end

// ===================== 显示板以太网（正式媒体链路）=====================
wire        eth_app_clk;
wire [7:0]  eth_rx_data;
wire        eth_rx_valid;
wire [7:0]  eth_stack_rx_data;
wire        eth_stack_rx_valid, eth_stack_rx_start, eth_stack_rx_end;
wire [15:0] eth_stack_rx_length;
wire [5:0] eth_link_trace;
wire        video_rx_valid, video_rx_start, video_rx_end;
wire [7:0]  video_rx_data;
wire [15:0] video_rx_length;
wire        video_row_begin, video_row_stream_start, video_session_request;
wire [15:0] video_row_frame_id, video_row_sequence;
wire [8:0]  video_row_index;
wire        video_pixel_write, video_row_commit, video_row_reject;
wire [9:0]  video_pixel_index;
wire [15:0] video_pixel_data;
wire        video_nack_valid, video_credit_update;
wire [15:0] video_nack_sequence, video_credit_next_sequence;
wire [7:0]  video_free_row_credits;
wire [31:0] video_accepted_rows, video_rejected_rows, video_duplicate_rows;
wire [31:0] video_underflow_lines;
wire [31:0] video_parser_accepted,video_parser_rejected;
reg [31:0] video_underflow_gray;
always @(posedge video_clk or posedge rst_all)begin
    if(rst_all)video_underflow_gray<=0;
    else video_underflow_gray<={16'd0,(video_underflow_lines[15:0]^(video_underflow_lines[15:0]>>1))};
end
wire        video_stream_active, video_stream_ready;
wire        video_session_busy;
wire [15:0] video_active_base_sequence, video_consumed_sequence;
wire [31:0] video_word_data;
wire        video_word_valid, video_line_available;
wire [9:0]  video_scan_y;
wire [10:0] video_scan_x;
wire        video_frame_start, video_line_start, video_line_done;
wire        video_mode_active;
wire video_memory_grant,video_hold_old,video_memory_active,video_memory_idle;
wire [20:0] video_scratch_base;
wire video_wr_en,video_rd_en;wire [20:0] video_wr_addr,video_rd_addr;wire [31:0] video_wr_data;
wire video_lease_done,video_lease_fault;
wire video_ready_event;wire [15:0] video_ready_sequence,video_ready_frame;
wire video_missing, audio_missing;reg [1:0] audio_missing_sync;
always @(posedge eth_app_clk or posedge rst_all)
 if(rst_all)audio_missing_sync<=0;else audio_missing_sync<={audio_missing_sync[0],audio_missing};
wire direct_audio_valid;wire [23:0] direct_audio_sample;wire [95:0] direct_audio_stats;
wire [15:0] video_crc_seed,video_crc_expected;wire [95:0] video_hybrid_stats,video_readback_stats;
wire view_transaction_busy;
reg video_request;reg [2:0] video_done_sync;reg video_done_seen;
assign video_session_busy=video_request||video_stream_active;
always @(posedge eth_app_clk or posedge rst_all)begin
 if(rst_all)begin video_request<=0;video_done_sync<=0;video_done_seen<=0;end
 else begin
  video_done_sync<={video_done_sync[1:0],video_lease_done};
  if(video_done_sync[2]!=video_done_seen)begin video_done_seen<=video_done_sync[2];video_request<=0;end
  if(video_session_request)video_request<=1;
 end
end
wire        media_packet_request, media_packet_valid, media_packet_ack, media_packet_ready;
wire [7:0]  media_packet_data;
wire [15:0] media_packet_length;
wire        media_ready_request;
wire        media_frame_begin_valid;
wire [15:0] media_frame_id;
wire [4:0]  media_source_index;
wire [7:0]  media_image_flags;
wire [20:0] media_total_words;
wire [11:0] media_image_width, media_image_height;
wire [7:0]  media_image_layout, media_image_window;
wire [15:0] media_image_generation;
wire        media_stream_start, media_stream_is_audio;
wire [8:0]  media_stream_word_count;
wire [31:0] media_stream_word_data;
wire        media_stream_word_valid, media_stream_word_ready, media_stream_done;
wire        media_raw_stream_ready;
wire        media_padded_stream_start, media_padded_stream_audio;
wire [8:0]  media_padded_stream_count;
wire [31:0] media_padded_stream_data;
wire        media_padded_stream_valid, media_padded_stream_ready, media_padded_stream_done;
wire        media_pad_frame_done;
wire        media_frame_end_valid, media_frame_end_ok;
wire [3:0]  media_frame_end_reason;
wire [15:0] media_frame_end_id;
wire        media_audio_begin_valid;
wire [15:0] media_audio_frame_id;
wire [31:0] media_audio_sample_count;
wire        media_audio_end_valid, media_audio_end_ok;
wire [3:0]  media_audio_end_reason;
wire [15:0] media_audio_end_id;
wire        media_protocol_error_toggle;
wire        media_image_result_valid, media_audio_result_valid;
wire [7:0]  media_image_result_code, media_audio_result_code;
wire        media_auto_play_status;
wire        media_control_ack_valid;
wire [7:0]  media_control_ack_sequence, media_control_ack_op;
wire [7:0]  media_control_ack_status, media_control_ack_value;
wire        media_status_valid;
wire [63:0] media_status_payload;
wire        media_set_toggle_eth;
wire [7:0]  media_set_op_eth, media_set_value_eth;
wire        media_status_req_valid_eth;
wire [7:0]  media_status_sequence_eth;
reg         status_req_toggle_eth;
wire        media_control_ack_valid_rx;
wire [7:0]  media_control_ack_sequence_rx, media_control_ack_op_rx;
wire [7:0]  media_control_ack_status_rx, media_control_ack_value_rx;
wire        subtitle_write_toggle_eth;
wire [7:0]  subtitle_write_index_eth, subtitle_write_char_eth;
wire        subtitle_commit_toggle_eth;
wire [7:0]  subtitle_commit_length_eth, subtitle_commit_sequence_eth;
reg [2:0]   set_toggle_sync_sd, status_req_sync_sd;
reg [2:0]   subtitle_write_sync_sd, subtitle_commit_sync_sd, subtitle_store_ack_sync;
reg         set_toggle_seen_sd, status_req_seen_sd;
reg         subtitle_write_seen_sd, subtitle_commit_seen_sd, subtitle_store_ack_seen;
reg [7:0]   set_op_s0, set_op_s1, set_value_s0, set_value_s1;
reg [7:0]   status_sequence_s0, status_sequence_s1;
reg [7:0]   subtitle_index_s0, subtitle_index_s1, subtitle_char_s0, subtitle_char_s1;
reg [7:0]   subtitle_length_s0, subtitle_length_s1;
reg [7:0]   subtitle_sequence_s0, subtitle_sequence_s1;
reg         subtitle_waiting_ack;
reg [7:0]   subtitle_pending_sequence, subtitle_pending_length;
reg         subtitle_ack_toggle_sd;
reg [7:0]   subtitle_ack_sequence_sd, subtitle_ack_value_sd;
reg [2:0]   subtitle_ack_sync_eth, status_snapshot_sync_eth;
reg         subtitle_ack_seen_eth, status_snapshot_seen_eth;
reg [7:0]   subtitle_ack_seq_e0, subtitle_ack_seq_e1;
reg [7:0]   subtitle_ack_value_e0, subtitle_ack_value_e1;
reg [63:0]  status_snapshot_data_sd, status_data_e0, status_data_e1;
reg         status_snapshot_toggle_sd;
reg         subtitle_ack_valid_eth, status_valid_eth;
reg [7:0]   subtitle_ack_seq_eth, subtitle_ack_value_eth;
reg [63:0]  status_payload_eth;

wire diagnostic_cursor_enabled;wire [10:0] diagnostic_cursor_x;wire [9:0] diagnostic_cursor_y;
generate if(DISPLAY_DIAGNOSTICS)begin:g_diagnostic_cursor
display_test_cursor u_test_cursor(.clk(eth_app_clk),.rst(rst_all),.data(eth_rx_data),.valid(eth_rx_valid),
    .enabled(diagnostic_cursor_enabled),.x(diagnostic_cursor_x),.y(diagnostic_cursor_y));
end else begin:g_product_cursor
    assign diagnostic_cursor_enabled=1'b0;
    assign diagnostic_cursor_x=11'd640;
    assign diagnostic_cursor_y=10'd360;
end endgenerate
wire digest_req, digest_valid, digest_ready, digest_ack;
wire media_packet_to_source,media_packet_to_owner,media_source_claim;
wire [7:0] digest_data;
wire [15:0] digest_length;
eth_subsys #(.MEDIA_PEER_IP(MEDIA_PEER_IP), .MEDIA_PEER_UDP_PORT(MEDIA_PEER_PORT)) u_eth_subsys(
    .clk_50              (clk),
    .rst_all             (rst_all),
    .phy1_rgmii_rx_clk   (eth_rgmii_rxc),
    .phy1_rgmii_rx_ctl   (eth_rgmii_rx_ctl),
    .phy1_rgmii_rx_data  (eth_rgmii_rxd),
    .phy1_rgmii_tx_clk   (eth_rgmii_txc),
    .phy1_rgmii_tx_ctl   (eth_rgmii_tx_ctl),
    .phy1_rgmii_tx_data  (eth_rgmii_txd),
    .phy_reset           (eth_phy_reset),
    .app_clk_out         (eth_app_clk),
    .app_rx_data_out     (eth_stack_rx_data),
    .app_rx_data_valid_out(eth_stack_rx_valid),
    .app_rx_data_length_out(eth_stack_rx_length),
    .app_rx_packet_start_out(eth_stack_rx_start),
    .app_rx_packet_end_out(eth_stack_rx_end),
    .link_trace(eth_link_trace),
    .media_packet_request(media_packet_request),
    .media_packet_valid  (media_packet_valid),
    .media_packet_data   (media_packet_data),
    .media_packet_length (media_packet_length),
    .media_packet_to_source(media_packet_to_source),
    .media_packet_to_owner(media_packet_to_owner),
    .media_source_claim(media_source_claim),
    .media_packet_ack    (media_packet_ack),
    .media_packet_ready  (media_packet_ready),
    .digest_req(digest_req), .digest_valid(digest_valid), .digest_data(digest_data),
    .digest_length(digest_length), .digest_ready(digest_ready), .digest_ack(digest_ack)
);

direct_video_packet_demux #(.DROP_AUDIO(1)) u_direct_video_packet_demux (
    .clk (eth_app_clk), .rst (rst_all),
    .rx_valid (eth_stack_rx_valid), .rx_data (eth_stack_rx_data),
    .rx_length (eth_stack_rx_length), .rx_packet_start (eth_stack_rx_start),
    .rx_packet_end (eth_stack_rx_end),
    .app_valid (eth_rx_valid), .app_data (eth_rx_data), .app_length ( ),
    .app_packet_start ( ), .app_packet_end ( ),
    .video_valid (video_rx_valid), .video_data (video_rx_data),
    .video_length (video_rx_length), .video_packet_start (video_rx_start),
    .video_packet_end (video_rx_end)
);

direct_video_row_parser #(.PIXELS_PER_ROW(DIRECT_VIDEO_WIDTH),.ACTIVE_LINES(DIRECT_VIDEO_HEIGHT)) u_direct_video_row_parser (
    .clk (eth_app_clk), .rst (rst_all),
    .packet_start (video_rx_start), .packet_end (video_rx_end),
    .packet_length (video_rx_length), .rx_valid (video_rx_valid),
    .rx_data (video_rx_data), .row_begin (video_row_begin),
    .row_stream_start (video_row_stream_start), .row_frame_id (video_row_frame_id),
    .row_index (video_row_index), .row_sequence (video_row_sequence),
    .pixel_write (video_pixel_write), .pixel_index (video_pixel_index),
    .pixel_data (video_pixel_data), .row_commit (video_row_commit),
    .row_crc_seed(video_crc_seed),.row_crc_expected(video_crc_expected),
    .row_reject (video_row_reject), .accepted_rows (video_parser_accepted), .rejected_rows (video_parser_rejected)
);

direct_video_session_gate u_direct_video_session_gate (
    .clk (eth_app_clk), .rst (rst_all),
    .row_stream_start (video_row_stream_start),
    .row_frame_id (video_row_frame_id), .row_index (video_row_index),
    .row_commit (video_row_commit), .row_reject (video_row_reject),
    .request (video_session_request)
);

always @(posedge eth_app_clk or posedge rst_all) begin
    if (rst_all)
        auto_play_w <= 1'b0;
    else if (frame_commit_pulse)
        auto_play_w <= media_auto_play_status;
end

wire view_prepare_valid,view_status_request,view_accepted_begin,view_image_owned,view_abort_image;
wire [15:0] view_owned_frame_id;
wire [63:0] view_prepare_body,view_prepare_reply;
wire view_prepare_reply_valid,view_status_valid,view_busy;
wire [127:0] view_status_body;
assign media_source_claim = view_prepare_reply_valid && (view_prepare_reply[15:8] == 8'd0);
wire [1:0] view_target_layout,view_target_window,view_active_layout,view_focus,view_write_layout,view_write_window;
wire [15:0] view_target_generation,view_active_generation;
wire [3:0] view_active_mask;
wire [4:0] view_focus_index;
wire [11:0] view_focus_width,view_focus_height;
wire view_target_buffer,view_config_epoch,view_config_buffer,view_video_epoch,view_video_buffer,view_drained_epoch;
wire [1:0] view_config_layout,view_video_layout;
wire [3:0] view_config_mask,view_video_mask;
wire [3:0] view_config_window_buffers,view_video_window_buffers;
wire view_transition_start_toggle,view_transition_release_toggle,view_transition_active;
wire [1:0] view_transition_mode;
wire view_transition_direction_prev;
wire transition_start_effective=transition_start_toggle ^ view_transition_start_toggle;
wire transition_target_effective=view_transition_active ? view_target_buffer : transition_target_buf;
wire [1:0] transition_mode_effective=view_transition_active ? view_transition_mode : transition_mode_latched;
wire transition_direction_effective=view_transition_active ? view_transition_direction_prev : transition_prev_latched;
wire writer_image_result_valid;
wire [7:0] writer_image_result_code;
wire [15:0] view_result_frame;
wire view_pipeline_ready;
wire aud_pair_raw;
wire view_audio_commit_enable=(view_active_layout==0 && view_target_layout==0);
reg [2:0] view_local_sync;
reg view_local_seen;
reg [10:0] view_cursor_x0,view_cursor_x1;
reg [9:0] view_cursor_y0,view_cursor_y1;
wire view_local_step=view_local_sync[2]!=view_local_seen &&
                     (media_cmd_byte==8'h4e || media_cmd_byte==8'h50);
always @(posedge eth_app_clk or posedge rst_all)begin
    if(rst_all)begin view_local_sync<=0;view_local_seen<=0;
        view_cursor_x0<=640;view_cursor_x1<=640;view_cursor_y0<=360;view_cursor_y1<=360;end
    else begin
        view_local_sync<={view_local_sync[1:0],media_cmd_toggle};view_local_seen<=view_local_sync[2];
        view_cursor_x0<=cursor_mailbox_x;view_cursor_x1<=view_cursor_x0;
        view_cursor_y0<=cursor_mailbox_y;view_cursor_y1<=view_cursor_y0;
    end
end
view_protocol_rx u_view_protocol(.clk(eth_app_clk),.rst(rst_all),.data(eth_rx_data),.valid(eth_rx_valid),
    .prepare_valid(view_prepare_valid),.prepare_body(view_prepare_body),.status_request(view_status_request));
view_session_manager #(.EXTERNAL_BUSY_ENABLED(1)) u_view_session(.clk(eth_app_clk),.rst(rst_all),.external_busy(video_session_busy),.transaction_busy(view_transaction_busy),
    .prepare_valid(view_prepare_valid),.prepare_body(view_prepare_body),.status_request(view_status_request),
    .cursor_x(diagnostic_cursor_enabled ? diagnostic_cursor_x : view_cursor_x1),.cursor_y(diagnostic_cursor_enabled ? diagnostic_cursor_y : view_cursor_y1),.local_step(view_local_step),
    .frame_begin(media_frame_begin_valid),.frame_id(media_frame_id),
    .frame_generation(media_image_generation),.frame_layout(media_image_layout[1:0]),
    .frame_window(media_image_window[1:0]),.frame_index(media_source_index),
    .frame_width(media_image_width),.frame_height(media_image_height),
    .writer_result_valid(writer_image_result_valid),.writer_result(writer_image_result_code),
    .transition_mode_cfg(transition_mode_cfg),.transition_done_toggle(transition_done_toggle),
    .single_display_buffer(disp_buf_idx[0]),.cfg_drained_epoch(view_drained_epoch),
    .accepted_begin(view_accepted_begin),.image_owned(view_image_owned),.owned_frame_id(view_owned_frame_id),
    .abort_image(view_abort_image),.target_buffer(view_target_buffer),
    .target_layout(view_target_layout),.target_window(view_target_window),.target_generation(view_target_generation),
    .busy(view_busy),.active_layout(view_active_layout),.active_mask(view_active_mask),
    .active_generation(view_active_generation),.focus_window(view_focus),.focus_index(view_focus_index),
    .focus_width(view_focus_width),.focus_height(view_focus_height),
    .prepare_reply_valid(view_prepare_reply_valid),.prepare_reply_body(view_prepare_reply),
    .view_status_valid(view_status_valid),.view_status_body(view_status_body),
    .image_result_valid(media_image_result_valid),.image_result(media_image_result_code),
    .image_result_frame(view_result_frame),.config_epoch(view_config_epoch),
    .config_buffer(view_config_buffer),.config_layout(view_config_layout),.config_mask(view_config_mask),
    .config_window_buffers(view_config_window_buffers),
    .view_transition_start_toggle(view_transition_start_toggle),
    .view_transition_mode(view_transition_mode),
    .view_transition_direction_prev(view_transition_direction_prev),
    .view_transition_release_toggle(view_transition_release_toggle),
    .view_transition_active(view_transition_active));
view_video_config u_view_video(.clk(video_clk),.rst(rst_all),.vs(vs_0),
    .raw_epoch(view_config_epoch),.raw_buffer(view_config_buffer),
    .raw_layout(view_config_layout),.raw_mask(view_config_mask),
    .raw_window_buffers(view_config_window_buffers),
    .epoch(view_video_epoch),.buffer_index(view_video_buffer),.layout(view_video_layout),
    .valid_mask(view_video_mask),.window_buffers(view_video_window_buffers));
assign aud_pair_on=aud_pair_raw;

media_protocol_rx #(.MULTIVIEW(1)) u_media_protocol_rx (
    .clk (eth_app_clk), .rst (rst_all), .rx_data (eth_rx_data), .rx_valid (eth_rx_valid),
    .ready_request (media_ready_request),
    .frame_begin_valid (media_frame_begin_valid), .frame_id (media_frame_id),
    .image_index (media_source_index), .image_flags (media_image_flags),
    .image_total_words (media_total_words), .image_width (media_image_width),
    .image_height (media_image_height),
    .image_layout (media_image_layout), .image_window (media_image_window),
    .image_generation (media_image_generation),
    .stream_start (media_stream_start), .stream_is_audio (media_stream_is_audio),
    .stream_word_count (media_stream_word_count), .stream_word_data (media_stream_word_data),
    .stream_word_valid (media_stream_word_valid), .stream_word_ready (media_raw_stream_ready),
    .stream_done (media_stream_done),
    .frame_end_valid (media_frame_end_valid), .frame_end_ok (media_frame_end_ok),
    .frame_end_reason (media_frame_end_reason),
    .frame_end_id (media_frame_end_id),
    .audio_begin_valid (media_audio_begin_valid), .audio_frame_id (media_audio_frame_id),
    .audio_sample_count (media_audio_sample_count),
    .audio_end_valid (media_audio_end_valid), .audio_end_ok (media_audio_end_ok),
    .audio_end_reason (media_audio_end_reason),
    .audio_end_id (media_audio_end_id), .protocol_error_toggle (media_protocol_error_toggle)
);

view_image_pipeline u_media_frame_pad (
    .clk (eth_app_clk), .rst (rst_all),
    .frame_begin (view_accepted_begin),.layout(media_image_layout[1:0]),
    .image_width (media_image_width), .image_height (media_image_height),
    .frame_end ((media_frame_end_valid && view_image_owned) || view_abort_image),
    .in_audio (media_stream_is_audio), .in_start (media_stream_start),
    .in_count (media_stream_word_count), .in_data (media_stream_word_data),
    .in_valid (media_stream_word_valid && view_image_owned), .in_ready (view_pipeline_ready),
    .in_done (media_stream_done),
    .out_start (media_padded_stream_start), .out_audio (media_padded_stream_audio),
    .out_count (media_padded_stream_count), .out_data (media_padded_stream_data),
    .out_valid (media_padded_stream_valid), .out_ready (media_padded_stream_ready),
    .out_done (media_padded_stream_done), .frame_done (media_pad_frame_done)
);
assign media_raw_stream_ready=view_image_owned ? view_pipeline_ready : 1'b1;

media_display_control_rx #(.CV_ENABLED(PRODUCT_CV_ENABLED),.SPECTRUM_ENABLED(PRODUCT_SPECTRUM_ENABLED)) u_media_display_control_rx (
    .clk (eth_app_clk), .rst (rst_all), .rx_data (eth_rx_data), .rx_valid (eth_rx_valid),
    .set_toggle (media_set_toggle_eth), .set_op (media_set_op_eth),
    .set_value (media_set_value_eth),
    .status_req_valid (media_status_req_valid_eth),
    .status_sequence (media_status_sequence_eth),
    .control_ack_valid (media_control_ack_valid_rx),
    .control_ack_sequence (media_control_ack_sequence_rx),
    .control_ack_op (media_control_ack_op_rx),
    .control_ack_status (media_control_ack_status_rx),
    .control_ack_value (media_control_ack_value_rx),
    .subtitle_write_toggle (subtitle_write_toggle_eth),
    .subtitle_write_index (subtitle_write_index_eth),
    .subtitle_write_char (subtitle_write_char_eth),
    .subtitle_commit_toggle (subtitle_commit_toggle_eth),
    .subtitle_commit_length (subtitle_commit_length_eth),
    .subtitle_commit_sequence (subtitle_commit_sequence_eth)
);

media_transaction_writer #(.VIEW_ENABLE(1),.DIRECT_STREAM(1)) u_media_transaction_writer (
    .udp_clk (eth_app_clk), .udp_rst (rst_all),
    .frame_begin_valid (view_accepted_begin), .frame_id (media_frame_id),
    .image_layout(media_image_layout[1:0]),.image_window(media_image_window[1:0]),
    .view_target_buffer(view_target_buffer),.write_layout(view_write_layout),.write_window(view_write_window),
    .image_index (media_source_index), .image_flags (media_image_flags),
    .image_total_words (media_total_words),
    .image_width (media_image_width), .image_height (media_image_height),
    .stream_start (media_padded_stream_start), .stream_is_audio (media_padded_stream_audio),
    .stream_word_count (media_padded_stream_count), .stream_word_data (media_padded_stream_data),
    .stream_word_valid (media_padded_stream_valid), .stream_word_ready (media_padded_stream_ready),
    .stream_done (media_padded_stream_done),
    .frame_end_valid ((media_frame_end_valid && view_image_owned) || view_abort_image),
    .frame_end_ok (media_frame_end_ok && !view_abort_image),
    .frame_end_reason (media_frame_end_reason),
    .frame_end_id (view_abort_image ? view_owned_frame_id : media_frame_end_id),
    .audio_begin_valid (media_audio_begin_valid && view_image_owned), .audio_frame_id (media_audio_frame_id),
    .audio_sample_count (media_audio_sample_count),
    .audio_end_valid (media_audio_end_valid), .audio_end_ok (media_audio_end_ok),
    .audio_end_reason (media_audio_end_reason),
    .audio_end_id (media_audio_end_id),
    .write_clk (eth_app_clk), .write_rst (rst_all),
    .frame_finish_toggle (frame_write_toggle_mem),
    .effect_mode ((view_active_layout!=0 || view_target_layout!=0) ? 2'd0 : transition_mode_cfg),
    .audio_commit_enable(view_audio_commit_enable),
    .transition_done_toggle (transition_done_toggle),
    .display_valid (display_valid), .image_index_out (img_idx_w),
    .image_width_out (displayed_image_width), .image_height_out (displayed_image_height),
    .image_has_wav (img_wav_w), .auto_play_status (media_auto_play_status),
    .display_buffer_index (disp_buf_idx),
    .transition_start_toggle (transition_start_toggle),
    .transition_target_buf (transition_target_buf),
    .transition_mode_latched (transition_mode_latched),
    .transition_prev_latched (transition_prev_latched),
    .frame_commit_pulse (frame_commit_pulse),
    .write_req (media_write_req), .write_req_ack (media_write_req_ack),
    .write_ready (media_write_ready),
    .write_buffer_index (write_buf_idx), .write_length (media_write_len),
    .write_row_offset (media_row_offset), .write_en (media_write_en),
    .write_data (media_write_data),
    .image_result_valid (writer_image_result_valid),
    .image_result_code (writer_image_result_code),
    .audio_result_valid (media_audio_result_valid),
    .audio_result_code (media_audio_result_code),
    .audio_pair_on (aud_pair_raw), .audio_buffer_index (audio_buffer_index),
    .audio_buffer_length (audio_buffer_length),
    .audio_sample_count_out (audio_sample_count_out), .audio_source_toggle (audio_source_toggle)
);

wire [7:0] media_local_cmd_byte = media_cmd_byte;
media_display_tx #(.VIEW_ENABLE(1)) u_media_display_tx (
    .clk (eth_app_clk), .rst (rst_all),
    .tx_ready (media_packet_ready),
    .local_cmd_toggle_async (media_cmd_toggle), .local_cmd_async (media_local_cmd_byte),
    .ready_valid (media_ready_request),
    .image_result_valid (media_image_result_valid), .image_result_code (media_image_result_code),
    .image_result_frame (view_result_frame),
    .view_busy(view_busy),.view_prepare_valid(view_prepare_reply_valid),.view_prepare_body(view_prepare_reply),
    .view_status_valid(view_status_valid),.view_status_body(view_status_body),
    .audio_result_valid (media_audio_result_valid), .audio_result_code (media_audio_result_code),
    .audio_result_frame (media_frame_id),
    .control_ack_valid (media_control_ack_valid),
    .control_ack_sequence (media_control_ack_sequence), .control_ack_op (media_control_ack_op),
    .control_ack_status (media_control_ack_status), .control_ack_value (media_control_ack_value),
    .status_valid (media_status_valid), .status_payload (media_status_payload),
    .tx_request (media_packet_request), .tx_valid (media_packet_valid),
    .tx_data (media_packet_data), .tx_length (media_packet_length), .tx_to_source(media_packet_to_source),
    .tx_to_owner(media_packet_to_owner),
    .tx_ack (media_packet_ack)
);

assign media_control_ack_valid = media_control_ack_valid_rx | subtitle_ack_valid_eth;
assign media_control_ack_sequence = subtitle_ack_valid_eth ? subtitle_ack_seq_eth :
                                    media_control_ack_sequence_rx;
assign media_control_ack_op = subtitle_ack_valid_eth ? 8'd8 : media_control_ack_op_rx;
assign media_control_ack_status = subtitle_ack_valid_eth ? 8'd0 : media_control_ack_status_rx;
assign media_control_ack_value = subtitle_ack_valid_eth ? subtitle_ack_value_eth :
                                  media_control_ack_value_rx;
assign media_status_valid = status_valid_eth;
assign media_status_payload = status_payload_eth;

always @(posedge eth_app_clk or posedge rst_all) begin
    if (rst_all) begin
        status_req_toggle_eth <= 1'b0;
        subtitle_ack_sync_eth <= 3'b000;
        status_snapshot_sync_eth <= 3'b000;
        subtitle_ack_seen_eth <= 1'b0;
        status_snapshot_seen_eth <= 1'b0;
        subtitle_ack_seq_e0 <= 8'd0; subtitle_ack_seq_e1 <= 8'd0;
        subtitle_ack_value_e0 <= 8'd0; subtitle_ack_value_e1 <= 8'd0;
        status_data_e0 <= 64'd0; status_data_e1 <= 64'd0;
        subtitle_ack_valid_eth <= 1'b0; status_valid_eth <= 1'b0;
        subtitle_ack_seq_eth <= 8'd0; subtitle_ack_value_eth <= 8'd0;
        status_payload_eth <= 64'd0;
    end else begin
        if (media_status_req_valid_eth)
            status_req_toggle_eth <= ~status_req_toggle_eth;
        subtitle_ack_sync_eth <= {subtitle_ack_sync_eth[1:0], subtitle_ack_toggle_sd};
        status_snapshot_sync_eth <= {status_snapshot_sync_eth[1:0], status_snapshot_toggle_sd};
        subtitle_ack_seq_e0 <= subtitle_ack_sequence_sd;
        subtitle_ack_seq_e1 <= subtitle_ack_seq_e0;
        subtitle_ack_value_e0 <= subtitle_ack_value_sd;
        subtitle_ack_value_e1 <= subtitle_ack_value_e0;
        status_data_e0 <= status_snapshot_data_sd;
        status_data_e1 <= status_data_e0;
        subtitle_ack_valid_eth <= 1'b0;
        status_valid_eth <= 1'b0;
        if (subtitle_ack_sync_eth[2] != subtitle_ack_seen_eth) begin
            subtitle_ack_seen_eth <= subtitle_ack_sync_eth[2];
            subtitle_ack_seq_eth <= subtitle_ack_seq_e1;
            subtitle_ack_value_eth <= subtitle_ack_value_e1;
            subtitle_ack_valid_eth <= 1'b1;
        end
        if (status_snapshot_sync_eth[2] != status_snapshot_seen_eth) begin
            status_snapshot_seen_eth <= status_snapshot_sync_eth[2];
            status_payload_eth <= status_data_e1;
            status_valid_eth <= 1'b1;
        end
    end
end

always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        set_toggle_sync_sd <= 3'b000; status_req_sync_sd <= 3'b000;
        subtitle_write_sync_sd <= 3'b000; subtitle_commit_sync_sd <= 3'b000;
        subtitle_store_ack_sync <= 3'b000;
        set_toggle_seen_sd <= 1'b0; status_req_seen_sd <= 1'b0;
        subtitle_write_seen_sd <= 1'b0; subtitle_commit_seen_sd <= 1'b0;
        subtitle_store_ack_seen <= 1'b0; subtitle_waiting_ack <= 1'b0;
        set_op_s0 <= 8'd0; set_op_s1 <= 8'd0;
        set_value_s0 <= 8'd0; set_value_s1 <= 8'd0;
        status_sequence_s0 <= 8'd0; status_sequence_s1 <= 8'd0;
        subtitle_index_s0 <= 8'd0; subtitle_index_s1 <= 8'd0;
        subtitle_char_s0 <= 8'd0; subtitle_char_s1 <= 8'd0;
        subtitle_length_s0 <= 8'd0; subtitle_length_s1 <= 8'd0;
        subtitle_sequence_s0 <= 8'd0; subtitle_sequence_s1 <= 8'd0;
        set_valid_sd <= 1'b0; set_op_sd <= 8'd0; set_value_sd <= 8'd0;
        status_snapshot_data_sd <= 64'd0; status_snapshot_toggle_sd <= 1'b0;
        subtitle_wr_en <= 1'b0; subtitle_wr_index <= 8'd0; subtitle_wr_char <= 8'h20;
        subtitle_commit_toggle <= 1'b0; subtitle_commit_len <= 8'd0;
        subtitle_pending_sequence <= 8'd0; subtitle_pending_length <= 8'd0;
        subtitle_ack_toggle_sd <= 1'b0; subtitle_ack_sequence_sd <= 8'd0;
        subtitle_ack_value_sd <= 8'd0;
    end else begin
        set_toggle_sync_sd <= {set_toggle_sync_sd[1:0], media_set_toggle_eth};
        status_req_sync_sd <= {status_req_sync_sd[1:0], status_req_toggle_eth};
        subtitle_write_sync_sd <= {subtitle_write_sync_sd[1:0], subtitle_write_toggle_eth};
        subtitle_commit_sync_sd <= {subtitle_commit_sync_sd[1:0], subtitle_commit_toggle_eth};
        subtitle_store_ack_sync <= {subtitle_store_ack_sync[1:0], subtitle_swap_ack};
        set_op_s0 <= media_set_op_eth; set_op_s1 <= set_op_s0;
        set_value_s0 <= media_set_value_eth; set_value_s1 <= set_value_s0;
        status_sequence_s0 <= media_status_sequence_eth; status_sequence_s1 <= status_sequence_s0;
        subtitle_index_s0 <= subtitle_write_index_eth; subtitle_index_s1 <= subtitle_index_s0;
        subtitle_char_s0 <= subtitle_write_char_eth; subtitle_char_s1 <= subtitle_char_s0;
        subtitle_length_s0 <= subtitle_commit_length_eth; subtitle_length_s1 <= subtitle_length_s0;
        subtitle_sequence_s0 <= subtitle_commit_sequence_eth; subtitle_sequence_s1 <= subtitle_sequence_s0;
        set_valid_sd <= 1'b0;
        subtitle_wr_en <= 1'b0;

        if (set_toggle_sync_sd[2] != set_toggle_seen_sd) begin
            set_toggle_seen_sd <= set_toggle_sync_sd[2];
            set_op_sd <= set_op_s1; set_value_sd <= set_value_s1;
            set_valid_sd <= 1'b1;
        end
        if (status_req_sync_sd[2] != status_req_seen_sd) begin
            status_req_seen_sd <= status_req_sync_sd[2];
            status_snapshot_data_sd <= {
                {6'd0, sensitivity_value}, {7'd0, bar_en},
                {6'd0, osd_mode_cfg}, {6'd0, transition_mode_cfg},
                {4'd0, contrast_value}, {4'd0, brightness_value},
                {1'b0, cv_effect_mode_cfg, vol_gain}, status_sequence_s1
            };
            status_snapshot_toggle_sd <= ~status_snapshot_toggle_sd;
        end
        if (subtitle_write_sync_sd[2] != subtitle_write_seen_sd) begin
            subtitle_write_seen_sd <= subtitle_write_sync_sd[2];
            subtitle_wr_index <= subtitle_index_s1;
            subtitle_wr_char <= subtitle_char_s1;
            subtitle_wr_en <= 1'b1;
        end
        if (subtitle_commit_sync_sd[2] != subtitle_commit_seen_sd) begin
            subtitle_commit_seen_sd <= subtitle_commit_sync_sd[2];
            subtitle_commit_len <= subtitle_length_s1;
            subtitle_pending_sequence <= subtitle_sequence_s1;
            subtitle_pending_length <= subtitle_length_s1;
            subtitle_commit_toggle <= ~subtitle_commit_toggle;
            subtitle_waiting_ack <= 1'b1;
        end
        if (subtitle_store_ack_sync[2] != subtitle_store_ack_seen) begin
            subtitle_store_ack_seen <= subtitle_store_ack_sync[2];
            if (subtitle_waiting_ack) begin
                subtitle_ack_sequence_sd <= subtitle_pending_sequence;
                subtitle_ack_value_sd <= subtitle_pending_length;
                subtitle_ack_toggle_sd <= ~subtitle_ack_toggle_sd;
                subtitle_waiting_ack <= 1'b0;
            end
        end
    end
end

assign state_code = 4'd0;
assign dbg_fat_state = 8'd0;
assign dbg_fat_err = 1'b0;
assign aud_play_done = 1'b0;

wire signed [23:0] aud_l_s = $signed(video_mode_active ? direct_audio_sample : aud_l);
wire signed [23:0] aud_r_s = $signed(video_mode_active ? direct_audio_sample : aud_r);
wire signed [27:0] aud_l_g = (aud_l_s * $signed({1'b0, vol_gain})) >>> 3;
wire signed [27:0] aud_r_g = (aud_r_s * $signed({1'b0, vol_gain})) >>> 3;
wire [23:0] aud_l_v = aud_l_g[23:0];
wire [23:0] aud_r_v = aud_r_g[23:0];
reg [1:0] video_mode_audio_sync;
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all)
        video_mode_audio_sync <= 2'b00;
    else
        video_mode_audio_sync <= {video_mode_audio_sync[0],video_mode_active};
end

sys_pll sys_pll_m0(
    .refclk(clk), .reset(1'b0), .extlock(sys_pll_lock),
    .clk0_out(sd_card_clk), .clk1_out(ext_mem_clk), .clk2_out(ext_mem_clk_sft)
);

video_pll video_pll_m0(
    .refclk(clk), .reset(1'b0), .extlock(video_pll_lock),
    .clk0_out(video_clk), .clk1_out(hdmi_5x_clk)
);

gt911_trackpad u_gt911_trackpad (
    .clk(sd_card_clk), .rst(rst_all), .scl(gt911_scl), .sda(gt911_sda),
    .cursor_ack_toggle(cursor_ack_toggle), .cursor_req_toggle(cursor_req_toggle),
    .cursor_mailbox_x(cursor_mailbox_x), .cursor_mailbox_y(cursor_mailbox_y),
    .online(cursor_online), .touch_report(), .touch_down(),
    .swipe_next(touch_swipe_next), .swipe_prev(touch_swipe_prev),
    .cursor_x(), .cursor_y()
);

always @(posedge ext_mem_clk or posedge rst_all) begin
    if (rst_all) frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish) frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

media_audio_playback #(.PAUSE_ENABLED(1)) u_media_audio_playback (
    .clk (sd_card_clk), .rst (rst_all),.pause(video_mode_audio_sync[1]), .source_toggle (audio_source_toggle),
    .pair_on (aud_pair_on), .source_buffer (audio_buffer_index),
    .source_length (audio_buffer_length), .source_samples (audio_sample_count_out),
    .read_req (audio_read_req), .read_req_ack_async (audio_read_req_ack),
    .read_index (audio_read_index), .read_length (audio_read_length),
    .read_en (audio_read_en), .read_data (audio_read_data),
    .read_fifo_words (audio_read_fifo_words),
    .audio_tick (aud_tick), .audio_valid (aud_valid),
    .audio_left (aud_l), .audio_right (aud_r), .audio_underrun (aud_underrun)
);

// ===================== 双板分片诊断数码管 ======================
// 左侧 db 为标记，后四位为错误计数和完整分片计数（各 8 位十六进制）。
// ETH 域的完成事件以 toggle 同步到 50 MHz，避免跨域传递多位计数器。
wire [6:0] seg0, seg1, seg2, seg3, seg4, seg5;
wire [15:0] link_digits;
generate if(VIDEO_LINK_DIAGNOSTICS)begin:g_link_trace
    reg [7:0] seen,meta,synced;
    reg [7:0] live_meta,live_sync;
    always @(posedge eth_app_clk or posedge rst_all)
        if(rst_all)seen<=0;
        else seen<=seen|{eth_link_trace[5],(eth_link_trace[4]|eth_link_trace[2]),eth_link_trace[1],video_ready_event,
                        video_row_commit,video_rx_valid,eth_stack_rx_valid,eth_link_trace[0]};
    always @(posedge clk)begin
        meta<=seen;synced<=meta;
        live_meta<={sys_pll_lock,video_pll_lock,rst_all,eth_link_trace[3],
                    Sdr_init_done,video_request,video_memory_grant,video_stream_active};
        live_sync<=live_meta;
    end
    assign link_digits={live_sync,synced};
end else begin:g_product_digits
    assign link_digits={{3'd0,display_valid},{3'd0,aud_pair_on},3'd0,img_idx_w};
end endgenerate
seg_decoder u_seg0 (.bin_data(link_digits[3:0]), .seg_data(seg0));
seg_decoder u_seg1 (.bin_data(link_digits[7:4]), .seg_data(seg1));
seg_decoder u_seg2 (.bin_data(link_digits[11:8]), .seg_data(seg2));
seg_decoder u_seg3 (.bin_data(link_digits[15:12]), .seg_data(seg3));
seg_decoder u_seg4 (.bin_data(4'hd), .seg_data(seg4));
seg_decoder u_seg5 (.bin_data(4'h2), .seg_data(seg5));
seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,seg0}),
    .seg_data_1        ({1'b1,seg1}),
    .seg_data_2        ({1'b1,seg2}),
    .seg_data_3        ({1'b1,seg3}),
    .seg_data_4        ({1'b1,seg4}),
    .seg_data_5        ({1'b1,seg5})
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

// Hybrid queue: complete ingress rows -> SDRAM lookahead -> small BRAM head.
// The head returns RGB565 pairs to the unchanged video_delay unpacker.
reg de_raw_d_video, vs_raw_d_video;
reg video_word_pop_d_video;
reg [10:0] video_scan_x_reg;
reg [9:0] video_scan_y_reg;
assign video_frame_start = vs_raw_d_video && !vs_0;
assign video_line_start = de_0 && !de_raw_d_video;
assign video_line_done = !de_0 && de_raw_d_video;
assign video_scan_x = video_scan_x_reg;
assign video_scan_y = video_scan_y_reg;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        de_raw_d_video <= 1'b0;
        vs_raw_d_video <= 1'b1;
        video_word_pop_d_video <= 1'b0;
        video_scan_x_reg <= 11'd0;
        video_scan_y_reg <= 10'd0;
    end else begin
        de_raw_d_video <= de_0;
        vs_raw_d_video <= vs_0;
        video_word_pop_d_video <= video_read_en;
        if (video_frame_start)
            video_scan_y_reg <= 10'd0;
        else if (video_line_done && video_scan_y_reg < 10'd720)
            video_scan_y_reg <= video_scan_y_reg + 10'd1;

        if (!de_0)
            video_scan_x_reg <= 11'd0;
        else
            video_scan_x_reg <= video_scan_x_reg + 11'd1;

    end
end

video_hybrid_pipeline #(.WIDTH(DIRECT_VIDEO_WIDTH),.HEIGHT(DIRECT_VIDEO_HEIGHT),.WINDOW(DIRECT_VIDEO_ROWS),.HEAD_ROWS(4),.INGRESS_PAGES(4)) u_direct_video_pipeline(
 .app_clk(eth_app_clk),.mem_clk(ext_mem_clk),.pixel_clk(video_clk),.rst(rst_all),.memory_enable(video_memory_grant),
 .sdr_init_done(Sdr_init_done),.sdr_busy(Sdr_busy),.sdr_refresh(Sdr_init_ref_vld),.scratch_base(video_scratch_base),
 .row_begin(video_row_begin),.row_start(video_row_stream_start),.pixel_write(video_pixel_write),.row_commit(video_row_commit),.row_reject(video_row_reject),
 .row_frame(video_row_frame_id),.row_sequence(video_row_sequence),.pixel_data(video_pixel_data),.crc_seed(video_crc_seed),.crc_expected(video_crc_expected),.row_index(video_row_index),.pixel_index(video_pixel_index),
 .source_ready(),.credit_sequence(video_credit_next_sequence),.credit_event(video_credit_update),.ready_event(video_ready_event),.ready_sequence(video_ready_sequence),.ready_frame(video_ready_frame),.free_rows(video_free_row_credits),
 .accepted_rows(video_accepted_rows),.rejected_rows(video_rejected_rows),.duplicate_rows(video_duplicate_rows),.hybrid_stats(video_hybrid_stats),.readback_stats(video_readback_stats),.nack_event(video_nack_valid),.nack_sequence(video_nack_sequence),
 .frame_start(video_frame_start),.line_start(video_line_start),.line_done(video_line_done),.word_pop(video_word_pop_d_video),.video_y(video_scan_y),
 .word_data(video_word_data),.word_valid(video_word_valid),.line_available(video_line_available),.video_ready(video_stream_ready),.underflows(video_underflow_lines),
 .session_live(video_stream_active),.video_missing(video_missing),.memory_active(video_memory_active),.memory_idle(video_memory_idle),
 .app_wr_en(video_wr_en),.app_wr_addr(video_wr_addr),.app_wr_data(video_wr_data),.app_rd_en(video_rd_en),.app_rd_addr(video_rd_addr),.sdr_rd_en(Sdr_rd_en&&video_memory_grant),.sdr_rd_data(Sdr_rd_dout));
video_memory_lease u_video_memory_lease(
 .mem_clk(ext_mem_clk),.pixel_clk(video_clk),.rst(rst_all),.request_async(video_request),.transaction_busy_async(view_transaction_busy),.audio_buffer_async(audio_buffer_index),
 .frame_start(video_frame_start),.old_rd_en(mux_app_rd_en),.old_wr_en(App_wr_en),.old_rd_valid(Sdr_rd_en&&!video_memory_grant),.old_rd_busy(frame_rd_busy),.old_wr_busy(frame_wr_busy),.old_line_busy(transition_line_hold),
 .sdr_busy(Sdr_busy),.sdr_refresh(Sdr_init_ref_vld),.stream_active(video_memory_active),.stream_idle(video_memory_idle),
 .hold_old(video_hold_old),.memory_grant(video_memory_grant),.scratch_base(video_scratch_base),.video_mode(video_mode_active),.release_toggle(video_lease_done),.accounting_error(video_lease_fault));
direct_video_audio u_direct_video_audio(.app_clk(eth_app_clk),.pixel_clk(video_clk),.rst(rst_all),
 .rx_valid(eth_stack_rx_valid),.packet_start(eth_stack_rx_start),.packet_end(eth_stack_rx_end),.rx_data(eth_stack_rx_data),.packet_length(eth_stack_rx_length),
 .session_live(video_stream_active),.session_event(video_ready_event),.session_frame(video_ready_frame),.video_ready(video_stream_ready),.frame_start(video_frame_start),
 .missing_seen(audio_missing),.audio_valid(direct_audio_valid),.audio_data(direct_audio_sample),.audio_stats(direct_audio_stats));
wire [31:0] video_selected_word = video_mode_active ? (video_stream_ready ? video_word_data : 32'd0) : transition_word;

transition_ctrl #(
    .BUF0_ADDR (BUF0_ADDR[20:0]),
    .BUF1_ADDR (BUF1_ADDR[20:0])
) transition_ctrl_m0 (
    .video_clk (video_clk), .rst (rst_all),
    .start_toggle_raw (transition_start_effective),
    .target_buf_raw (transition_target_effective),
    .mode_raw (transition_mode_effective),
    .direction_prev_raw (transition_direction_effective),
    .view_transition_raw (view_transition_active),
    .view_layout_raw (view_target_layout),.view_window_raw (view_target_window),
    .release_toggle_raw (view_transition_release_toggle),
    .done_toggle (transition_done_toggle),
    .de_word (de_word), .vs_word (vs_word),
    .line_req_toggle (line_req_toggle), .line_num (line_num),
    .line_base (line_base),.row_words(transition_row_words),
    .line_ready_toggle_raw (line_ready_toggle),
    .line_rd_bank (line_rd_bank), .line_rd_addr (line_rd_addr),
    .row_ready (effect_row_ready), .effect_active (effect_active),
    .active_mode (effect_active_mode), .direction_prev (effect_prev),
    .fade_alpha (effect_fade_alpha), .wipe_progress (effect_wipe_progress),
    .view_active(effect_view_active),.active_view_layout(effect_view_layout),
    .active_view_window(effect_view_window)
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
    .view_active(effect_view_active),.view_layout(effect_view_layout),
    .view_window(effect_view_window),
    .effect_mode (effect_active_mode), .direction_prev (effect_prev),
    .fade_alpha (effect_fade_alpha),
    .wipe_progress (effect_wipe_progress), .mixed_word (transition_word)
);

video_delay #(.MIX_PIPELINE(1)) video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_en           (video_read_en),
    .read_data         (video_selected_word),
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

reg [2:0] cv_gray_s0, cv_gray_s1;
always @(posedge video_clk) begin
    cv_gray_s0 <= cv_effect_gray_cfg;
    cv_gray_s1 <= cv_gray_s0;
end
wire [2:0] cv_mode_video = {cv_gray_s1[2],
                            cv_gray_s1[2] ^ cv_gray_s1[1],
                            cv_gray_s1[2] ^ cv_gray_s1[1] ^ cv_gray_s1[0]};

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

// Genuine selected-bin DFT of the played PCM. The present WAV is 24 kHz,
// 8-bit mono expanded to 24-bit HDMI words; take one of each repeated pair.
// A future native 24-bit source can use the same analyzer input.
wire [127:0] spectrum_levels;
wire spectrum_done_toggle, spectrum_ack_toggle;
wire [23:0] spectrum_rgb;
wire spectrum_hit;

// Optional HDMI-only computer-vision effects. Processing precedes brightness,
// spectrum and OSD so line RAMs can retain exact RGB565 source pixels while
// the UI and spectrum graphics remain aligned to the processed video timing.
generate if(PRODUCT_CV_ENABLED)begin:g_cv_enabled
cv_pixel_effects_runtime #(
    .H_ACTIVE   (1280),
    .H_TOTAL    (1650),
    .V_ACTIVE   (720),
    .MODE_DEFAULT (CV_EFFECT_MODE)
) u_cv_pixel_effects (
    .clk (video_clk), .rst (rst_all),
    .rgb_in (vout_data_raw), .de_in (de), .vs_in (vs),
    .mode_raw (video_mode_active ? 3'd0 : cv_mode_video),
    .rgb_out (cv_data), .de_out (cv_de), .vs_out (cv_vs)
);
end else begin:g_cv_disabled
    assign cv_data=vout_data_raw;
    assign cv_de=de;
    assign cv_vs=vs;
end endgenerate

wire [23:0] vout_adj;
display_levels_rgb u_display_levels(.rgb(cv_data),.contrast(ct_bin_v),.brightness(bri_bin_v),.adjusted(vout_adj));

generate if(PRODUCT_SPECTRUM_ENABLED)begin:g_spectrum_enabled
spectrum_dft u_spectrum_dft (
    .clk (sd_card_clk), .rst (rst_all),
    .aud_tick (aud_tick), .aud_valid (aud_valid),
    .pcm ($signed(aud_l_v)), .sens_gray (bar_sens_gray),
    .ack_toggle (spectrum_ack_toggle),
    .levels (spectrum_levels), .done_toggle (spectrum_done_toggle)
);
spectrum_overlay u_spectrum_overlay (
    .video_clk (video_clk), .rst (rst_all), .de (cv_de), .vs (cv_vs),
    .enable_raw (bar_en && !video_mode_active),
    .levels_raw (spectrum_levels), .done_toggle_raw (spectrum_done_toggle),
    .ack_toggle (spectrum_ack_toggle),
    .shade (), .bar_hit (spectrum_hit), .bar_rgb (spectrum_rgb)
);
end else begin:g_spectrum_disabled
    assign spectrum_levels=128'd0;
    assign spectrum_done_toggle=1'b0;
    assign spectrum_ack_toggle=1'b0;
    assign spectrum_rgb=24'd0;
    assign spectrum_hit=1'b0;
end endgenerate
wire view_pixel_black;
view_black_mask u_view_black_mask(.clk(video_clk),.rst(rst_all),.de(cv_de),.vs(cv_vs),
    .layout(view_video_layout),.valid_mask(view_video_mask),.black(view_pixel_black));
wire [23:0] base_video;
direct_video_region_mux #(.VIDEO_WIDTH(DIRECT_VIDEO_WIDTH),.VIDEO_HEIGHT(DIRECT_VIDEO_HEIGHT)) u_direct_video_region_mux (
    .clk (video_clk), .rst (rst_all), .video_mode (video_mode_active),
    .de (cv_de), .vs (cv_vs), .video_rgb (cv_data),
    .still_rgb (display_valid && !view_pixel_black ? vout_adj : 24'd0),
    .rgb_out (base_video)
);
assign vout_data = spectrum_hit ? spectrum_rgb : base_video;

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
    .video_clk (video_clk), .rst (rst_all), .de (cv_de), .vs (cv_vs),
    .ox (subtitle_ox), .oy (subtitle_oy),
    .text_len (subtitle_active_len),
    .char_index (subtitle_char_index), .char_data (subtitle_char_data),
    .font_ascii (subtitle_font_ascii), .font_row (subtitle_font_row),
    .font_row_data (subtitle_font_row_data),
    .text_on (subtitle_text_on), .text_rgb (subtitle_text_rgb), .in_band (subtitle_band)
);

osd_visibility u_osd_visibility (
    .video_clk (video_clk), .rst (rst_all), .vs (vs),
    .mode_raw (osd_mode_cfg),
    .bri_gray_raw (bri_gray), .ct_gray_raw (ct_gray),
    .vol_gray_raw (vol_gray),
    .image_width_raw (view_active_layout!=0 ? view_focus_width : displayed_image_width),
    .image_height_raw (view_active_layout!=0 ? view_focus_height : displayed_image_height),
    .show_panel (panel_show),
    .brightness_level (panel_bri_level),
    .contrast_level (panel_ct_level),
    .volume_level (panel_vol_level),
    .image_width (panel_image_width), .image_height (panel_image_height)
);

osd_panel_levels u_osd_panel (
    .video_clk (video_clk), .rst (rst_all), .de (cv_de), .vs (cv_vs),
    .brightness_level (panel_bri_level),
    .contrast_level (panel_ct_level),
    .volume_level (panel_vol_level),
    .image_width (panel_image_width), .image_height (panel_image_height),
    .font_ascii (panel_font_ascii), .font_row (panel_font_row),
    .font_row_data (panel_font_row_data),
    .text_on (panel_text_on), .text_rgb (panel_text_rgb), .in_band (panel_band)
);

font_rom_2r u_shared_font (
    .video_clk (video_clk),
    .ascii_a (subtitle_font_ascii), .row_a (subtitle_font_row),
    .row_data_a (subtitle_font_row_data),
    .ascii_b (panel_font_ascii), .row_b (panel_font_row),
    .row_data_b (panel_font_row_data)
);

osd_composite u_osd_composite (
    .video_clk (video_clk), .rst (rst_all),
    .video_in (vout_data), .de_in (cv_de), .vs_in (cv_vs),
    .panel_show (panel_show && !video_mode_active),
    .panel_text_on (panel_text_on && !video_mode_active),
    .panel_text_rgb (panel_text_rgb),
    .panel_band (panel_band && !video_mode_active),
    .subtitle_text_on (subtitle_text_on && !video_mode_active),
    .subtitle_text_rgb (subtitle_text_rgb),
    .subtitle_band (subtitle_band && !video_mode_active),
    .video_out (osd_rgb), .de_out (osd_de), .vs_out (osd_vs)
);

// Cursor is HDMI-only. PC D snapshots are generated by the media board.
gt911_cursor_overlay u_gt911_cursor (
    .video_clk (video_clk), .rst (rst_all),
    .video_in (osd_rgb), .de_in (osd_de), .vs_in (osd_vs),
    .online_raw (cursor_online && !video_mode_active),
    .cursor_req_toggle (cursor_req_toggle),
    .cursor_mailbox_x (cursor_mailbox_x),
    .cursor_mailbox_y (cursor_mailbox_y),
    .cursor_ack_toggle (cursor_ack_toggle),
    .video_out (cursor_rgb), .de_out (cursor_de), .vs_out (cursor_vs)
);

frame_read_write #(
    // Media board sends BMP rows in source order (bottom-up); preserve the
    // single-board V1 address mapping so HDMI scans the image upright.
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),   // 每行字数（RGB565 两像素/字：1280 像素/行 = 640 字）
    .FRAME_HEIGHT     (720),.VIEW_ENABLE(1),.STREAM_CLOCK(1)
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
    .read_addr_index   (view_video_layout==0 ? disp_buf_idx : {1'b0,view_video_buffer}),
    .stream_clk(eth_app_clk),
    .view_read_layout(view_video_layout),.view_valid_mask(view_video_mask),
    .view_window_buffers(view_video_window_buffers),.view_epoch(view_video_epoch),
    .view_drained_epoch(view_drained_epoch),.view_write_layout(view_write_layout),.view_write_window(view_write_window),
    .read_len          (FRAME_WORDS),
    .read_en           (video_read_en && !video_mode_active),
    .read_data         (video_read_data),
    .o_vid_rd_empty    (vid_rd_empty),
    .o_mem_rd_audio    (mem_rd_audio),
    .o_mem_rd_busy     (frame_rd_busy),
    .o_mem_wr_busy     (frame_wr_busy),
    .o_vid_fifo_words  (vid_fifo_words),
    .line_hold         (transition_line_hold || video_hold_old),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (media_write_req),
    .write_req_ack     (media_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (BUF2_ADDR),
    .write_addr_3      (BUF3_ADDR),
    .write_addr_index  (write_buf_idx),
    .write_len         (media_write_len),
    .vrow_off          (media_row_offset),
    .write_ready       (media_write_ready),
    .write_en          (media_write_en),
    .write_data        (media_write_data),

    .aud_read_req      (audio_read_req),
    .aud_read_req_ack  (audio_read_req_ack),
    .aud_read_finish   (audio_read_finish),
    .aud_read_addr_index(audio_read_index),
    .aud_read_len      (audio_read_length),
    .aud_rd_en         (audio_read_en),
    .aud_rd_data       (audio_read_data),
    .o_aud_fifo_words  (audio_read_fifo_words)
);

generate if(DISPLAY_DIAGNOSTICS)begin:g_acceptance_digest
display_frame_digest u_acceptance_digest (
    .mem_clk(ext_mem_clk), .app_clk(eth_app_clk), .producer_clk(eth_app_clk), .rst(rst_all),
    .video_ack(video_read_req_ack), .video_valid(frame_sdr_rd_valid),
    .video_audio(mem_rd_audio), .video_data(Sdr_rd_dout),
    .video_bank(view_video_layout==0 ? disp_buf_idx : {1'b0,view_video_buffer}),
    .write_valid(1'b0), .write_addr(App_wr_addr), .write_data(App_wr_din),
    .image_begin(1'b0), .source_words(media_write_len),
    .producer_start(1'b0),
    .raw_valid(1'b0), .raw_data(media_write_data),
    .padded_valid(1'b0),
    .padded_data(media_padded_stream_data),
    .rx_data(eth_rx_data), .rx_valid(eth_rx_valid),
    .tx_request(digest_req), .tx_valid(digest_valid), .tx_data(digest_data),
    .tx_length(digest_length), .tx_ready(digest_ready), .tx_ack(digest_ack)
);
end else begin:g_product_digest
    direct_video_feedback_tx #(.HEALTH_FLAGS_ENABLED(1),.AUDIO_STATUS_ENABLED(1),.READY_ENABLED(1),.HYBRID_STATUS_ENABLED(1),.CREDIT_STEP(4),.STATUS_ENABLED(DIRECT_VIDEO_STATUS)) u_direct_video_feedback_tx (
        .clk (eth_app_clk), .rst (rst_all),.health_flags({5'd0,audio_missing_sync[1],video_missing}),.ready_event(video_ready_event),.ready_sequence(video_ready_sequence),.ready_frame(video_ready_frame),
        .audio_stats(direct_audio_stats),.hybrid_stats(video_hybrid_stats),.readback_stats(video_readback_stats),.diagnostic_mode(1'b0),.reject_reason_stats(96'd0),.video_output_stats(96'd0),.memory_stats(96'd0),.memory_kind(2'd0),.memory_mode(1'b0),.output_color_mode(3'd0),
        .nack_event (video_nack_valid), .nack_sequence (video_nack_sequence),
        .credit_event (video_credit_update),
        .credit_next_sequence (video_credit_next_sequence),
        .free_row_credits (video_free_row_credits),
        .parser_accepted(video_parser_accepted),.parser_rejected(video_parser_rejected),
        .store_accepted(video_accepted_rows),.store_rejected(video_rejected_rows),
        .duplicate_rows(video_duplicate_rows),.underflow_gray_async(video_underflow_gray),
        .digest_req (digest_req), .digest_valid (digest_valid),
        .digest_data (digest_data), .digest_length (digest_length),
        .digest_ack (digest_ack)
    );
end endgenerate
transition_line_read transition_line_read_m0 (
    .mem_clk (ext_mem_clk), .rst (rst_all),
    .sdr_init_done (Sdr_init_done), .sdr_busy (Sdr_busy),
    .sdr_refresh (Sdr_init_ref_vld),
    .line_req_toggle (line_req_toggle), .line_num (line_num),
    .line_base (line_base),.row_words(transition_row_words),
    .line_ready_toggle (line_ready_toggle),
    .frame_rd_en (App_rd_en), .frame_rd_addr (App_rd_addr),
    .frame_wr_en (App_wr_en), .frame_rd_busy (frame_rd_busy),
    .frame_wr_busy (frame_wr_busy), .video_fifo_words (vid_fifo_words),
    .line_hold (transition_line_hold),
    .app_rd_en (mux_app_rd_en), .app_rd_addr (mux_app_rd_addr),
    .sdr_rd_valid (Sdr_rd_en && !video_memory_grant), .sdr_rd_data (Sdr_rd_dout),
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
    .App_wr_en         (video_memory_grant ? video_wr_en : App_wr_en),
    .App_wr_addr       (video_memory_grant ? video_wr_addr : App_wr_addr),
    .App_wr_dm         (video_memory_grant ? 4'd0 : App_wr_dm),
    .App_wr_din        (video_memory_grant ? video_wr_data : App_wr_din),
    .App_rd_en         (video_memory_grant ? video_rd_en : mux_app_rd_en),
    .App_rd_addr       (video_memory_grant ? video_rd_addr : mux_app_rd_addr),
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

    .I_audio_valid      (video_mode_active ? direct_audio_valid : aud_valid),
    .I_audio_left_data  (aud_l_v),
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

`timescale 1ns/1ps
// Temporary board-acceptance probe. Samples the actual SDRAM video return,
// never requests memory access. Not part of the production TD source list.
module display_frame_digest #(
    parameter integer WORDS = 460800,
    parameter [20:0] FIRST_ADDR0 = 21'd460160,
    parameter [20:0] BANK_WORDS = 21'd460800
)(
    input wire mem_clk, app_clk, producer_clk, rst,
    input wire video_ack, video_valid, video_audio,
    input wire [31:0] video_data,
    input wire [1:0] video_bank,
    input wire write_valid,
    input wire [20:0] write_addr,
    input wire [31:0] write_data,
    input wire image_begin,
    input wire producer_start,
    input wire [20:0] source_words,
    input wire raw_valid, padded_valid,
    input wire [31:0] raw_data, padded_data,
    input wire [7:0] rx_data,
    input wire rx_valid,
    output wire tx_request, tx_valid,
    output reg [7:0] tx_data,
    output wire [15:0] tx_length,
    input wire tx_ready, tx_ack
);
    localparam [31:0] WORD_COUNT = WORDS;
    reg ack_d, active;
    reg [18:0] count;
    reg [31:0] sum, hash;
    reg [15:0] frame_number;
    reg [1:0] bank;
    reg [127:0] last_frame, last_write;
    reg [511:0] snapshot_data_mem;
    reg [255:0] aux_snapshot_app;
    reg [127:0] last_raw, last_pad;
    reg raw_active,pad_active;
    reg [20:0] raw_count,pad_count,raw_target;
    reg [31:0] raw_sum,raw_hash,pad_sum,pad_hash;
    reg [15:0] raw_number,pad_number;
    wire [31:0] raw_sum_next=raw_sum+raw_data, pad_sum_next=pad_sum+padded_data;
    wire [31:0] raw_hash_next=((raw_hash<<5)+raw_hash)^raw_data;
    wire [31:0] pad_hash_next=((pad_hash<<5)+pad_hash)^padded_data;
    always @(posedge producer_clk or posedge rst) begin
        if(rst)begin last_raw<=0;raw_active<=0;raw_count<=0;raw_target<=0;
            raw_sum<=0;raw_hash<=0;raw_number<=0;end
        else if(producer_start)begin
            raw_active<=1;raw_target<=source_words;raw_count<=0;raw_sum<=0;raw_hash<=0;
        end else if(raw_active && raw_valid)begin
            raw_count<=raw_count+1'b1;raw_sum<=raw_sum_next;raw_hash<=raw_hash_next;
            if(raw_count+1'b1==raw_target)begin
                raw_active<=0;raw_number<=raw_number+1'b1;
                last_raw<={raw_hash_next,raw_sum_next,11'd0,raw_target,8'd0,8'hdd,raw_number};
            end
        end
    end
    reg wr_active;
    reg [18:0] wr_count;
    reg [31:0] wr_sum, wr_hash;
    reg [15:0] wr_number;
    reg [1:0] wr_bank;
    wire [31:0] wr_sum_next = wr_sum + write_data;
    wire [31:0] wr_hash_next = ((wr_hash << 5) + wr_hash) ^ write_data;
    reg request_toggle, reply_toggle;
    reg [2:0] request_sync, reply_sync;
    wire take_word = active && video_valid && !video_audio;
    wire [31:0] sum_next = sum + video_data;
    // Multiplication by 33 is a shift/add and remains sensitive to row order.
    // A rotate-XOR hash would alias whole 640-word rows (640 % 32 == 0).
    wire [31:0] hash_next = ((hash << 5) + hash) ^ video_data;
    always @(posedge mem_clk or posedge rst) begin
        if(rst) begin
            ack_d<=0;active<=0;count<=0;sum<=0;hash<=0;bank<=0;
            frame_number<=0;last_frame<=0;last_write<=0;snapshot_data_mem<=0;
            wr_active<=0;wr_count<=0;wr_sum<=0;wr_hash<=0;wr_number<=0;wr_bank<=0;
            request_sync<=0;reply_toggle<=0;
        end else begin
            ack_d<=video_ack;
            request_sync<={request_sync[1:0],request_toggle};
            if(request_sync[2]!=reply_toggle) begin
                snapshot_data_mem<={aux_snapshot_app,last_write,last_frame};
                reply_toggle<=request_sync[2];
            end
            if(video_ack && !ack_d) begin
                active<=1;count<=0;sum<=0;hash<=0;bank<=video_bank;
            end else if(take_word) begin
                sum<=sum_next;hash<=hash_next;count<=count+1'b1;
                if(count==WORDS-1) begin
                    active<=0;frame_number<=frame_number+1'b1;
                    last_frame<={hash_next,sum_next,WORD_COUNT,6'd0,bank,8'hd9,frame_number};
                end
            end
            if(write_valid && (write_addr==FIRST_ADDR0 || write_addr==BANK_WORDS+FIRST_ADDR0)) begin
                wr_active<=1;wr_count<=1;wr_sum<=write_data;wr_hash<=write_data;
                wr_bank<=write_addr>=BANK_WORDS ? 2'd1 : 2'd0;
            end else if(write_valid && wr_active && write_addr<(BANK_WORDS<<1)) begin
                wr_count<=wr_count+1'b1;wr_sum<=wr_sum_next;wr_hash<=wr_hash_next;
                if(wr_count==WORDS-1) begin
                    wr_active<=0;wr_number<=wr_number+1'b1;
                    last_write<={wr_hash_next,wr_sum_next,WORD_COUNT,6'd0,wr_bank,8'hda,wr_number};
                end
            end
        end
    end

    reg [10:0] pos;
    reg was_valid, magic_ok, match_type;
    reg [2:0] state;
    reg [6:0] byte_index;
    reg [511:0] payload;
    localparam IDLE=0, SNAPSHOT=1, REQUEST=2, SEND=3, WAIT_READY=4;
    assign tx_request=state==REQUEST;
    assign tx_valid=state==SEND;
    assign tx_length=16'd24;
    always @* begin
        case(byte_index)
            0:tx_data=8'haa;1:tx_data=8'hbb;2:tx_data=8'hcc;3:tx_data=8'hdd;
            4:tx_data=0;5:tx_data=8'h47;6:tx_data=0;7:tx_data=16;
            default:tx_data=payload[8*(byte_index-8)+:8];
        endcase
    end
    always @(posedge app_clk or posedge rst) begin
        if(rst) begin
            pos<=0;was_valid<=0;magic_ok<=0;match_type<=0;
            state<=IDLE;byte_index<=0;payload<=0;request_toggle<=0;reply_sync<=0;
            aux_snapshot_app<=0;last_pad<=0;pad_active<=0;pad_count<=0;
            pad_sum<=0;pad_hash<=0;pad_number<=0;
        end else begin
            was_valid<=rx_valid;
            reply_sync<={reply_sync[1:0],reply_toggle};
            if(image_begin)begin
                pad_active<=1;pad_count<=0;pad_sum<=0;pad_hash<=0;
            end else begin
                if(pad_active && padded_valid)begin
                    pad_count<=pad_count+1'b1;pad_sum<=pad_sum_next;pad_hash<=pad_hash_next;
                    if(pad_count==WORDS-1)begin
                        pad_active<=0;pad_number<=pad_number+1'b1;
                        last_pad<={pad_hash_next,pad_sum_next,WORD_COUNT,8'd0,8'hdc,pad_number};
                    end
                end
            end
            if(rx_valid) begin
                pos<=pos+1'b1;
                case(pos)
                    0:begin magic_ok<=rx_data==8'haa;match_type<=0;end
                    1:magic_ok<=magic_ok && rx_data==8'hbb;
                    2:magic_ok<=magic_ok && rx_data==8'hcc;
                    3:magic_ok<=magic_ok && rx_data==8'hdd;
                    4:match_type<=rx_data==0;
                    5:match_type<=match_type && rx_data==8'h47;
                    6:match_type<=match_type && rx_data==0;
                    7:match_type<=match_type && rx_data==0;
                    default:;
                endcase
            end else begin
                pos<=0;
                if(was_valid && magic_ok && match_type && pos==8 && state==IDLE) begin
                    request_toggle<=~request_toggle;
                    aux_snapshot_app<={last_pad,last_raw};
                    state<=SNAPSHOT;
                end
            end
            case(state)
                SNAPSHOT:if(reply_sync[2]==request_toggle) begin
                    payload<=snapshot_data_mem;state<=WAIT_READY;
                end
                WAIT_READY:if(tx_ready)state<=REQUEST;
                REQUEST:if(tx_ack)begin byte_index<=0;state<=SEND;end
                SEND:if(byte_index==23)state<=IDLE;else byte_index<=byte_index+1'b1;
                default:;
            endcase
        end
    end
endmodule

`timescale 1ns/1ps
// Isolated acceptance builds only. V1 type 004B / length 4 supplies LE x,y to
// the view manager, allowing unattended tests to select every window. It does
// not replace or enter the product GT911/cursor renderer or source-file list.
module display_test_cursor(
    input wire clk,rst,
    input wire [7:0] data,
    input wire valid,
    output reg enabled,
    output reg [10:0] x,
    output reg [9:0] y
);
    reg [4:0] position;
    reg [15:0] kind,length,px,py;
    reg good;
    always @(posedge clk or posedge rst)begin
        if(rst)begin position<=0;kind<=0;length<=0;px<=0;py<=0;
            good<=0;enabled<=0;x<=640;y<=360;end
        else if(valid)begin
            if(position!=31)position<=position+1'b1;else good<=0;
            case(position)
                0:good<=data==8'haa;1:good<=good && data==8'hbb;
                2:good<=good && data==8'hcc;3:good<=good && data==8'hdd;
                4:kind[15:8]<=data;5:kind[7:0]<=data;
                6:length[15:8]<=data;7:length[7:0]<=data;
                8:px[7:0]<=data;9:px[15:8]<=data;
                10:py[7:0]<=data;11:py[15:8]<=data;
            endcase
        end else begin
            if(good && kind==16'h004b && length==4 && position==12 && px<1280 && py<720)begin
                enabled<=1;x<=px[10:0];y<=py[9:0];
            end
            position<=0;
        end
    end
endmodule
