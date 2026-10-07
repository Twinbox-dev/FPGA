// =============================================================================
// sd_card_bmp.v — SD 卡图像控制（FAT32 版）
// -----------------------------------------------------------------------------
// 本模块把例程的「原始扇区线性扫描」方案换成正宗 FAT32 只读解析：
//
//   TF卡 ── sd_card_top(SPI+init，板上已验证) ──► sd_adapter ──► fat32_ro ──► bmp_dec ──► frame_write
//                                                  ▲                                     │
//                                                   └────── 扇区读协议翻译 ───────────────┘
//
// 模块名/端口与例程版本完全一致，top_tf_hdmi_audio.v 无需改动。
// fat32_ro / bmp_dec 为仿真侧（anlogic 仓库）验证通过的原样移植；板级差异只有两点：
//   1. 复位极性：本模块 rst 高有效 → 子模块接 ~rst；
//   2. fat32_ro 的扇区读协议（o_req/o_lba/i_ready/i_dval/i_done/i_err）经 sd_adapter
//      适配到 sd_card_top 的 sd_sec_read 协议（电平请求 + 数据有效 + end 一拍）。
//   板上 sd_card_top 无错误上抛（坏扇区会在 CMD17 重试），故 i_err 恒 0，
//   恢复靠本模块 1s 装载超时——与例程行为一致。
//
// 装载顺序（关键，与 frame_fifo_write 语义配套）：
//   空闲 → 先开写通道（write_req 保持到 ack，存储侧借此清写 FIFO 并锁存长度）
//        → 再向 fat32_ro 发文件请求。顺序反了会把上一张图的残留像素算进这一张。
//
// 完成判定：bmp_dec 的 o_img_ok（整图字节处理完、头校验通过）且 write_finish 已同步到
//   （整帧真正落盘）→ 切换显示缓冲。坏图（o_img_err）立即放弃不提交，旧图继续显示，
//   光标推进跳过，轮播不会卡死在坏图上。
//
// 轮播控制逻辑与仿真侧 top.v 一致：挂载后自动加载第一个图片项（跳过 WAV 项），
// key_next 切下一张（到尾回绕、跳过音频项），装载中按键排队到文件完成。
//
// 音频扫描相位（S1，boot 一次性）：首图提交后若卡内有 WAV，顺序遍历播放列表，
//   逐个请求 WAV 项送 wav_reader 解析（fmt 硬校验 24k/8bit/mono），解析结果与
//   PCM 字节流由 boardtest 逐字节比对。扫描完成后才开放按键/自动轮播。
//   图像装载与音频扫描共用单 fat32_ro（文件级分时，无需 SD 仲裁）。
//
// 音频写 SDRAM（S2）：合法 WAV 的样本字节同时 4 字节打包成字，复用写口装入
//   BUF2（write_buf_idx=2），长度 = ceil(dbytes/4) 取整 256（突发整除约束），
//   尾补 0x80。写口在图像装载（buf 0/1）与音频扫描（buf 2）间分时复用。
//
// 同名配对 + 原子提交（S4）：
//   扫描相位前导保留原等待拍数；配对时直接查询 fat32_ro 的播放列表主名；
//   合法 WAV 项关闭时顺序比对 BMP 名，建 pair_valid/pair_wav/wav_len_rec 配对表。
//   切图 N+1 时：图入空闲 BUF0/1，配对 WAV 重读入空闲音频缓冲 BUF2/3
//   （aud_disp_buf 乒乓，与 disp_buf_idx 同节奏），图完成且音频写尽后
//   **同一拍**切 display_valid/disp_buf_idx 并 aud_cmt_valid 握手通知播放域换源。
//   无配对 → 播放域进静音态（aud_valid=1, 样本 0，不开读通道）。
//   WAV 随图循环重播：一路放完自动回卷（aud_play_done 脉冲一拍）。
//   播放域为 en25（clk/4 使能）子域，与主域同 clk，握手电平直接共享无时序风险。
// =============================================================================

module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,      // 保留参数（兼容 top 例化）
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4,
    parameter         ENABLE_LIST_DIAG  = 1'b1
)(
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       key_auto,
    input                       key_prev,
    input  [3:0]                auto_period_s,   // 自动轮播周期（秒，1..10；ctrl_core 可调）
    input  [15:0]               bmp_width,     // 保留（bmp_dec 内部硬编码 640x480）
    input  [15:0]               bmp_height,
    output reg                  display_valid,
    output      [3:0]           state_code,
    // ---- UART 遥测：当前图索引 / 该图是否配同名 WAV（状态包保留字节）----
    output      [4:0]           img_idx_out,   // 当前/最近尝试的图索引（5bit，≤31）
    output                      img_wav_out,   // 该图有合法同名 WAV
    output                      auto_play_out, // 自动轮播开关当前状态（遥测：ACK/状态包）
    // ---- 板级调试面板：fat32 FSM 状态 / 错误锁存（接数码管空位）----
    output      [7:0]           dbg_fat_state,
    output                      dbg_fat_err,

    // ---- 播放列表转储（'L' 调试命令）：ctrl_core 发起，逐条目 64bit 包回吐 ----
    input                       pl_dump_start,
    output      [63:0]          pl_pkt,        // 线序：uart_link LSB 字节先行，此处已反转
    output                      pl_pkt_val,
    output      [7:0]           ld_diag,       // 装载诊断：{0,result[1:0],ld[2:0],busy,img_wav}

    // ---- 写侧分叉探针：图像会话发射字同步馈以太网流（撕裂取证/上位机预览）----
    output      [31:0]          tap_word,      // 发射字（2 像素 RGB565）
    output                      tap_val,       // tap_word 有效（图像会话期间）
    output                      tap_end,       // 会话结束脉冲（离开 LD_STREAM，含弃载）

    input                       write_finish_toggle,
    // ---- 读侧 dump 触发（'D' 手动 / 装载提交自动）：捕获窗在 top 的 video 域
    //      圈取显示读数据（video_read_data）——不碰读引擎、不借音频通道 ----
    input                       rdump_start,       // 'D' 手动触发脉冲（ctrl_core）
    output                      dmp_trig,          // 读回捕获触发（toggle 源，本域脉冲）（冲洗 FIFO）
    output reg  [1:0]           disp_buf_idx,
    input                [1:0]  effect_mode,       // 0=cut, 1=fade, 2=soft wipe
    output reg                  transition_start_toggle,
    output reg                  transition_target_buf,
    output reg  [1:0]           transition_mode_latched,
    output reg                  transition_prev_latched,
    input                       transition_done_toggle,

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    output [1:0]                write_buf_idx,   // 0/1=图像乒乓  2=音频 BUF2
    output [20:0]               write_len,
    output [19:0]               o_wr_vrow_off, // 信箱行偏移（字）：vflip 首行 = y0+h-1 行（居中）       // 本次写通道长度（字）：图像 img_h*640（信箱适配，720p 时 460800）/ 音频取整 256
    // ---- 音频扫描观测（S1：boot 后一次性遍历卡内 WAV，供 boardtest 比对）----
    output      [7:0]           aud_smp,
    output                      aud_sval,
    output                      aud_item_done,   // 一个 WAV 项流完（脉冲）
    output                      aud_scan_done,   // 全部 WAV 项遍历完（电平）
    output                      wav_hdr_ok,      // 最近一项头合法（电平）
    output                      wav_fmt_err,     // 最近一项格式拒绝（电平）
    output      [31:0]          wav_data_bytes,  // 最近一项 data 块声明长度
    // ---- 音频播放（S3）：读口顺序读 BUF2，24k 节拍 ×2 上采样 → 48k HDMI 口 ----
    output reg                  aud_valid,
    output reg  [23:0]          aud_l,
    output reg  [23:0]          aud_r,
    output                      aud_play_done,   // 一路自然放完（脉冲一拍，随后回卷重播）
    output                      aud_underrun,    // 播放读空（脉冲，应恒 0）
    output                      aud_tick,        // 48k 采样节拍（100M 域 1 拍宽，仿真采样用）
    output                      aud_pair_on,     // 当前在放配对 WAV（0=静音态，S4 检查用）
    output                      rd_req,
    output                      rd_en,
    output      [1:0]           rd_addr_idx,
    output      [20:0]          rd_len,
    input                       rd_req_ack,
    input                       rd_finish,
    input       [31:0]          rd_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO,

    // ---- SIM_FAST 直连扇区服务器（fast_en=1 选中，见 stub_sd_card_top.v）----
    input                       fast_en,
    input                [7:0]  fast_byte,
    input                       fast_val,
    output               [31:0] fast_lba,
    output                [9:0] fast_idx,
    output                      fast_serving
);

    // ==================== 声明区（先声明后使用，TD 解析要求） ====================

    // ---- 键去抖 ----
    wire key_next_press;
    wire key_auto_press;
    wire key_prev_press;

    // ---- 扇区读通道（fat32_ro 主机 / sd_card_top 从机，经适配器） ----
    wire        sd_init_done;
    wire [31:0] sec_lba;
    wire        sec_req, sec_ready, sec_dval, sec_done, sec_err;
    wire [7:0]  sec_data;

    // ---- 文件字节流 / 状态 ----
    wire [7:0]  file_byte;
    wire        file_bval, file_done;
    wire        fat_mounted, fat_idle, fat_err, cur_is_wav /*verilator public_flat_rd*/;
    wire [5:0]  file_cnt, bmp_cnt, wav_cnt, type_map;
    wire [5:0]  first_bmp_w /*verilator public_flat_rd*/;          // fat32_ro 建：首个 BMP 索引（轮播起点）
    wire [191:0] bmp_nxt_map;         // fat32_ro 建：BMP 循环下一跳表（6bit × 32）
    wire [191:0] bmp_prv_map;         // fat32_ro 建：BMP 循环上一跳表（6bit × 32）
    wire [7:0]  fat_dbg, bmp_dbg;
    wire        img_ok, img_err /*verilator public_flat_rd*/;
    wire        pix_val;
    wire [23:0] pix;

    // ---- 播放列表查找口（音频扫描 / 后续同名配对用）----
    wire        pl_is_wav;
    wire        pl_valid;
    wire [63:0] pl_name;

    // ---- wav_reader ----
    wire [7:0]  wav_smp;
    wire        wav_sval;
    wire        w_hdr_ok, w_fmt_err;
    wire [31:0] w_data_bytes;

    // ---- 适配器 / SD 从机 ----
    wire        sd_sec_read;
    wire [31:0] sd_sec_read_addr;
    wire [7:0]  sd_sec_read_data;
    wire        sd_sec_read_data_valid;
    wire        sd_sec_read_end;

    // ---- 写帧（frame_read_write 写口） ----
    reg         write_req_r /*verilator public_flat_rd*/;
    reg  [1:0]  write_buf_idx_r;      // 图像装载目标缓冲（音频扫描期输出被 mux 成 2/BUF2）

    // ---- 装载序列 FSM ----
    // 2026-10-03 多分辨率信箱适配：装载序列重排
    //   LD_FILL_*（全帧涂黑会话，垫掉非图像区）→ LD_FILE（请求文件，等头）
    //   → LD_IMG_ACK（按 img_h*640 开图像写会话）→ LD_IMG_SETTLE（等 FIFO 清零释放）
    //   → LD_STREAM（信箱发射）。
    //   720p 图像在此路径下行为与旧版一致（x0=y0=0、len=460800）。
    localparam [2:0] LD_IDLE     = 3'd0,
                     LD_FILL_REQ = 3'd1,   // 涂黑会话握手
                     LD_FILL_RUN = 3'd2,   // 涂黑数据推行（等 finish）
                     LD_FILE     = 3'd3,   // 文件请求（图像等 hdr，音频发完即回）
                     LD_IMG_WAIT = 3'd4,   // 等 BMP 头校验（拿 img_w/h 定 len）
                     LD_IMG_ACK  = 3'd5,   // 图像写会话握手（len = img_h*640）
                     LD_STREAM   = 3'd6,   // 信箱发射（等 finish → write_done_seen）
                     LD_IMG_SETTLE = 3'd7; // ACK 后等写 FIFO 异步清零跨域释放
    reg [2:0] ld_state /*verilator public_flat_rd*/;
    reg [3:0] img_settle_cnt;
    reg       file_req;
    reg [4:0] file_idx /*verilator public_flat_rd*/;
    reg       aud_item_done_pulse;

    // ---- 装载诊断快照（ACK 诊断位 + 'L' tag11 包）：2026-10-04 板级"多分辨率图
    //      装载挂死"排查。每次装载尝试在发起/终止点留痕，任何一次按键的 ACK 都
    //      能看到上一次尝试卡在哪个阶段。result：0 进行中/无 1 img_err 2 超时 3 提交
    reg [1:0]  ld_result;
    reg [20:0] snap_len;     // 终止时写口长度（字）
    reg [11:0] snap_w, snap_h;   // 终止时锁存图像尺寸
    reg [2:0]  snap_ld /*verilator public_flat_rd*/;      // 终止时 ld_state（7=音频装载段超时）
    reg [20:0] emit_cnt;     // 本次装载已发射字数（发射块自证进度）
    reg [20:0] snap_words;   // 终止时发射字数：0=发射器没跑/中途=断流/=len=引擎不收尾
    reg [19:0] pix_cnt;      // 本次装载解码器已产出像素数（源自证进度）
    reg [19:0] snap_pix;     // 终止时解码像素数：0=解码没跑/中途=断流/=w*h=解码完毕

    // ---- 外控 ----
    reg [2:0]  wrfin_tgl_sync;
    wire       write_finish_pulse;
    wire       auto_tick;
    reg        load_start_pulse;      // 装载发起一拍（同时复位 bmp_dec）
    reg [5:0]  load_idx /*verilator public_flat_rd*/;              // 当前装载的播放列表索引
    reg [5:0]  img_idx;               // 轮播光标（当前显示/最近尝试的图片索引）
    reg [5:0]  first_idx_r;           // 首图候选（坏图时推进，避免上电卡死在坏图）
    reg        first_idx_captured /*verilator public_flat_rd*/;
    reg [1:0]  pending_buf_idx;       // 当前装载目标缓冲
    reg        load_busy /*verilator public_flat_rd*/;
    reg        write_done_seen;       // 整帧已落盘（write_finish 同步后）
    reg        first_image_committed;
    reg        auto_play_en;
    reg [31:0] auto_cnt;
    reg [31:0] load_timeout_cnt;
    reg        next_req_pending /*verilator public_flat_rd*/;
    reg        prev_req_pending /*verilator public_flat_rd*/;
    reg        load_direction_prev;
    reg [1:0]  load_effect_mode;
    reg        transition_pending;
    reg [27:0] transition_timeout_cnt;
    reg [2:0]  transition_done_sync;
    wire       transition_done_pulse = transition_done_sync[2] ^ transition_done_sync[1];
    reg [5:0]  transition_img_idx;
    reg [1:0]  transition_disp_buf;
    reg        transition_cmt_pair;
    reg [1:0]  transition_cmt_buf;
    reg [20:0] transition_cmt_len;
    reg [1:0]  transition_aud_buf;

    // ---- 音频扫描相位（S1）----
    reg        aud_scan_active /*verilator public_flat_rd*/;
    reg        aud_scan_done_r /*verilator public_flat_rd*/;
    reg [5:0]  aud_k;                 // 播放列表扫描游标
    reg        aud_item_active;       // 一个 WAV 项正在流
    reg        aud_req_pulse;         // 扫描项踢脉冲：复位 wav_reader（文件请求
                                      // 本体改由装载 FSM 发出，见 scan_kick）
    reg        scan_kick;             // 扫描项 → 装载 FSM 的文件请求踢（⚠ 唯一写方=
                                      // 外控/扫描块；本装载 FSM 只读——多驱动 TD 必炸）
    reg        scan_req_active;       // 装载 FSM 正在替扫描发文件请求（idx 选择用）
    reg [4:0]  aud_req_idx /*verilator public_flat_rd*/;           // 请求索引锁存（pulse 下一拍可见，fat 采样此值）

    // ---- 音频打包器 / 写通道（S2：PCM 字节 → 32 位字 → BUF2）----
    localparam [2:0] P_IDLE = 3'd0, P_WAIT_HDR = 3'd1, P_ACK = 3'd2,
                     P_STREAM = 3'd3, P_PAD = 3'd4, P_DONE = 3'd5;
    reg [2:0]  pstate /*verilator public_flat_rd*/;
    reg        aud_wr_req /*verilator public_flat_rd*/;            // 音频写通道请求（保持到 ack）
    reg        aud_wr_active;         // 写通道已 ack，可以推字
    reg [20:0] aud_wr_len;            // 本项写长度（字）= ceil(dbytes/4) 取整 256
    reg [20:0] aud_wr_cnt;            // 已推字数
    reg [31:0] word_asm;              // 组装中的字（第 k 字节在 [8k+7:8k]）
    reg [2:0]  byte_cnt;              // 当前字内已装字节数 0..3
    reg [31:0] byte_total;            // 本项已收样本字节数
    reg        aud_fin_seen;          // 本项 write_finish 已见
    reg        aud_eof_seen;          // 本项文件流已结束（file_done）

    // 组字：新字节按 byte_cnt 落位，不足 4 字节的高位补 0x80（静音）
    reg  [31:0] word_now;
    always @(*) begin
        case (byte_cnt)
            3'd0:    word_now = {24'h808080, wav_smp};
            3'd1:    word_now = {16'h8080,   wav_smp, word_asm[7:0]};
            3'd2:    word_now = {8'h80,      wav_smp, word_asm[15:0]};
            default: word_now = {            wav_smp, word_asm[23:0]};
        endcase
    end
    wire aud_last_byte  = (byte_total + 32'd1 >= w_data_bytes); // smp 是本项最后一字节
    wire aud_word_done  = (byte_cnt == 3'd3) || aud_last_byte;  // 本拍凑齐/收尾一字
    wire aud_item_close = aud_eof_seen && (aud_fin_seen || !aud_wr_active);
    // 拒绝项（fmt_err）不开写通道：aud_wr_active 恒 0，file_done 即关闭
    wire aud_word_val = aud_wr_active &&
                        ((pstate == P_STREAM && wav_sval && aud_word_done)
                         || pstate == P_PAD);
    wire [31:0] aud_word = (pstate == P_PAD) ? 32'h80808080 : word_now;

    // ---- 音频播放（S3/S4）：25M 使能域（clk/4），读口顺序读当前音频缓冲 BUF2/3 ----
    localparam [2:0] PL_WAIT = 3'd0, PL_REQ = 3'd1, PL_RUN = 3'd2, PL_SIL = 3'd3,
                     PL_REQ2 = 3'd4;   // PL_REQ 内换源：先撤一拍 req 再重请求（见该分支注释）
    reg [2:0]  plstate /*verilator public_flat_rd*/;
    reg [1:0]  div25;
    reg        rd_req_r, rd_en_r;
    reg        pb_pair;               // 当前播放：1=配对 WAV / 0=静音
    reg [1:0]  pb_buf;                // 当前播放的音频缓冲（2/3）
    reg [20:0] pb_len /*verilator public_flat_rd*/;                // 当前播放长度（字）
    reg        ch_open, ch_closed, rd_outst /*verilator public_flat_rd*/;
    // 读口返回信号（ext_mem_clk 域）→ 本域双拍同步（电平语义，延迟 2 拍无害；
    // 直跨在 STA 上报 -1.4ns 违例，且亚稳态会丢 finish/ack）
    reg        rd_ack_s0, rd_ack_s1, rd_fin_s0, rd_fin_s1;
    reg        have_cur, have_nxt /*verilator public_flat_rd*/;
    reg [31:0] cur_word, nxt_word /*verilator public_flat_rd*/;
    reg [2:0]  byte_pos /*verilator public_flat_rd*/;              // 当前字内样本字节 0..3
    reg        phase /*verilator public_flat_rd*/;                 // 同一 24k 样本的两次 48k 输出
    reg [9:0]  tick_cnt;
    reg        aud_play_done_r, aud_underrun_pulse;
    reg        aud_tick_r;

    // ---- 同名配对（S4）：名字快照 + BMP↔WAV 配对表 ----
    reg        scan_start_pulse;      // 外控→扫描相位：启动扫描（单写方：外控块）
    reg        scan_nowav_pulse;      // 外控→扫描相位：无 WAV 直接置 scan_done（单写方：外控块）
    reg        npass_active;          // 保留原播放列表前导等待拍数
    reg [5:0]  npass_k;
    reg [63:0] aud_cur_name;          // 当前扫描项名字（请求拍锁存）
    reg        pmatch_active;         // 合法项关闭后顺序比对 BMP 名
    reg [5:0]  pmatch_j;
    reg [31:0] pair_valid /*verilator public_flat_rd*/;            // 位 j = BMP j 有合法同名 WAV
    reg [5:0]  pair_wav    [0:31] /*verilator public_flat_rd*/;    // BMP j → WAV 索引
    reg [20:0] wav_len_rec [0:31];    // WAV k 可播长度（字）

    // ---- 音频随图装载（S4）：配对 WAV 重读入空闲 BUF2/3，就绪后与图原子提交 ----
    reg        ald_active /*verilator public_flat_rd*/;            // 音频装载子相位（占用写口/打包器）
    reg        ald_start_pulse;       // 请求拍：restart wav_reader + 触发打包器
    reg        boot_ald;              // 本次 ald 为 boot 首图配对（完成时不切图只换音）
    reg        ald_boot_done /*verilator public_flat_rd*/;         // boot 音频已安排（防重复）
    // ---- 音频 boot 自愈看门狗（2026-10-03，见 TODO 第十七轮）----
    reg [29:0] aud_wd_cnt;            // 8s @ 100MHz = 800_000_000
    reg        aud_rescan;            // 重扫描在途（期间封锁 boot_ald 触发，防旧数据竞争）
    reg [1:0]  aud_retry_cnt;         // 已重试次数（上限 3；播放成功即清零）
    wire       aud_playing;           // 播放域真实出声（PL_RUN）
    reg        ld_kick;               // 主域→装载 FSM：直接发文件请求（音频先发文件后开写口）
    reg [5:0]  ald_wav_idx /*verilator public_flat_rd*/;
    reg [1:0]  ald_buf;               // 目标音频缓冲（aud_disp_buf 的对侧）
    reg [1:0]  aud_disp_buf;          // 当前音频显示缓冲（播放读口指向）

    // ---- 播放提交握手（主域 → en25 播放子域；同 clk，电平直接共享）----
    reg        aud_cmt_valid, aud_cmt_taken /*verilator public_flat_rd*/;
    reg        cmt_pair;
    reg [1:0]  cmt_buf;
    reg [20:0] cmt_len;
    wire       cmt_new = aud_cmt_valid && !aud_cmt_taken;

    wire       en25    = (div25 == 2'd0);
    wire       tick48  = (tick_cnt == 10'd520);   // 25M ÷ 521 ≈ 47.985kHz
    wire [7:0] cur_byte = (byte_pos == 3'd0) ? cur_word[7:0]   :
                          (byte_pos == 3'd1) ? cur_word[15:8]  :
                          (byte_pos == 3'd2) ? cur_word[23:16] :
                                               cur_word[31:24];
    // u8 无符号 → s24：({16'd0,b} - 128) << 16（回绕即二进制补码）
    wire [23:0] cur_samp = ({16'd0, cur_byte} - 24'd128) << 16;

    assign rd_req      = rd_req_r;
    assign rd_en       = rd_en_r;
    assign rd_addr_idx = pb_buf;      // S4 随音频显示缓冲乒乓（BUF2/3）
    assign rd_len      = pb_len;
    assign aud_play_done = aud_play_done_r;
    assign aud_underrun  = aud_underrun_pulse;
    assign aud_pair_on   = pb_pair;
    // 100M 域 1 拍宽脉冲：与 aud_valid/aud_l 同拍更新，仿真可在脉冲高电平期间稳定采样
    always @(posedge clk or posedge rst)
        if (rst) aud_tick_r <= 1'b0;
        else     aud_tick_r <= en25 & tick48;
    assign aud_tick      = aud_tick_r;

    // ---- 读口返回（ext_mem_clk 域）双拍同步进本域 ----
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rd_ack_s0 <= 1'b0; rd_ack_s1 <= 1'b0;
            rd_fin_s0 <= 1'b0; rd_fin_s1 <= 1'b0;
        end
        else begin
            rd_ack_s0 <= rd_req_ack; rd_ack_s1 <= rd_ack_s0;
            rd_fin_s0 <= rd_finish;  rd_fin_s1 <= rd_fin_s0;
        end
    end

    // ---- 组合 ----
    wire [5:0] next_idx;
    wire [5:0] prev_idx;

    // ==================== 函数 ====================
    // 轮播下一跳由 fat32_ro 在挂载扫目录时逐拍建表（o_bmp_nxt / o_first_bmp），
    // 此处仅做查表——原 next_bmp_idx/first_bmp_idx 组合函数是 33 级链（27ns，时序爆炸根因）。
    function [1:0] next_buf_lut;
        input [1:0] cur_disp_buf;
        input       valid_now;
        begin
            if (!valid_now)
                next_buf_lut = 2'd0;
            else if (cur_disp_buf == 2'd0)
                next_buf_lut = 2'd1;
            else
                next_buf_lut = 2'd0;
        end
    endfunction

    // ============ 图像信箱适配打包器（多分辨率 → 720p 帧，2 像素/字）============
    // bmp_dec 吐「图像自身分辨率」w*h（<=720p）的 24b {R,G,B} 像素流；发射 FSM
    // 按流序（图像行序，自底向上）逐行输出 1280 像素：行内水平窗口 [x0, x0+w)
    // 弹缓冲像素，窗口外补黑（24'd0 → 565 字 0）。垂直边距不在发射流里——写引擎
    // 的 vrow_off 把 h 行落到帧的 [y0, y0+h-1]（居中），帧内其余行由先行**全帧
    // 涂黑会话**（LD_FILL）垫黑。word = {pix1, pix0}（565），低半字 = 偶数下标
    // 像素，与读侧解包/串行化约定一致（video_delay）。
    //
    // 弹性缓冲 64*24：源（SPI，~1px/96clk）远慢于汇（写口 1px/clk）——行边距注
    // 入期间源最多积压 ~14 px，64 深 = 4 倍裕量。刻意用小触发器堆而非大 BRAM：
    // audio_fifo 2048 深度被 TD 摊成 9k LUT、加 pragma 又因 >1024 级联失败的
    // 教训（TODO 第七/八轮）；本深度不可能触发该病理。
    function [15:0] px565_f;
        input [23:0] p;
        begin
            px565_f = {p[23:19], p[15:10], p[7:3]};
        end
    endfunction

    reg  [23:0] ibuf [0:63];
    reg  [5:0]  ibuf_wptr, ibuf_rptr;
    reg  [6:0]  ibuf_level;
    wire        ibuf_full  = (ibuf_level >= 7'd64);
    wire        ibuf_empty = (ibuf_level == 7'd0);
    wire        ibuf_push  = pix_val && !ibuf_full;   // 满 = 丢像素（分析上不可达，
                                                      // 兜底防地址回卷）
    wire        in_h       = (emit_col >= x0_l) && (emit_col < x0_l + img_w_l);
    // 发射决策：图像窗口内弹缓冲（空则等——源一定会来）；窗口外补黑（无条件）
    wire        emit_go    = img_emit_en && (in_h ? !ibuf_empty : (pad_pace_cnt == 2'd0));
    wire        pop_en     = img_emit_en && in_h && !ibuf_empty;   // 缓冲弹出（发射块给出，缓冲块消费）
    wire [23:0] px_src     = in_h ? ibuf[ibuf_rptr] : 24'd0;

    reg  [15:0] img_pix0_hold;
    reg         img_have_pix0;
    reg         img_word_val;
    reg         pad_done;                 // 会话末尾填充字已发（补偿 FIFO 输出寄存器在途字）
    reg         emit_seen;                // 本次会话 img_emit_en 曾升起（pad 只许在收尾发）
    reg  [31:0] img_word;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ibuf_wptr     <= 6'd0;
            ibuf_rptr     <= 6'd0;
            ibuf_level    <= 7'd0;
            img_pix0_hold <= 16'd0;
            img_have_pix0 <= 1'b0;
            img_word_val  <= 1'b0;
            img_word      <= 32'd0;
            emit_cnt      <= 21'd0;
            pix_cnt       <= 20'd0;
            pad_done      <= 1'b0;
            emit_seen     <= 1'b0;
        end
        else if (load_start_pulse) begin
            ibuf_wptr     <= 6'd0;
            ibuf_rptr     <= 6'd0;
            ibuf_level    <= 7'd0;
            img_have_pix0 <= 1'b0;
            img_word_val  <= 1'b0;
            emit_cnt      <= 21'd0;
            pix_cnt       <= 20'd0;
            pad_done      <= 1'b0;
            emit_seen     <= 1'b0;
        end
        else begin
            // 缓冲指针/水位（推=解码像素流；弹=发射窗口内取用）
            case ({ibuf_push, pop_en})
                2'b10: begin
                    ibuf[ibuf_wptr] <= pix;
                    ibuf_wptr  <= ibuf_wptr  + 1'b1;
                    ibuf_level <= ibuf_level + 1'b1;
                end
                2'b01: begin
                    ibuf_rptr  <= ibuf_rptr  + 1'b1;
                    ibuf_level <= ibuf_level - 1'b1;
                end
                2'b11: begin
                    ibuf[ibuf_wptr] <= pix;
                    ibuf_wptr  <= ibuf_wptr  + 1'b1;
                    ibuf_rptr  <= ibuf_rptr  + 1'b1;
                end
                default: ;
            endcase
            if (pix_val)
                pix_cnt <= pix_cnt + 20'd1;

            // 发射：两两组字
            img_word_val <= 1'b0;
            if (img_emit_en)
                emit_seen <= 1'b1;
            // 填充字只许在「发射已开过且已收」时补：LD_IMG_SETTLE 拉起 emit_start_pulse
            // 后 img_emit_en 晚一拍才升起，这一拍里 !img_emit_en && LD_STREAM 同样
            // 成立——没有 emit_seen 前置会话开头就错发一个黑字（占掉第 0 字预算，
            // 整帧右移一字、末字不落 SDRAM = 板上撕裂的直接根因，2026-10-05 实锤）
            if (emit_seen && !img_emit_en && ld_state == LD_STREAM && !pad_done) begin
                img_word_val <= 1'b1;        // 会话末尾填充字（不入 SDRAM，见上）
                img_word     <= 32'd0;
                pad_done     <= 1'b1;
            end
            else if (emit_go) begin
                if (!img_have_pix0) begin
                    img_pix0_hold <= px565_f(px_src);
                    img_have_pix0 <= 1'b1;
                end
                else begin
                    img_word_val  <= 1'b1;
                    img_word      <= {px565_f(px_src), img_pix0_hold};
                    img_have_pix0 <= 1'b0;
                    emit_cnt      <= emit_cnt + 21'd1;
                end
            end
        end
    end

    // 发射坐标推进（独立块：与组字块同拍不同寄存器，避免混驱）
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            emit_col    <= 11'd0;
            emit_row    <= 11'd0;
            img_emit_en <= 1'b0;
        end
        else if (load_start_pulse) begin
            emit_col    <= 11'd0;
            emit_row    <= 11'd0;
            img_emit_en <= 1'b0;
        end
        else if (emit_start_pulse) begin
            emit_col    <= 11'd0;
            emit_row    <= 11'd0;
            img_emit_en <= 1'b1;                  // 会话开跑（装载 FSM 发脉冲）
        end
        else if (img_emit_en && emit_go) begin
            if (emit_col == 11'd1279) begin
                emit_col <= 11'd0;
                emit_row <= emit_row + 1'b1;
            end
            else begin
                emit_col <= emit_col + 1'b1;
            end
            if ((emit_col == 11'd1279) && (emit_row == img_h_l - 12'd1))
                img_emit_en <= 1'b0;              // 末图末行末像素：会话完成
            // 装载异常弃载（超时/错文件）： FSM 回 IDLE，发射自行熄火
            else if (load_timeout_cnt > 32'd300_000_000)
                img_emit_en <= 1'b0;
        end
    end

    // ==================== 组合赋值 ====================
    // ---- 写口 mux：图像装载走 565 打包器（buf 0/1），音频走打包器。
    // 音频目标缓冲：扫描相位固定 BUF2；随图装载（ald）写入 aud_disp_buf 对侧 BUF2/3。
    // 三相位互斥（扫描/ald/图像装载两两不重叠），write_req/ack 握手天然无竞争。
    wire aud_wr_phase = aud_scan_active | ald_active;
    // 720p 帧缓冲 = 1280*720/2 = 460800 字（RGB565，2 像素/字）
    assign write_req      = write_req_r | aud_wr_req;
    assign write_en       = fill_active   ? (fill_pace_cnt == 4'd0)
                          : aud_wr_phase  ? aud_word_val
                          :                 img_word_val;
    assign write_data     = fill_active   ? 32'd0
                          : aud_wr_phase  ? aud_word
                          :                 img_word;
    assign write_buf_idx  = aud_scan_active ? 2'd2
                          : ald_active      ? ald_buf
                          :                   write_buf_idx_r;
    assign write_len      = fill_active   ? 21'd460800
                          : aud_wr_phase  ? aud_wr_len
                          :                 {10'd0, img_h_l} * 11'd640;  // 640*h
    // 信箱行偏移（字）：vflip 首行 = y0+h-1。涂黑会话必须满帧（偏移 0，否则
    // 负偏移把首地址顶出缓冲底、回卷砸音频区）；音频通道 vflip_en=0 不消费。
    assign o_wr_vrow_off = (fill_active | aud_wr_phase)
                           ? 20'd0
                           : vrow_words[19:0];
    assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
    // 轮播周期 = auto_period_s 秒（1..10），0 视作 1 兜底
    wire [31:0] auto_thr = ((auto_period_s == 4'd0) ? 32'd1 : {28'd0, auto_period_s})
                           * CLK_FREQ_HZ;
    assign auto_tick  = (auto_cnt >= auto_thr - 32'd1);
    assign next_idx   = bmp_nxt_map[6*img_idx[4:0] +: 6];
    assign prev_idx   = bmp_prv_map[6*img_idx[4:0] +: 6];
    assign img_idx_out = img_idx[4:0];     // UART 遥测
    assign img_wav_out = pair_valid[img_idx[4:0]];
    assign ld_diag     = {1'b0, ld_result, ld_state, load_busy, img_wav_out};
    assign tap_word    = img_word;
    assign tap_val     = img_word_val;
    // 会话结束脉冲：检测「离开 LD_STREAM」而非 write_finish——超时/img_err 弃载
    // 没有 finish，但以太网侧仍需冲洗 FIFO 残字，否则脏字污染下一帧。
    // 拍序安全：pad 填充字在 LD_STREAM 内发出（早于 write_finish/弃载退出），
    // 脉冲到达 eth_front 时所有字已进 Gray FIFO。
    reg  ld_stream_q, tap_end_r;
    reg  dmp_auto_r;                    // 装载提交自动触发读回捕获（video 域开窗，见提交处）
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ld_stream_q <= 1'b0; tap_end_r <= 1'b0;
        end
        else begin
            ld_stream_q <= (ld_state == LD_STREAM);
            tap_end_r   <= ld_stream_q && (ld_state != LD_STREAM);
        end
    end
    assign tap_end     = tap_end_r;

    assign dmp_trig   = rdump_start | dmp_auto_r;
    assign auto_play_out = auto_play_en;   // 遥测：自动轮播开关（ctrl_core 打进 ACK/状态包）
    assign aud_playing   = (plstate == PL_RUN);   // 播放域真实出声（音频自愈看门狗用）

    assign dbg_fat_state = fat_dbg;
    assign dbg_fat_err   = fat_err;

    // ---- 状态码（数码管）：1 空闲 2 挂载/扫描 3 FIFO 握手 4 写帧 ----
    assign state_code = !sd_init_done               ? 4'd0
                      : !fat_mounted                ? 4'd2
                      : (ld_state == LD_IMG_ACK)    ? 4'd3
                      : load_busy                   ? 4'd4
                      :                               4'd1;

    // ---- 吸收未用信号，避免 lint 噪声 ----
    wire _unused_absorb = &{1'b0,
                            bmp_width[15:0], bmp_height[15:0],
                            type_map[5:0],
                            cur_is_wav, fat_dbg[7:0], bmp_dbg[7:0],
                            SCAN_START_SECTOR[31:0], SCAN_MAX_SECTOR[31:0],
                            SCAN_TARGET_COUNT[2:0],
                            1'b0};

    // ==================== 例化 ====================
`ifdef VERILATOR   // 仿真加速：1ms 去抖（板级 50ms；去抖逻辑本身仍被完整遍历）
    key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(1)) u_key_next (
`else
    key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(50)) u_key_next (
`endif
        .clk        (clk),
        .rst        (rst),
        .button_in  (key_next),
        .press_pulse(key_next_press)
    );

`ifdef VERILATOR
    key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(1)) u_key_auto (
`else
    key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(50)) u_key_auto (
`endif
        .clk        (clk),
        .rst        (rst),
        .button_in  (key_auto),
        .press_pulse(key_auto_press)
    );

`ifdef VERILATOR
    key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(1)) u_key_prev (
`else
    key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(50)) u_key_prev (
`endif
        .clk        (clk),
        .rst        (rst),
        .button_in  (key_prev),
        .press_pulse(key_prev_press)
    );

    // 适配器：fat32_ro 请求 → sd_card_top sd_sec_read
    sd_adapter u_adapter (
        .clk                    (clk),
        .rst                    (rst),
        .sd_init_done           (sd_init_done),
        .o_lba                  (sec_lba),
        .o_req                  (sec_req),
        .i_ready                (sec_ready),
        .i_data                 (sec_data),
        .i_dval                 (sec_dval),
        .i_done                 (sec_done),
        .i_err                  (sec_err),
        .sd_sec_read            (sd_sec_read),
        .sd_sec_read_addr       (sd_sec_read_addr),
        .sd_sec_read_data       (sd_sec_read_data),
        .sd_sec_read_data_valid (sd_sec_read_data_valid),
        .sd_sec_read_end        (sd_sec_read_end)
    );

    // FAT32 只读引擎（仿真侧原样移植）+ 播放列表查找口
    fat32_ro u_fat (
        .clk         (clk),
        .rst_n       (~rst),
        .o_lba       (sec_lba),
        .o_req       (sec_req),
        .i_ready     (sec_ready),
        .i_data      (sec_data),
        .i_dval      (sec_dval),
        .i_done      (sec_done),
        .i_err       (sec_err),
        .o_byte      (file_byte),
        .o_bval      (file_bval),
        .o_file_done (file_done),
        // 2026-10-03：文件请求单一主人=装载 FSM。此前扫描的 aud_req_pulse 与
        // 图像 file_req 直接或在一起无仲裁——扫描窗口（boot 后 1-4s）内按下一张，
        // 两请求同拍撞车，mux 优先给音频，图像请求被吞（FSM 却已前进）→ WAV 字节
        // 流进 bmp_dec → img_err 弃载 = “按下一张没反应”。扫描项改道经装载 FSM。
        .i_file_idx  (ald_active     ? ald_wav_idx[4:0]
                      : scan_req_active ? aud_req_idx
                      :                   file_idx),
        .i_file_req  (file_req),
        .o_mounted   (fat_mounted),
        .o_file_cnt  (file_cnt),
        .o_bmp_cnt   (bmp_cnt),
        .o_wav_cnt   (wav_cnt),
        .o_type_map  (type_map),
        .o_first_bmp (first_bmp_w),
        .o_bmp_nxt   (bmp_nxt_map),
        .o_bmp_prv   (bmp_prv_map),
        .o_cur_is_wav(cur_is_wav),
        .o_err       (fat_err),
        .o_file_idle (fat_idle),
        .o_dbg_state (fat_dbg),
        .i_pl_idx    (pmatch_active ? pmatch_j[4:0] : aud_k[4:0]),
        .o_pl_name   (pl_name),
        .o_pl_is_wav (pl_is_wav),
        .o_pl_valid  (pl_valid)
    );

    // WAV 头解析 + PCM 样本流（图像装载期它会被 BMP 字节污染，下次 i_restart 自清）
    wav_reader u_wav (
        .clk         (clk),
        .rst_n       (~rst),
        .i_byte      (file_byte),
        .i_bval      (file_bval),
        .i_restart   (aud_req_pulse | ald_start_pulse),
        .o_smp       (wav_smp),
        .o_sval      (wav_sval),
        .o_hdr_ok    (w_hdr_ok),
        .o_fmt_err   (w_fmt_err),
        .o_data_bytes(w_data_bytes)
    );

    assign aud_smp         = wav_smp;
    assign aud_sval        = wav_sval;
    assign aud_item_done   = aud_item_done_pulse;
    assign aud_scan_done   = aud_scan_done_r;
    assign wav_hdr_ok      = w_hdr_ok;
    assign wav_fmt_err     = w_fmt_err;
    assign wav_data_bytes  = w_data_bytes;

    // ---- 信箱适配：解码头导出 + 发射/偏移参数 ----
    wire [11:0] img_w_dec, img_h_dec /*verilator public_flat_rd*/;      // bmp_dec 头部导出（byte53 后有效）
    wire        img_hdr_ok_dec /*verilator public_flat_rd*/;            // 本文件头校验通过（i_restart 清零）
    wire        img_hdr_ok = img_hdr_ok_dec;   // bmp_dec o_hdr_ok：本文件头校验通过
                                               //（⚠ 不可用 img_w_dec!=0 代替——w 跨装载
                                               //   保持旧值，新会话会拿旧尺寸提前开门）
    reg  [11:0] img_w_l, img_h_l;        // 装载会话锁存
    wire [11:0] x0_l = (12'd1280 - img_w_l) >> 1;   // 水平居中起点（像素）
    wire [11:0] y0_l = (12'd720  - img_h_l) >> 1;   // 垂直居中起点（行）
    wire signed [11:0] row_off  = $signed(y0_l) + $signed(img_h_l) - 12'sd720;
    wire signed [29:0] vrow_words = ($signed(row_off) <<< 9) + ($signed(row_off) <<< 7);
                                                     // *640（512+128），<=0
    reg        fill_active /*verilator public_flat_rd*/;                  // 全帧涂黑会话进行中
    reg  [3:0] fill_pace_cnt;                // 每 16 拍送一黑字，降低共享写通路的瞬时压力
    reg        img_emit_en;                  // 信箱发射使能（唯一写方=发射块）
    reg  [1:0] pad_pace_cnt;                 // 图像左右黑色 padding 每 4 拍发一像素
    reg        emit_start_pulse;             // 装载 FSM → 发射块：会话开跑脉冲
    reg  [10:0] emit_col, emit_row;          // 发射坐标（列 0..1279 / 流行号）

    always @(posedge clk or posedge rst) begin
        if (rst || load_start_pulse || !img_emit_en)
            pad_pace_cnt <= 2'd0;
        else
            pad_pace_cnt <= pad_pace_cnt + 2'd1;
    end

    always @(posedge clk or posedge rst) begin
        if (rst || !fill_active)
            fill_pace_cnt <= 4'd0;
        else
            fill_pace_cnt <= fill_pace_cnt + 4'd1;
    end

    // BMP 解码（行翻转归属存储侧 WRITE_V_FLIP=1）
    bmp_dec u_bmp (
        .clk        (clk),
        .rst_n      (~rst),
        .i_byte     (file_byte),
        .i_bval     (file_bval),
        .i_restart  (load_start_pulse),
        .o_pix_val  (pix_val),
        .o_pix      (pix),
        .o_img_ok   (img_ok),
        .o_img_err  (img_err),
        .o_img_w    (img_w_dec),
        .o_img_h    (img_h_dec),
        .o_hdr_ok   (img_hdr_ok_dec),
        .o_dbg_state(bmp_dbg)
    );

    // SD 层二选一：默认引脚级（stub_sd_card_top：协议翻译 + sd_spi + 卡模型，
    // 板上已验证原样保留）；fast_en=1（SIM_FAST）走直连扇区服务器，
    // SPI 栈退出仿真覆盖（排查可疑 bug 时先用默认档排除 SPI 因素）
    wire        sd_init_slow, sec_dval_slow, sec_end_slow, sd_init_fast;
    wire        sec_dval_fast, sec_end_fast;
    wire [7:0]  sec_data_slow, sec_data_fast;
    wire        sec_read_slow = sd_sec_read & ~fast_en;
    wire        sec_read_fast = sd_sec_read &  fast_en;

    sd_card_top sd_card_top_m0 (
        .clk                    (clk),
        .rst                    (rst),
        .SD_nCS                 (SD_nCS),
        .SD_DCLK                (SD_DCLK),
        .SD_MOSI                (SD_MOSI),
        .SD_MISO                (SD_MISO),
        .sd_init_done           (sd_init_slow),
        .sd_sec_read            (sec_read_slow),
        .sd_sec_read_addr       (sd_sec_read_addr),
        .sd_sec_read_data       (sec_data_slow),
        .sd_sec_read_data_valid (sec_dval_slow),
        .sd_sec_read_end        (sec_end_slow),
        .sd_sec_write           (1'b0),
        .sd_sec_write_addr      (32'd0),
        .sd_sec_write_data      (8'd0),
        .sd_sec_write_data_req  (),
        .sd_sec_write_end       ()
    );

    fast_sd_stub u_fast_sd (
        .clk                    (clk),
        .rst                    (rst),
        .sd_init_done           (sd_init_fast),
        .fast_byte              (fast_byte),
        .fast_val               (fast_val),
        .fast_lba               (fast_lba),
        .fast_idx               (fast_idx),
        .fast_serving           (fast_serving),
        .sd_sec_read            (sec_read_fast),
        .sd_sec_read_addr       (sd_sec_read_addr),
        .sd_sec_read_data       (sec_data_fast),
        .sd_sec_read_data_valid (sec_dval_fast),
        .sd_sec_read_end        (sec_end_fast)
    );

    assign sd_init_done           = fast_en ? sd_init_fast  : sd_init_slow;
    assign sd_sec_read_data       = fast_en ? sec_data_fast : sec_data_slow;
    assign sd_sec_read_data_valid = fast_en ? sec_dval_fast : sec_dval_slow;
    assign sd_sec_read_end        = fast_en ? sec_end_fast  : sec_end_slow;

    // ==================== 装载序列 ====================
    // 图像：空闲 → 先开写通道（等 ack，存储侧借此清写 FIFO 并锁存长度）
    //       → 再向 fat32_ro 发文件请求（顺序反了会把上一张图的残留像素算进这一张）。
    // 音频（ald）：打包器先解析头再开写通道，故直接发文件请求（ld_kick 跳过 MEM_ACK）。
    // ====================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ld_state    <= LD_IDLE;
            write_req_r <= 1'b0;
            file_req    <= 1'b0;
            file_idx    <= 5'd0;
            emit_start_pulse <= 1'b0;
            scan_req_active  <= 1'b0;
            img_settle_cnt <= 4'd0;
        end
        else begin
            file_req <= 1'b0;
            emit_start_pulse <= 1'b0;
            case (ld_state)
                LD_IDLE: begin
                    if (load_start_pulse) begin
                        fill_active <= 1'b1;          // 先全帧涂黑（垫非图像区）
                        write_req_r <= 1'b1;
                        scan_req_active <= 1'b0;      // 兜底：图像装载绝不被劫持
                        ld_state    <= LD_FILL_REQ;
                    end
                    else if (ld_kick) begin
                        scan_req_active <= 1'b0;      // ald：无涂黑会话
                        ld_state        <= LD_FILE;
                    end
                    else if (scan_kick) begin
                        scan_req_active <= 1'b1;      // 扫描项：无涂黑会话
                        ld_state        <= LD_FILE;
                    end
                end
                LD_FILL_REQ: begin
                    if (write_req_ack) begin
                        write_req_r <= 1'b0;
                        ld_state    <= LD_FILL_RUN;
                    end
                end
                LD_FILL_RUN: begin
                    // 涂黑数据由写口 mux 常发（write_en=1、data=0、len=460800）
                    if (write_finish_pulse) begin
                        fill_active <= 1'b0;
                        ld_state    <= LD_FILE;
                    end
                    else if (load_timeout_cnt > 32'd300_000_000) begin
                        fill_active <= 1'b0;
                        ld_state    <= LD_IDLE;
                    end
                end
                LD_FILE: begin
                    // fat32 只在 MOUNTED 态收请求：忙时保持等待，一拍脉冲不被丢弃
                    if (fat_idle) begin
                        file_req <= 1'b1;
                        file_idx <= ald_active     ? ald_wav_idx[4:0]
                                  : scan_req_active ? aud_req_idx
                                  :                   load_idx[4:0];
                        // 图像：留在本态等头校验（拿 img_w/h 才能定会话长度）；
                        // 音频（ald/扫描项）：打包器自行开写口，直接回空闲
                        ld_state <= (ald_active | scan_req_active) ? LD_IDLE
                                                                    : LD_IMG_WAIT;
                        // ⚠ 请求已发出即消费掉 scan_req_active——不清除的话它
                        //   恒为 1，后续所有图像装载的 file_idx 都被劫持成滞留的
                        //   aud_req_idx（指向某个 WAV）→ img_err → "按下一张没反应"
                        scan_req_active <= 1'b0;
                    end
                end
                LD_IMG_WAIT: begin
                    if (img_hdr_ok) begin
                        img_w_l     <= img_w_dec;
                        img_h_l     <= img_h_dec;
                        write_req_r <= 1'b1;      // 会话长度 = img_h*640（mux 给出）
                        ld_state    <= LD_IMG_ACK;
                    end
                    else if (img_err) begin
                        ld_state <= LD_IDLE;      // 外控 img_err 分支同步放弃装载
                    end
                    else if (load_timeout_cnt > 32'd300_000_000) begin
                        ld_state <= LD_IDLE;
                    end
                end
                LD_IMG_ACK: begin
                    if (write_req_ack) begin
                        write_req_r    <= 1'b0;
                        img_settle_cnt <= 4'd0;
                        ld_state       <= LD_IMG_SETTLE;
                    end
                end
                LD_IMG_SETTLE: begin
                    // ACK 所在拍存储域的 fifo_aclr 仍为 1；请求撤销还要经过
                    // 3 级同步，再等 FIFO 两域同步释放。窄图行首黑边可每拍
                    // 发一个像素，必须等清零完全结束才允许首字进入 FIFO。
                    if (img_settle_cnt == 4'd15) begin
                        emit_start_pulse <= 1'b1;
                        ld_state <= LD_STREAM;
                    end else begin
                        img_settle_cnt <= img_settle_cnt + 4'd1;
                    end
                end
                LD_STREAM: begin
                    // 信箱发射推行；结束拍（写满 img_h*640 字）finish → 外控提交。
                    // img_emit_en 由发射块负责（末像素/超时自熄），此处只管状态。
                    if (write_finish_pulse)
                        ld_state <= LD_IDLE;
                    else if (load_timeout_cnt > 32'd300_000_000)
                        ld_state <= LD_IDLE;
                end
                default: ld_state <= LD_IDLE;
            endcase
        end
    end

    // ==================== 外控（沿用例程结构，改接 FAT32 信号） ====================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wrfin_tgl_sync        <= 3'b000;
            load_start_pulse      <= 1'b0;
            load_busy             <= 1'b0;
            load_timeout_cnt      <= 32'd0;
            aud_wd_cnt            <= 30'd0;
            aud_rescan            <= 1'b0;
            aud_retry_cnt         <= 2'd0;
            write_done_seen       <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            img_idx               <= 6'd0;
            first_idx_r           <= 6'd0;
            first_idx_captured    <= 1'b0;
            ld_result             <= 2'd0;
            snap_len              <= 21'd0;
            snap_w                <= 12'd0;
            snap_h                <= 12'd0;
            snap_ld               <= 3'd0;
            snap_words            <= 21'd0;
            snap_pix              <= 20'd0;
            load_idx              <= 6'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx_r <= 2'd0;
            disp_buf_idx          <= 2'd0;
            next_req_pending      <= 1'b0;
            prev_req_pending      <= 1'b0;
            display_valid         <= 1'b0;
            ld_kick               <= 1'b0;
            ald_start_pulse       <= 1'b0;
            scan_start_pulse      <= 1'b0;
            scan_nowav_pulse      <= 1'b0;
            ald_active            <= 1'b0;
            boot_ald              <= 1'b0;
            ald_boot_done         <= 1'b0;
            ald_wav_idx           <= 6'd0;
            ald_buf               <= 2'd2;
            aud_disp_buf          <= 2'd2;
            aud_cmt_valid         <= 1'b0;
            cmt_pair              <= 1'b0;
            cmt_buf               <= 2'd2;
            cmt_len               <= 21'd0;
            load_direction_prev   <= 1'b0;
            load_effect_mode      <= 2'd0;
            transition_pending    <= 1'b0;
            transition_timeout_cnt <= 28'd0;
            transition_done_sync  <= 3'd0;
            transition_start_toggle <= 1'b0;
            transition_target_buf <= 1'b0;
            transition_mode_latched <= 2'd0;
            transition_prev_latched <= 1'b0;
            transition_img_idx    <= 6'd0;
            transition_disp_buf   <= 2'd0;
            transition_cmt_pair   <= 1'b0;
            transition_cmt_buf    <= 2'd2;
            transition_cmt_len    <= 21'd0;
            transition_aud_buf    <= 2'd2;
        end
        else begin
            wrfin_tgl_sync  <= {wrfin_tgl_sync[1:0], write_finish_toggle};
            load_start_pulse<= 1'b0;
            dmp_auto_r      <= 1'b0;
            ld_kick         <= 1'b0;
            ald_start_pulse <= 1'b0;
            scan_start_pulse<= 1'b0;
            scan_nowav_pulse<= 1'b0;
            transition_done_sync <= {transition_done_sync[1:0], transition_done_toggle};

            // ---- 播放提交握手：播放域取走后撤 valid（电平双拍，同 clk 无竞争）----
            if (aud_cmt_taken) aud_cmt_valid <= 1'b0;

            // ---- SD 未就绪：保持复位态 ----
            if (!sd_init_done) begin
                load_busy             <= 1'b0;
                load_timeout_cnt      <= 32'd0;
                write_done_seen       <= 1'b0;
                first_image_committed <= 1'b0;
                auto_play_en          <= 1'b0;
                auto_cnt              <= 32'd0;
                img_idx               <= 6'd0;
                first_idx_r           <= 6'd0;
                first_idx_captured    <= 1'b0;
                load_idx              <= 6'd0;
                pending_buf_idx       <= 2'd0;
                write_buf_idx_r <= 2'd0;
                disp_buf_idx          <= 2'd0;
                next_req_pending      <= 1'b0;
                prev_req_pending      <= 1'b0;
                display_valid         <= 1'b0;
                ald_active            <= 1'b0;
                boot_ald              <= 1'b0;
                ald_boot_done         <= 1'b0;
                aud_disp_buf          <= 2'd2;
                aud_cmt_valid         <= 1'b0;
                aud_wd_cnt            <= 30'd0;
                aud_rescan            <= 1'b0;
                aud_retry_cnt         <= 2'd0;
                transition_pending    <= 1'b0;
                transition_timeout_cnt <= 28'd0;
            end
            else if (fat_err) begin
                // FAT 挂载失败/索引越界：清装载，保持黑屏
                load_busy        <= 1'b0;
                load_timeout_cnt <= 32'd0;
                write_done_seen  <= 1'b0;
                transition_pending <= 1'b0;
            end
            else begin
                if (transition_pending) begin
                    if (transition_done_pulse ||
                        transition_timeout_cnt >= 28'd200_000_000) begin
                        // Image, matching WAV and automatic D capture commit together.
                        transition_pending <= 1'b0;
                        transition_timeout_cnt <= 28'd0;
                        disp_buf_idx <= transition_disp_buf;
                        img_idx <= transition_img_idx;
                        aud_disp_buf <= transition_aud_buf;
                        aud_cmt_valid <= 1'b1;
                        cmt_pair <= transition_cmt_pair;
                        cmt_buf <= transition_cmt_buf;
                        cmt_len <= transition_cmt_len;
                        dmp_auto_r <= 1'b1;
                    end else begin
                        transition_timeout_cnt <= transition_timeout_cnt + 28'd1;
                    end
                end

                // ---- 挂载完成：捕获首图候选（坏图推进）----
                if (fat_mounted && !first_idx_captured) begin
                    first_idx_r      <= first_bmp_w;
                    first_idx_captured <= 1'b1;
                end

                // ---- 装载完成 / 放弃 / 超时 ----
                // 装载发起的那一拍跳过（load_start_pulse=1），
                // 等 bmp_dec 已被 i_restart 复位、img_ok/img_err 清零后再判。
                if (load_busy && !load_start_pulse) begin
                    // 多分辨率后每次装载有两个写会话（涂黑+图像）：
                    //   只有图像会话（LD_STREAM）的 finish 才算整帧落盘
                    if (write_finish_pulse && (ld_state == LD_STREAM)) begin
                        write_done_seen <= 1'b1;
                        // 图像会话收尾快照（提交/超时都用它）
                        snap_len <= write_len;
                        snap_w   <= img_w_l;
                        snap_h   <= img_h_l;
                        snap_ld  <= LD_STREAM;
                    end

                    if (ald_active) begin
                        // ---- 音频装载子相位：等打包器关闭（eof + write_finish 双确认）----
                        if (aud_item_close) begin
                            ald_active       <= 1'b0;
                            load_busy        <= 1'b0;
                            load_timeout_cnt <= 32'd0;
                            ld_result        <= 2'd3;
                            if (boot_ald || !first_image_committed || load_effect_mode == 2'd0) begin
                                // Boot audio and direct-cut mode preserve the old commit path.
                                aud_disp_buf  <= ald_buf;
                                aud_cmt_valid <= 1'b1;
                                cmt_pair      <= 1'b1;
                                cmt_buf       <= ald_buf;
                                cmt_len       <= wav_len_rec[ald_wav_idx[4:0]];
                                if (!boot_ald) begin
                                    write_done_seen <= 1'b0;
                                    disp_buf_idx    <= pending_buf_idx;
                                    img_idx         <= load_idx;
                                    display_valid   <= 1'b1;
                                end
                                dmp_auto_r <= 1'b1;
                            end else begin
                                // Keep both video buffers and the old WAV until HDMI finishes.
                                write_done_seen <= 1'b0;
                                transition_start_toggle <= ~transition_start_toggle;
                                transition_target_buf <= pending_buf_idx[0];
                                transition_mode_latched <= load_effect_mode;
                                transition_prev_latched <= load_direction_prev;
                                transition_pending <= 1'b1;
                                transition_timeout_cnt <= 28'd0;
                                transition_img_idx <= load_idx;
                                transition_disp_buf <= pending_buf_idx;
                                transition_cmt_pair <= 1'b1;
                                transition_cmt_buf <= ald_buf;
                                transition_cmt_len <= wav_len_rec[ald_wav_idx[4:0]];
                                transition_aud_buf <= ald_buf;
                            end
                            boot_ald <= 1'b0;
                            // 首图显示（含配对音频就绪）后启动音频扫描相位
                            if (!first_image_committed) begin
                                first_image_committed <= 1'b1;
                                if (wav_cnt != 6'd0) begin
                                    scan_start_pulse <= 1'b1;   // 扫描相位寄存器归扫描块独占
                                end
                                else begin
                                    scan_nowav_pulse <= 1'b1;
                                end
                            end
                        end
                        else if (load_timeout_cnt > 32'd500_000_000) begin
                            // 音频装载超时（坏卡）：放弃音频，图也不切（旧图旧音继续）
                            ald_active       <= 1'b0;
                            load_busy        <= 1'b0;
                            boot_ald         <= 1'b0;
                            load_timeout_cnt <= 32'd0;
                            ld_result        <= 2'd2;
                            snap_ld          <= 3'd7;   // 7=音频装载段
                            snap_len         <= write_len;
                        end
                        else begin
                            load_timeout_cnt <= load_timeout_cnt + 32'd1;
                        end
                    end
                    else if (img_err) begin
                        // 坏图：立即放弃不提交（旧图继续显示），光标推进跳过
                        load_busy        <= 1'b0;
                        load_timeout_cnt <= 32'd0;
                        write_done_seen  <= 1'b0;
                        ld_result        <= 2'd1;
                        snap_ld          <= ld_state;
                        snap_len         <= write_len;
                        snap_w           <= img_w_l;
                        snap_h           <= img_h_l;
                        snap_words       <= emit_cnt;
                        snap_pix         <= pix_cnt;
                        if (!first_image_committed)
                            first_idx_r <= bmp_nxt_map[6*first_idx_r[4:0] +: 6];
                        else
                            img_idx     <= load_idx;
                    end
                    else if (img_ok && write_done_seen && fat_idle) begin
                        load_timeout_cnt <= 32'd0;
                        // fat_idle：等 fat32 读完图文件尾回 MOUNTED 再踢 ald。
                        // 否则 ald 的 file_req 一拍脉冲在 fat32 忙时被丢弃，
                        // 图文件的 file_done 反被误当 WAV 流结束 → 空提交残留缓冲。
                        if (pair_valid[load_idx[4:0]]) begin
                            // 图就绪且有配对：先装音频，提交延迟到音频写尽（ald 分支）
                            ald_active      <= 1'b1;
                            ald_buf         <= (aud_disp_buf == 2'd2) ? 2'd3 : 2'd2;
                            ald_wav_idx     <= pair_wav[load_idx[4:0]];
                            ld_kick         <= 1'b1;
                            ald_start_pulse <= 1'b1;
                        end
                        else begin
                            // 提交：无配对 → 播放域切静音
                            load_busy             <= 1'b0;
                            write_done_seen       <= 1'b0;
                            ld_result             <= 2'd3;
                            if (!first_image_committed || load_effect_mode == 2'd0) begin
                                disp_buf_idx          <= pending_buf_idx;
                                img_idx               <= load_idx;
                                display_valid         <= 1'b1;
                                first_image_committed <= 1'b1;
                                dmp_auto_r            <= 1'b1;
                                aud_cmt_valid         <= 1'b1;
                                cmt_pair              <= 1'b0;
                                cmt_buf               <= aud_disp_buf;
                                cmt_len               <= 21'd0;
                            end else begin
                                transition_start_toggle <= ~transition_start_toggle;
                                transition_target_buf <= pending_buf_idx[0];
                                transition_mode_latched <= load_effect_mode;
                                transition_prev_latched <= load_direction_prev;
                                transition_pending <= 1'b1;
                                transition_timeout_cnt <= 28'd0;
                                transition_img_idx <= load_idx;
                                transition_disp_buf <= pending_buf_idx;
                                transition_cmt_pair <= 1'b0;
                                transition_cmt_buf <= aud_disp_buf;
                                transition_cmt_len <= 21'd0;
                                transition_aud_buf <= aud_disp_buf;
                            end
                            if (wav_cnt != 6'd0) begin
                                scan_start_pulse <= 1'b1;
                            end
                            else begin
                                scan_nowav_pulse <= 1'b1;
                            end
                        end
                    end
                    else if (load_timeout_cnt > 32'd300_000_000) begin // 3s @100MHz：720p 装载(SPI+SDRAM)约 1s+，留裕量
                        // 超时（坏卡/坏文件卡住）：强制释放，恢复按键。
                        // 光标推进到本次尝试项（img_err 同语义）——挂死项按坏图跳过，
                        // 环不因单个装载超时锁死（2026-10-04 板级多分辨率挂死的兜底）
                        load_busy        <= 1'b0;
                        load_timeout_cnt <= 32'd0;
                        write_done_seen  <= 1'b0;
                        img_idx          <= load_idx;
                        ld_result        <= 2'd2;
                        snap_ld          <= ld_state;
                        snap_len         <= write_len;
                        snap_w           <= img_w_l;
                        snap_h           <= img_h_l;
                        snap_words       <= emit_cnt;
                        snap_pix         <= pix_cnt;
                    end
                    else begin
                        load_timeout_cnt <= load_timeout_cnt + 32'd1;
                    end
                end
                else begin
                    load_timeout_cnt <= 32'd0;
                end

                // ---- boot 音频：首图提交时配对表未建（扫描才建），一律走的静音提交；
                // 扫描完成后若首图有配对，重读 WAV 入对侧缓冲提交（仅一次）----
                // ⚠ !aud_rescan：重扫描在途时封锁——否则 rescan 清 ald_boot_done
                //   到扫描块清 aud_scan_done_r 之间的 1 拍窗口里，触发条件用**旧扫描
                //   的残留 wav_len_rec** 提前点火，与重扫描抢写口。
                if (aud_scan_done_r && !ald_boot_done && !load_busy && fat_idle &&
                    !aud_rescan && first_image_committed) begin
                    ald_boot_done <= 1'b1;
                    if (pair_valid[img_idx[4:0]]) begin
                        boot_ald        <= 1'b1;
                        ald_active      <= 1'b1;
                        load_busy       <= 1'b1;
                        ld_result        <= 2'd0;
                        ald_buf         <= (aud_disp_buf == 2'd2) ? 2'd3 : 2'd2;
                        ald_wav_idx     <= pair_wav[img_idx[4:0]];
                        ld_kick         <= 1'b1;
                        ald_start_pulse <= 1'b1;
                    end
                end

                // ---- 音频 boot 自愈看门狗：图已提交+扫描完+当前图有配对，而
                //      音频 8s 未进入播放态 → 重跑整条音频 boot（重扫描 + 重新
                //      boot_ald），图像显示不受影响。复位键偶发丢音（音频 boot
                //      链一次性、无重试，见 TODO 第十七轮）的结构性解法。----
                if (aud_rescan) begin
                    if (aud_scan_done_r && !aud_scan_active) begin
                        aud_rescan    <= 1'b0;
                        ald_boot_done <= 1'b0;   // 扫描重跑完成 → 触发条件重新成立
                    end
                end
                else if (first_image_committed && aud_scan_done_r &&
                         pair_valid[img_idx[4:0]] && !aud_playing &&
                         !ald_active && !load_busy) begin
                    if (aud_wd_cnt >= 30'd800_000_000) begin
                        aud_wd_cnt       <= 30'd0;
                        aud_rescan       <= 1'b1;
                        scan_start_pulse <= 1'b1;   // 扫描块重跑并清 aud_scan_done_r
                        aud_retry_cnt    <= aud_retry_cnt + 1'b1;
                    end
                    else begin
                        aud_wd_cnt <= aud_wd_cnt + 1'b1;
                    end
                end
                else begin
                    aud_wd_cnt <= 30'd0;
                end
                if (aud_playing) begin
                    aud_retry_cnt <= 2'd0;           // 播放成功即恢复全部重试额度
                end

                // ---- 按键请求（装载中只记一次，连按不累积）----
                if (key_next_press && fat_mounted && (bmp_cnt != 6'd0))
                    next_req_pending <= 1'b1;
                if (key_prev_press && fat_mounted && (bmp_cnt != 6'd0))
                    prev_req_pending <= 1'b1;

                // ---- 自动轮播开/关 ----
                if (key_auto_press && fat_mounted && (bmp_cnt > 6'd1)) begin
                    auto_play_en <= ~auto_play_en;
                    auto_cnt     <= 32'd0;
                end

                // ---- 自动轮播 1s 计时（仅空闲且已首图提交）----
                if (fat_mounted && auto_play_en && display_valid && !load_busy &&
                    !transition_pending &&
                    first_image_committed && (bmp_cnt > 6'd1)) begin
                    if (auto_tick) auto_cnt <= 32'd0;
                    else           auto_cnt <= auto_cnt + 32'd1;
                end
                else begin
                    auto_cnt <= 32'd0;
                end

                // ---- 发起装载：首图 / 手动 / 自动（扫描与 boot 音频安排期间不发起）----
                // ⚠ first_idx_captured 门控：首图捕获（first_idx_r <= first_bmp_w）
                //   与本块同一拍——若无门控，boot 装载采样到**旧值 0**（= 一个 WAV
                //   条目），img_err 跳过又把 first_idx_r 推过真正的首图 → 开机图
                //   错位 + 环缺一张（2026-10-03 板级实锤）
                if (fat_mounted && fat_idle && !load_busy && !transition_pending &&
                    !aud_scan_active &&
                    (!aud_scan_done_r || ald_boot_done) && (bmp_cnt != 6'd0) &&
                    first_idx_captured) begin
                    if (!first_image_committed) begin
                        // 首图：写 buffer0（首图候选可能已被坏图推进）
                        load_idx         <= first_idx_r;
                        load_direction_prev <= 1'b0;
                        load_effect_mode <= effect_mode;
                        pending_buf_idx  <= 2'd0;
                        write_buf_idx_r <= 2'd0;
                        load_busy        <= 1'b1;
                        ld_result        <= 2'd0;
                        load_start_pulse <= 1'b1;
                        write_done_seen  <= 1'b0;
                        next_req_pending <= 1'b0;
                        prev_req_pending <= 1'b0;
                        auto_cnt         <= 32'd0;
                    end
                    else if (next_req_pending) begin
                        // 手动下一张：写非当前显示缓冲
                        load_idx         <= next_idx;
                        load_direction_prev <= 1'b0;
                        load_effect_mode <= effect_mode;
                        pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                        write_buf_idx_r <= next_buf_lut(disp_buf_idx, display_valid);
                        load_busy        <= 1'b1;
                        ld_result        <= 2'd0;
                        load_start_pulse <= 1'b1;
                        write_done_seen  <= 1'b0;
                        next_req_pending <= 1'b0;
                        prev_req_pending <= 1'b0;   // 本轮装载只认一个方向
                        auto_cnt         <= 32'd0;
                    end
                    else if (prev_req_pending) begin
                        // 手动上一张：写非当前显示缓冲
                        load_idx         <= prev_idx;
                        load_direction_prev <= 1'b1;
                        load_effect_mode <= effect_mode;
                        pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                        write_buf_idx_r <= next_buf_lut(disp_buf_idx, display_valid);
                        load_busy        <= 1'b1;
                        ld_result        <= 2'd0;
                        load_start_pulse <= 1'b1;
                        write_done_seen  <= 1'b0;
                        next_req_pending <= 1'b0;
                        prev_req_pending <= 1'b0;
                        auto_cnt         <= 32'd0;
                    end
                    else if (auto_play_en && auto_tick && (bmp_cnt > 6'd1)) begin
                        load_idx         <= next_idx;
                        load_direction_prev <= 1'b0;
                        load_effect_mode <= effect_mode;
                        pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                        write_buf_idx_r <= next_buf_lut(disp_buf_idx, display_valid);
                        load_busy        <= 1'b1;
                        ld_result        <= 2'd0;
                        load_start_pulse <= 1'b1;
                        write_done_seen  <= 1'b0;
                        next_req_pending <= 1'b0;
                        prev_req_pending <= 1'b0;
                        auto_cnt         <= 32'd0;
                    end
                end
            end
        end
    end

    // ==================== 播放列表转储（'L' 调试命令，S3c）====================
    // pl_dump_start 一拍 → 逐条目发 64bit 包，最后发收口包；包间 400µs（1Mbaud
    // UART 发 8 字节 ≈80µs，留 5 倍裕量；以太网同理）。只读挂载后静止的表，
    // 与装载/扫描互不干扰；条目 is_wav 用跳表重建（BMP 集 = first_bmp ∪
    // {i≠0 : nxt_map[prv_map[i]]==i}；i==0 时 prv_map[0] 恒 0 无效，单独判
    // first_bmp==0），不占用 fat32_ro 与音频扫描共享的 i_pl_idx 查找口。
    //   条目包 {2'b01, idx[4:0], is_bmp, pair_valid, pair_wav[5:0], nxt[5:0],
    //           prv[5:0], 37'b0}
    //   收口包 {2'b10, file_cnt, bmp_cnt, wav_cnt, first_bmp, img_idx[4:0],
    //           first_idx_r[4:0], load_busy, aud_scan_active, ld_state[2:0],
    //           23'b0}——高 2 位 01/10 不与 ASCII（<0x80）冲突，PC 侧据此分帧。
    reg [2:0]  plst_st;                      // 0 空闲 1 发包 2 间隔 3 收口后待快照 4 快照后收尾间隔 5 发快照
    reg [63:0] pl_pkt_be;                    // MSB-first 组包（tag 在 [63:62]）
    // uart_link 发送 LSB 字节先行（pkt[0]<=tx_pkt[7:0]，与 ctrl_core 的 ACK/状态包
    // 同一约定）——转储包按 MSB-first 组好整包字节反转后再上线路，控制台按线序
    // 大端解码无需任何偏移调整。
    assign pl_pkt = ENABLE_LIST_DIAG ?
                    {pl_pkt_be[7:0],   pl_pkt_be[15:8],  pl_pkt_be[23:16], pl_pkt_be[31:24],
                     pl_pkt_be[39:32], pl_pkt_be[47:40], pl_pkt_be[55:48], pl_pkt_be[63:56]} : 64'd0;
    reg pl_pkt_val_r;
    assign pl_pkt_val = ENABLE_LIST_DIAG && pl_pkt_val_r;
    reg [5:0]  plst_idx;
    reg [15:0] plst_pace;
    wire [5:0] plst_prv_i     = bmp_prv_map[6*plst_idx[4:0] +: 6];
    wire [5:0] plst_nxt_of_prv = bmp_nxt_map[6*plst_prv_i[4:0] +: 6];
    wire       plst_is_bmp    = (bmp_cnt == 6'd0) ? 1'b0
                                 : (plst_idx == 6'd0) ? (first_bmp_w == 6'd0)
                                 : (plst_nxt_of_prv == plst_idx);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            plst_st    <= 3'd0;
            plst_idx   <= 6'd0;
            plst_pace  <= 16'd0;
            pl_pkt_be  <= 64'd0;
            pl_pkt_val_r <= 1'b0;
        end
        else begin
            pl_pkt_val_r <= 1'b0;
            case (plst_st)
                3'd0: if (pl_dump_start) begin
                    plst_idx <= 6'd0;
                    // 先隔 400µs 再发首包：命令 ACK 脉冲与首包只差几十 ns 时，
                    // 以太网侧 toggle 跨域同步窗内两次翻转粘连出假边沿（串口
                    // 无此问题——同域逐包取用）
                    plst_pace <= 16'd40000;
                    plst_st   <= 3'd2;
                end
                3'd1: begin
                    pl_pkt_val_r <= 1'b1;
                    plst_pace  <= 16'd40000;
                    if (plst_idx == file_cnt) begin
                        pl_pkt_be  <= {2'b10, file_cnt, bmp_cnt, wav_cnt, first_bmp_w,
                                       img_idx[4:0], first_idx_r[4:0], load_busy,
                                       aud_scan_active, ld_state, 23'b0};
                        plst_st <= 3'd3;   // 收口后还有一条装载快照包
                    end
                    else begin
                        pl_pkt_be  <= {2'b01, plst_idx[4:0], plst_is_bmp,
                                       pair_valid[plst_idx[4:0]],
                                       pair_wav[plst_idx[4:0]],
                                       bmp_nxt_map[6*plst_idx[4:0] +: 6],
                                       bmp_prv_map[6*plst_idx[4:0] +: 6], 37'b0};
                        plst_idx <= plst_idx + 6'd1;
                        plst_st  <= 3'd2;
                    end
                end
                3'd2: if (plst_pace != 16'd0)
                          plst_pace <= plst_pace - 16'd1;
                      else
                          plst_st <= 3'd1;
                3'd3: if (plst_pace != 16'd0)
                          plst_pace <= plst_pace - 16'd1;
                      else
                          plst_st <= 3'd5;
                3'd5: begin
                    pl_pkt_val_r <= 1'b1;
                    pl_pkt_be  <= {2'b11, ld_result, snap_ld, snap_words,
                                   snap_pix, snap_h, 4'b0};
                    plst_pace  <= 16'd40000;
                    plst_st    <= 3'd4;
                end
                3'd4: if (plst_pace != 16'd0)
                          plst_pace <= plst_pace - 16'd1;
                      else
                          plst_st <= 3'd0;
                default: plst_st <= 3'd0;
            endcase
        end
    end

    // ==================== 音频打包器 / 写通道（S2）====================
    // wav_reader 样本字节 → 4 字节打包 32 位字（首字节在 [7:0]）→ 复用写口装 BUF2。
    // 写长度 = ceil(dbytes/4) 向上取整 256 字（存储侧突发整除约束），
    // 尾字节不足 4 的在字内补 0x80、字不足长度的整字补 0x80808080（0x80=静音零点）。
    // 写通道在 data 块到达（hdr_ok，dbytes 锁存）时才开——拒绝项根本不碰写口。
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pstate        <= P_IDLE;
            aud_wr_req    <= 1'b0;
            aud_wr_active <= 1'b0;
            aud_wr_len    <= 21'd0;
            aud_wr_cnt    <= 21'd0;
            word_asm      <= 32'd0;
            byte_cnt      <= 3'd0;
            byte_total    <= 32'd0;
            aud_fin_seen  <= 1'b0;
            aud_eof_seen  <= 1'b0;
        end
        else begin
            if (write_finish_pulse && (aud_item_active || ald_active))
                aud_fin_seen <= 1'b1;
            if (file_done && (aud_item_active || ald_active))
                aud_eof_seen <= 1'b1;

            if (aud_item_close) begin
                // 项关闭：清标志，写通道随下一项请求重开
                aud_fin_seen  <= 1'b0;
                aud_eof_seen  <= 1'b0;
                aud_wr_active <= 1'b0;
                aud_wr_req    <= 1'b0;
                pstate        <= P_IDLE;
                // 合法项（开过写通道）的长度记入配对表（扫描期即稳定，供提交域直读）
                if (aud_wr_active)
                    wav_len_rec[ald_active ? ald_wav_idx[4:0] : aud_req_idx[4:0]]
                        <= aud_wr_len;
            end
            else case (pstate)
                P_IDLE: begin
                    word_asm   <= 32'd0;
                    byte_cnt   <= 3'd0;
                    byte_total <= 32'd0;
                    aud_wr_cnt <= 21'd0;
                    if (aud_req_pulse || ald_start_pulse)
                        pstate <= P_WAIT_HDR;
                end

                P_WAIT_HDR: begin
                    if (w_hdr_ok) begin
                        aud_wr_len <=
                            ((((w_data_bytes + 32'd3) >> 2) + 32'd255) >> 8) << 8;
                        aud_wr_req <= 1'b1;
                        pstate     <= P_ACK;
                    end
                end

                P_ACK: begin
                    if (write_req_ack) begin
                        aud_wr_req    <= 1'b0;
                        aud_wr_active <= 1'b1;
                        pstate        <= P_STREAM;
                    end
                end

                P_STREAM: begin
                    if (wav_sval) begin
                        byte_total <= byte_total + 32'd1;
                        if (aud_word_done) begin
                            aud_wr_cnt <= aud_wr_cnt + 21'd1;
                            byte_cnt   <= 3'd0;
                            word_asm   <= 32'd0;
                            if (aud_last_byte)
                                pstate <= (aud_wr_cnt + 21'd1 >= aud_wr_len)
                                          ? P_DONE : P_PAD;
                        end
                        else begin
                            case (byte_cnt)
                                3'd0:    word_asm[7:0]   <= wav_smp;
                                3'd1:    word_asm[15:8]  <= wav_smp;
                                3'd2:    word_asm[23:16] <= wav_smp;
                                default: ;
                            endcase
                            byte_cnt <= byte_cnt + 3'd1;
                        end
                    end
                end

                P_PAD: begin
                    aud_wr_cnt <= aud_wr_cnt + 21'd1;
                    if (aud_wr_cnt + 21'd1 >= aud_wr_len)
                        pstate <= P_DONE;
                end

                default: ;   // P_DONE：等 aud_item_close
            endcase
        end
    end

    // ==================== 音频播放（S3/S4）====================
    // 25M 使能域（clk/4，与板上像素域同节奏）：读口顺序读当前音频缓冲 BUF2/3，
    // 每 521 个 25M 周期出一个样本（×2 上采样 = 48k 口，实际 47.985k，
    // 板级 ACR 声明 N=6144/CTS=25008 编码 ÷521，与像素时钟无关、零漂移）。
    // 队列为 2 字深弹性缓冲：rd_en 发一拍，read_data 下一拍有效并保持到下次 rd_en。
    // 主域提交握手（cmt_new）换源：有配对→重开读通道循环重播；无配对→静音态
    // （aud_valid=1、样本 0，不开读通道）。一路自然放完 aud_play_done 脉冲一拍后回卷。
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            div25             <= 2'd0;
            plstate           <= PL_WAIT;
            rd_req_r          <= 1'b0;
            rd_en_r           <= 1'b0;
            aud_cmt_taken     <= 1'b0;
            pb_pair           <= 1'b0;
            pb_buf            <= 2'd2;
            pb_len            <= 21'd0;
            ch_open           <= 1'b0;
            ch_closed         <= 1'b0;
            rd_outst          <= 1'b0;
            have_cur          <= 1'b0;
            have_nxt          <= 1'b0;
            cur_word          <= 32'd0;
            nxt_word          <= 32'd0;
            byte_pos          <= 3'd0;
            phase             <= 1'b0;
            tick_cnt          <= 10'd0;
            aud_valid         <= 1'b0;
            aud_l             <= 24'd0;
            aud_r             <= 24'd0;
            aud_play_done_r   <= 1'b0;
            aud_underrun_pulse <= 1'b0;
        end
        else begin
            div25 <= div25 + 2'd1;
            // rd_en 必须是单 clk 脉冲（每拍清零，en25 内的置位同拍后写覆盖生效）。
            // 真实 FIFO rfifo_32_32_512 语义：re 为高的每一拍弹一字。若清零放在
            // en25 内，rd_en 为 4 clk 宽 → 一次弹 4 字只捕获 1 字，FIFO 净消耗
            // ×4：5s 文件 1.26s 即回卷（周期性咔声）、音调 ×4。此前 C++ 模型按
            // 上升沿计一次取字，把本 bug 当正确行为建模，仿真不可见。2026-09-27。
            rd_en_r            <= 1'b0;
            if (en25) begin
                aud_underrun_pulse <= 1'b0;
                aud_play_done_r    <= 1'b0;
                if (tick48) tick_cnt <= 10'd0;
                else        tick_cnt <= tick_cnt + 10'd1;

                // 提交握手：taken 锁存到主域撤 valid 后回零
                if (cmt_new)      aud_cmt_taken <= 1'b1;
                else if (!aud_cmt_valid) aud_cmt_taken <= 1'b0;

                case (plstate)
                    PL_WAIT: begin
                        aud_valid <= 1'b0;
                        rd_req_r  <= 1'b0;
                        if (cmt_new) begin
                            if (cmt_pair) begin
                                pb_pair   <= 1'b1;
                                pb_buf    <= cmt_buf;
                                pb_len    <= cmt_len;
                                ch_open   <= 1'b0;
                                ch_closed <= 1'b0;
                                rd_outst  <= 1'b0;
                                have_cur  <= 1'b0;
                                have_nxt  <= 1'b0;
                                byte_pos  <= 3'd0;
                                phase     <= 1'b0;
                                rd_req_r  <= 1'b1;
                                plstate   <= PL_REQ;
                            end
                            else begin
                                pb_pair <= 1'b0;
                                plstate <= PL_SIL;
                            end
                        end
                    end

                    PL_REQ: begin
                        if (rd_ack_s1) begin
                            rd_req_r  <= 1'b0;
                            ch_open   <= 1'b1;
                            ch_closed <= 1'b0;
                            plstate   <= PL_RUN;
                        end
                        // 提交换源：放弃本通道，按新提交重来。
                        // 必须经 PL_REQ2 先撤一拍 req：读口把"请求上升沿"当新事务
                        // 锁存地址/长度（真实 frame_fifo_read 同语义），req 不撤
                        // 直接重拉 = 沿丢失，新缓冲会从旧位置续读（旧音频尾巴）。
                        if (cmt_new) begin
                            rd_req_r <= 1'b0;
                            if (cmt_pair) begin
                                pb_pair  <= 1'b1;
                                pb_buf   <= cmt_buf;
                                pb_len   <= cmt_len;
                                plstate  <= PL_REQ2;
                            end
                            else begin
                                pb_pair <= 1'b0;
                                plstate <= PL_SIL;
                            end
                        end
                    end

                    PL_REQ2: begin   // 换源重请求：req 已撤一拍，上升沿干净
                        rd_req_r <= 1'b1;
                        plstate  <= PL_REQ;
                    end

                    PL_RUN: begin
                        // 取字补充队列
                        if (ch_open && !ch_closed && !have_nxt && !rd_outst) begin
                            rd_en_r  <= 1'b1;
                            rd_outst <= 1'b1;
                        end
                        if (rd_outst) begin
                            rd_outst <= 1'b0;
                            if (!have_cur) begin
                                cur_word <= rd_data;
                                have_cur <= 1'b1;
                            end
                            else begin
                                nxt_word <= rd_data;
                                have_nxt <= 1'b1;
                            end
                        end
                        if (rd_fin_s1)
                            ch_closed <= 1'b1;

                        // 48k 节拍输出：样本每两个 tick 重复一次（×2 上采样）
                        if (tick48) begin
                            if (have_cur) begin
                                aud_valid <= 1'b1;
                                aud_l     <= cur_samp;
                                aud_r     <= cur_samp;
                                if (phase) begin
                                    phase <= 1'b0;
                                    if (byte_pos == 3'd3) begin
                                        byte_pos <= 3'd0;
                                        cur_word <= nxt_word;
                                        have_cur <= have_nxt;
                                        have_nxt <= 1'b0;
                                    end
                                    else byte_pos <= byte_pos + 3'd1;
                                end
                                else phase <= 1'b1;
                            end
                            else begin
                                aud_valid <= 1'b0;
                                aud_underrun_pulse <= 1'b1;
                            end
                        end

                        // 一路放完：脉冲一拍后回卷重播（等图切换或循环）
                        if (ch_closed && !have_cur && !have_nxt && !rd_outst) begin
                            aud_play_done_r <= 1'b1;
                            ch_open   <= 1'b0;
                            ch_closed <= 1'b0;
                            byte_pos  <= 3'd0;
                            phase     <= 1'b0;
                            rd_req_r  <= 1'b1;
                            plstate   <= PL_REQ;
                        end

                        // 提交换源：立即丢弃旧流，按新提交播放
                        if (cmt_new) begin
                            ch_open   <= 1'b0;
                            ch_closed <= 1'b0;
                            rd_outst  <= 1'b0;
                            have_cur  <= 1'b0;
                            have_nxt  <= 1'b0;
                            byte_pos  <= 3'd0;
                            phase     <= 1'b0;
                            if (cmt_pair) begin
                                pb_pair  <= 1'b1;
                                pb_buf   <= cmt_buf;
                                pb_len   <= cmt_len;
                                plstate  <= PL_REQ;
                                rd_req_r <= 1'b1;
                            end
                            else begin
                                pb_pair <= 1'b0;
                                plstate <= PL_SIL;
                            end
                        end
                    end

                    default: begin   // PL_SIL 静音态：48k 节拍输出零点，不开读通道
                        rd_req_r <= 1'b0;
                        if (tick48) begin
                            aud_valid <= 1'b1;
                            aud_l     <= 24'd0;
                            aud_r     <= 24'd0;
                        end
                        if (cmt_new && cmt_pair) begin
                            pb_pair   <= 1'b1;
                            pb_buf    <= cmt_buf;
                            pb_len    <= cmt_len;
                            ch_open   <= 1'b0;
                            ch_closed <= 1'b0;
                            rd_outst  <= 1'b0;
                            have_cur  <= 1'b0;
                            have_nxt  <= 1'b0;
                            byte_pos  <= 3'd0;
                            phase     <= 1'b0;
                            rd_req_r  <= 1'b1;
                            plstate   <= PL_REQ;
                        end
                    end
                endcase
            end
        end
    end

    // ==================== 音频扫描相位（S1/S4）====================
    // 首图提交后启动。前导 npass 保留原来按 file_cnt 等待的拍数；
    // 主名/类型已保存在 fat32_ro，pmatch 阶段分时复用其组合查找口。
    // 然后顺序遍历 WAV 项送 wav_reader 解析；合法项关闭时锁存长度进 wav_len_rec，
    // 并起 pmatch 顺序比对 BMP 主名，命中则记 pair_valid/pair_wav 配对表。
    // 全部项走完后置 aud_scan_done，开放轮播。与图像装载共用单 fat32_ro（分时）。
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            aud_scan_active     <= 1'b0;
            aud_scan_done_r     <= 1'b0;
            aud_k               <= 6'd0;
            aud_item_active     <= 1'b0;
            aud_req_pulse       <= 1'b0;
            scan_kick        <= 1'b0;
            aud_req_idx         <= 5'd0;
            aud_item_done_pulse <= 1'b0;
            npass_active        <= 1'b0;
            npass_k             <= 6'd0;
            aud_cur_name        <= 64'd0;
            pmatch_active       <= 1'b0;
            pmatch_j            <= 6'd0;
            pair_valid          <= 32'd0;
        end
        else begin
            aud_req_pulse       <= 1'b0;
            scan_kick           <= 1'b0;
            aud_item_done_pulse <= 1'b0;

            if (!sd_init_done) begin
                aud_scan_active <= 1'b0;
                aud_scan_done_r <= 1'b0;
                aud_k           <= 6'd0;
                aud_item_active <= 1'b0;
                npass_active    <= 1'b0;
                pair_valid      <= 32'd0;
            end
            else if (scan_start_pulse) begin
                // 外控块首图提交 / 音频自愈重扫：启动扫描（本块独占扫描相位
                // 寄存器，避免多驱动）。⚠ 必须清 done_r——自愈重扫期间若不清，
                // boot_ald 触发条件在 1 拍后重新成立，用旧扫描数据提前点火。
                aud_scan_active <= 1'b1;
                aud_scan_done_r <= 1'b0;
                aud_k           <= 6'd0;
                npass_active    <= 1'b1;
                npass_k         <= 6'd0;
            end
            else if (scan_nowav_pulse) begin
                aud_scan_done_r <= 1'b1;
            end
            else if (aud_scan_active) begin
                if (npass_active) begin
                    // 原名字快照阶段的等待节奏保留，不再复制重复表项。
                    if (npass_k + 6'd1 >= file_cnt)
                        npass_active <= 1'b0;
                    npass_k <= npass_k + 6'd1;
                end
                else if (pmatch_active) begin
                    // 合法 WAV 项关闭后：顺序比对 BMP 主名（同主名 = 配对）
                    if (pmatch_j >= file_cnt)
                        pmatch_active <= 1'b0;
                    else begin
                        if (pl_valid && !pl_is_wav && (pl_name == aud_cur_name)) begin
                            pair_valid[pmatch_j[4:0]] <= 1'b1;
                            pair_wav[pmatch_j[4:0]]   <= {1'b0, aud_req_idx};
                        end
                        pmatch_j <= pmatch_j + 6'd1;
                    end
                end
                else if (!aud_item_active) begin
                    if (aud_k >= file_cnt) begin
                        // 全部项遍历完
                        aud_scan_active <= 1'b0;
                        aud_scan_done_r <= 1'b1;
                    end
                    else if (fat_idle) begin
                        if (pl_is_wav) begin
                            aud_req_pulse <= 1'b1;  // 复位 wav_reader（文件请求经 FSM）
                            scan_kick     <= 1'b1;  // → 装载 FSM 单主人仲裁发文件请求
                            aud_req_idx   <= aud_k[4:0];
                            aud_cur_name    <= pl_name; // 锁存主名（pmatch 用）
                            aud_item_active <= 1'b1;
                        end
                        aud_k <= aud_k + 6'd1;
                    end
                end
                else if (aud_item_close) begin
                    // 当前 WAV 项流完且 BUF2 写尽（拒绝项无写通道，file_done 即关）
                    aud_item_active     <= 1'b0;
                    aud_item_done_pulse <= 1'b1;
                    if (aud_wr_active) begin
                        // 合法项：起配对比对（pmatch 完成前不发下一项请求）
                        pmatch_active <= 1'b1;
                        pmatch_j      <= 6'd0;
                    end
                end
            end
        end
    end

endmodule


// =============================================================================
// key_press_debounce — 按键去抖（例程原样保留）
// =============================================================================
module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse
);

    localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

    reg button_sync0;
    reg button_sync1;
    reg button_stable;
    reg [31:0] cnt;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            button_sync0  <= 1'b1;
            button_sync1  <= 1'b1;
            button_stable <= 1'b1;
            cnt           <= 32'd0;
            press_pulse   <= 1'b0;
        end else begin
            button_sync0 <= button_in;
            button_sync1 <= button_sync0;
            press_pulse  <= 1'b0;

            if (button_sync1 == button_stable) begin
                cnt <= 32'd0;
            end else begin
                if (cnt >= DEBOUNCE_CYCLES - 1) begin
                    if (button_stable && !button_sync1)
                        press_pulse <= 1'b1;
                    button_stable <= button_sync1;
                    cnt           <= 32'd0;
                end else begin
                    cnt <= cnt + 32'd1;
                end
            end
        end
    end

endmodule
