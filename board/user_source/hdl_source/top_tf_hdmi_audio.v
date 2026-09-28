
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 手动下一张
    input                       key2,           // 自动播放 开/关
    input                       uart_rx,        // CH340G USB-UART（1Mbaud 8N1）
    output                      uart_tx,

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
wire [6:0]  seg_data_0;
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
reg de_0_d, line_seen;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        vid_und_stick_v <= 1'b0;
        de_0_d   <= 1'b0;
        line_seen <= 1'b0;
    end else begin
        de_0_d <= de_0;
        if (vs_0)
            line_seen <= 1'b0;
        else if (de_0_d && !de_0)
            line_seen <= 1'b1;
        if (de_0 && vid_rd_empty && line_seen)
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

// ===================== UART 交互通道（v1：虚拟按键 + 状态回读） =====================
// sd_card_clk 域，命令消费方（sd_card_bmp 去抖）同域免 CDC；协议见 uart_link.v 头
wire vk_next_n, vk_auto_n;

uart_link #(
    .CLK_FREQ_HZ    (100_000_000),
    .BAUD           (1_000_000),
    .VK_PULSE_CYC   (10_000_000)       // 100ms，须明显大于 sd_card_bmp 的 50ms 去抖窗
) uart_link_m0(
    .clk            (sd_card_clk),
    .rst            (rst_all),
    .rx             (uart_rx),
    .tx             (uart_tx),
    .vk_next_n      (vk_next_n),
    .vk_auto_n      (vk_auto_n),
    .state_code     (state_code),
    .dbg_fat_state  (dbg_fat_state),
    .flag_a         ({video_pll_lock, sys_pll_lock, Sdr_init_done, display_valid}),
    .flag_b         ({hdmi_locked, dbg_fat_err, disp_buf_idx[1], disp_buf_idx[0]}),
    .dbg_underrun   (dbg_underrun)
);

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

seg_decoder seg_decoder_m0(
    .bin_data          (state_code),
    .seg_data          (seg_data_0)
);

// 调试面板：digit4=fat状态高4位 digit3=fat状态低4位
// digit2={video_pll_lock, sys_pll_lock, Sdr_init_done, display_valid}
// digit1={hdmi_locked, dbg_fat_err, disp_buf_idx[1:0]}（bit3..0）
wire [6:0] seg_fat_hi, seg_fat_lo, seg_flag_a, seg_flag_b, seg_und;
seg_decoder u_seg_fat_hi (.bin_data(dbg_fat_state[7:4]), .seg_data(seg_fat_hi));
seg_decoder u_seg_fat_lo (.bin_data(dbg_fat_state[3:0]), .seg_data(seg_fat_lo));
seg_decoder u_seg_flag_a (.bin_data({video_pll_lock, sys_pll_lock,
                                     Sdr_init_done, display_valid}),
                          .seg_data(seg_flag_a));
seg_decoder u_seg_flag_b (.bin_data({hdmi_locked, dbg_fat_err,
                                     disp_buf_idx[1], disp_buf_idx[0]}),
                          .seg_data(seg_flag_b));
// d0 = {vid_und_stick, aud_und_stick, 2'b00}：视频 FIFO 下溢 / 音频欠载粘滞
seg_decoder u_seg_underrun (.bin_data(dbg_underrun), .seg_data(seg_und));

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,seg_und}),
    .seg_data_4        ({1'b1,seg_fat_hi}),
    .seg_data_3        ({1'b1,seg_fat_lo}),
    .seg_data_2        ({1'b1,seg_flag_a}),
    .seg_data_1        ({1'b1,seg_flag_b}),
    .seg_data_5        ({1'b1,seg_data_0})
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
assign vout_data = display_valid ? vout_data_raw : 24'd0;

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
    .I_audio_left_data  (aud_l),
    .I_audio_right_data (aud_r),
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
