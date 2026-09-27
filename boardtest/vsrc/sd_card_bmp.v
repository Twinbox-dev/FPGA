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
//   扫描相位前导先把播放列表全部条目的 8 字节主名快照进 pl_names[0:31]；
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
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4
)(
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       key_auto,
    input  [15:0]               bmp_width,     // 保留（bmp_dec 内部硬编码 640x480）
    input  [15:0]               bmp_height,
    output reg                  display_valid,
    output      [3:0]           state_code,
    // ---- 板级调试面板（仅板上接线；仿真空置）----
    output      [7:0]           dbg_fat_state,
    output                      dbg_fat_err,

    input                       write_finish_toggle,
    output reg  [1:0]           disp_buf_idx,

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    output [1:0]                write_buf_idx,   // 0/1=图像乒乓  2=音频 BUF2
    output [20:0]               write_len,       // 本次写通道长度（字）：图像 307200 / 音频取整 256
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
    input                       SD_MISO
);

    // ==================== 声明区（先声明后使用，TD 解析要求） ====================

    // ---- 键去抖 ----
    wire key_next_press;
    wire key_auto_press;

    // ---- 扇区读通道（fat32_ro 主机 / sd_card_top 从机，经适配器） ----
    wire        sd_init_done;
    wire [31:0] sec_lba;
    wire        sec_req, sec_ready, sec_dval, sec_done, sec_err;
    wire [7:0]  sec_data;

    // ---- 文件字节流 / 状态 ----
    wire [7:0]  file_byte;
    wire        file_bval, file_done;
    wire        fat_mounted, fat_idle, fat_err, cur_is_wav;
    wire [5:0]  file_cnt, bmp_cnt, wav_cnt, type_map;
    wire [5:0]  first_bmp_w;          // fat32_ro 建：首个 BMP 索引（轮播起点）
    wire [191:0] bmp_nxt_map;         // fat32_ro 建：BMP 循环下一跳表（6bit × 32）
    wire [7:0]  fat_dbg, bmp_dbg;
    wire        img_ok, img_err;
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
    reg         write_req_r;
    reg  [1:0]  write_buf_idx_r;      // 图像装载目标缓冲（音频扫描期输出被 mux 成 2/BUF2）

    // ---- 装载序列 FSM ----
    localparam [1:0] LD_IDLE = 2'd0, LD_MEM_ACK = 2'd1, LD_FILE = 2'd2;
    reg [1:0] ld_state;
    reg       file_req;
    reg [4:0] file_idx;
    reg       aud_item_done_pulse;

    // ---- 外控 ----
    reg [2:0]  wrfin_tgl_sync;
    wire       write_finish_pulse;
    wire       auto_tick;
    reg        load_start_pulse;      // 装载发起一拍（同时复位 bmp_dec）
    reg [5:0]  load_idx              /*verilator public_flat_rd*/;    // 当前装载的播放列表索引
    reg [5:0]  img_idx;               // 轮播光标（当前显示/最近尝试的图片索引）
    reg [5:0]  first_idx_r;           // 首图候选（坏图时推进，避免上电卡死在坏图）
    reg        first_idx_captured;
    reg [1:0]  pending_buf_idx;       // 当前装载目标缓冲
    reg        load_busy;
    reg        write_done_seen;       // 整帧已落盘（write_finish 同步后）
    reg        first_image_committed;
    reg        auto_play_en;
    reg [31:0] auto_cnt;
    reg [31:0] load_timeout_cnt;
    reg        next_req_pending;

    // ---- 音频扫描相位（S1）----
    reg        aud_scan_active;
    reg        aud_scan_done_r;
    reg [5:0]  aud_k;                 // 播放列表扫描游标
    reg        aud_item_active;       // 一个 WAV 项正在流
    reg        aud_req_pulse;         // 请求发起一拍（同拍复位 wav_reader）
    reg [4:0]  aud_req_idx           /*verilator public_flat_rd*/;

    // ---- 音频打包器 / 写通道（S2：PCM 字节 → 32 位字 → BUF2）----
    localparam [2:0] P_IDLE = 3'd0, P_WAIT_HDR = 3'd1, P_ACK = 3'd2,
                     P_STREAM = 3'd3, P_PAD = 3'd4, P_DONE = 3'd5;
    reg [2:0]  pstate              /*verilator public_flat_rd*/;
    reg        aud_wr_req;            // 音频写通道请求（保持到 ack）
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
    reg [2:0]  plstate              /*verilator public_flat_rd*/;
    reg [1:0]  div25;
    reg        rd_req_r, rd_en_r;
    reg        pb_pair;               // 当前播放：1=配对 WAV / 0=静音
    reg [1:0]  pb_buf;                // 当前播放的音频缓冲（2/3）
    reg [20:0] pb_len                /*verilator public_flat_rd*/;
    reg        ch_open, ch_closed, rd_outst /*verilator public_flat_rd*/;
    // 读口返回信号（ext_mem_clk 域）→ 本域双拍同步（电平语义，延迟 2 拍无害；
    // 直跨在 STA 上报 -1.4ns 违例，且亚稳态会丢 finish/ack）
    reg        rd_ack_s0, rd_ack_s1, rd_fin_s0, rd_fin_s1;
    reg        have_cur, have_nxt /*verilator public_flat_rd*/;
    reg [31:0] cur_word, nxt_word /*verilator public_flat_rd*/;
    reg [2:0]  byte_pos /*verilator public_flat_rd*/;    // 当前字内样本字节 0..3
    reg        phase /*verilator public_flat_rd*/;       // 同一 24k 样本的两次 48k 输出
    reg [9:0]  tick_cnt;
    reg        aud_play_done_r, aud_underrun_pulse;
    reg        aud_tick_r;

    // ---- 同名配对（S4）：名字快照 + BMP↔WAV 配对表 ----
    reg        scan_start_pulse;      // 外控→扫描相位：启动扫描（单写方：外控块）
    reg        scan_nowav_pulse;      // 外控→扫描相位：无 WAV 直接置 scan_done（单写方：外控块）
    reg        npass_active;          // 名字快照扫描（音频扫描相位前导）
    reg [5:0]  npass_k;
    reg [63:0] pl_names [0:31];       // 全条目 8 字节主名快照（字节 k 在 [8k+7:8k]）
    reg [31:0] pl_iswav_map;          // 位 k = 条目 k 是 WAV
    reg [63:0] aud_cur_name;          // 当前扫描项名字（请求拍锁存）
    reg        pmatch_active;         // 合法项关闭后顺序比对 BMP 名
    reg [5:0]  pmatch_j;
    reg [31:0] pair_valid /*verilator public_flat_rd*/;    // 位 j = BMP j 有合法同名 WAV
    reg [5:0]  pair_wav    [0:31] /*verilator public_flat_rd*/;    // BMP j → WAV 索引
    reg [20:0] wav_len_rec [0:31];    // WAV k 可播长度（字）

    // ---- 音频随图装载（S4）：配对 WAV 重读入空闲 BUF2/3，就绪后与图原子提交 ----
    reg        ald_active             /*verilator public_flat_rd*/;
    reg        ald_start_pulse;       // 请求拍：restart wav_reader + 触发打包器
    reg        boot_ald;              // 本次 ald 为 boot 首图配对（完成时不切图只换音）
    reg        ald_boot_done;         // boot 音频已安排（防重复）
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

    // ==================== 组合赋值 ====================
    // ---- 写口 mux：图像装载走 pix_val/{pix,8'h0}（buf 0/1），音频走打包器。
    // 音频目标缓冲：扫描相位固定 BUF2；随图装载（ald）写入 aud_disp_buf 对侧 BUF2/3。
    // 三相位互斥（扫描/ald/图像装载两两不重叠），write_req/ack 握手天然无竞争。
    wire aud_wr_phase = aud_scan_active | ald_active;
    assign write_req      = write_req_r | aud_wr_req;
    assign write_en       = aud_wr_phase  ? aud_word_val : pix_val;
    assign write_data     = aud_wr_phase  ? aud_word     : {pix, 8'b0};
    assign write_buf_idx  = aud_scan_active ? 2'd2
                          : ald_active      ? ald_buf
                          :                   write_buf_idx_r;
    assign write_len      = aud_wr_phase  ? aud_wr_len   : 21'd307200;
    assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
    assign auto_tick  = (auto_cnt == (CLK_FREQ_HZ - 1));
    assign next_idx   = bmp_nxt_map[6*img_idx[4:0] +: 6];

    assign dbg_fat_state = fat_dbg;
    assign dbg_fat_err   = fat_err;

    // ---- 状态码（数码管）：1 空闲 2 挂载/扫描 3 FIFO 握手 4 写帧 ----
    assign state_code = !sd_init_done               ? 4'd0
                      : !fat_mounted                ? 4'd2
                      : (ld_state == LD_MEM_ACK)    ? 4'd3
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
        .i_file_idx  (aud_req_pulse ? aud_req_idx
                      : ald_active  ? ald_wav_idx[4:0]
                      :               file_idx),
        .i_file_req  (file_req | aud_req_pulse),
        .o_mounted   (fat_mounted),
        .o_file_cnt  (file_cnt),
        .o_bmp_cnt   (bmp_cnt),
        .o_wav_cnt   (wav_cnt),
        .o_type_map  (type_map),
        .o_first_bmp (first_bmp_w),
        .o_bmp_nxt   (bmp_nxt_map),
        .o_cur_is_wav(cur_is_wav),
        .o_err       (fat_err),
        .o_file_idle (fat_idle),
        .o_dbg_state (fat_dbg),
        .i_pl_idx    (npass_active ? npass_k[4:0] : aud_k[4:0]),
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
        .o_dbg_state(bmp_dbg)
    );

    // SD SPI 层（板上已验证，原样保留）
    sd_card_top sd_card_top_m0 (
        .clk                    (clk),
        .rst                    (rst),
        .SD_nCS                 (SD_nCS),
        .SD_DCLK                (SD_DCLK),
        .SD_MOSI                (SD_MOSI),
        .SD_MISO                (SD_MISO),
        .sd_init_done           (sd_init_done),
        .sd_sec_read            (sd_sec_read),
        .sd_sec_read_addr       (sd_sec_read_addr),
        .sd_sec_read_data       (sd_sec_read_data),
        .sd_sec_read_data_valid (sd_sec_read_data_valid),
        .sd_sec_read_end        (sd_sec_read_end),
        .sd_sec_write           (1'b0),
        .sd_sec_write_addr      (32'd0),
        .sd_sec_write_data      (8'd0),
        .sd_sec_write_data_req  (),
        .sd_sec_write_end       ()
    );

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
        end
        else begin
            file_req <= 1'b0;
            case (ld_state)
                LD_IDLE: begin
                    if (load_start_pulse) begin
                        write_req_r <= 1'b1;
                        ld_state    <= LD_MEM_ACK;
                    end
                    else if (ld_kick) begin
                        ld_state    <= LD_FILE;
                    end
                end
                LD_MEM_ACK: begin
                    if (write_req_ack) begin
                        write_req_r <= 1'b0;
                        ld_state    <= LD_FILE;
                    end
                end
                LD_FILE: begin
                    // fat32 只在 MOUNTED 态收请求：忙时保持等待，一拍脉冲不被丢弃
                    if (fat_idle) begin
                        file_req <= 1'b1;
                        file_idx <= ald_active ? ald_wav_idx[4:0] : load_idx[4:0];
                        ld_state <= LD_IDLE;
                    end
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
        end
        else begin
            wrfin_tgl_sync  <= {wrfin_tgl_sync[1:0], write_finish_toggle};
            load_start_pulse<= 1'b0;
            ld_kick         <= 1'b0;
            ald_start_pulse <= 1'b0;
            scan_start_pulse<= 1'b0;
            scan_nowav_pulse<= 1'b0;

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
                display_valid         <= 1'b0;
                ald_active            <= 1'b0;
                boot_ald              <= 1'b0;
                ald_boot_done         <= 1'b0;
                aud_disp_buf          <= 2'd2;
                aud_cmt_valid         <= 1'b0;
            end
            else if (fat_err) begin
                // FAT 挂载失败/索引越界：清装载，保持黑屏
                load_busy        <= 1'b0;
                load_timeout_cnt <= 32'd0;
                write_done_seen  <= 1'b0;
            end
            else begin
                // ---- 挂载完成：捕获首图候选（坏图推进）----
                if (fat_mounted && !first_idx_captured) begin
                    first_idx_r      <= first_bmp_w;
                    first_idx_captured <= 1'b1;
                end

                // ---- 装载完成 / 放弃 / 超时 ----
                // 装载发起的那一拍跳过（load_start_pulse=1），
                // 等 bmp_dec 已被 i_restart 复位、img_ok/img_err 清零后再判。
                if (load_busy && !load_start_pulse) begin
                    if (write_finish_pulse)
                        write_done_seen <= 1'b1;

                    if (ald_active) begin
                        // ---- 音频装载子相位：等打包器关闭（eof + write_finish 双确认）----
                        if (aud_item_close) begin
                            ald_active       <= 1'b0;
                            load_busy        <= 1'b0;
                            load_timeout_cnt <= 32'd0;
                            aud_disp_buf     <= ald_buf;
                            aud_cmt_valid    <= 1'b1;   // 与图同一拍握手：原子提交
                            cmt_pair         <= 1'b1;
                            cmt_buf          <= ald_buf;
                            cmt_len          <= wav_len_rec[ald_wav_idx[4:0]];
                            if (!boot_ald) begin
                                // 随图切换：切显示缓冲 + 光标（boot：图已在显示，只换音）
                                write_done_seen <= 1'b0;
                                disp_buf_idx    <= pending_buf_idx;
                                img_idx         <= load_idx;
                                display_valid   <= 1'b1;
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
                            disp_buf_idx          <= pending_buf_idx;
                            img_idx               <= load_idx;
                            display_valid         <= 1'b1;
                            first_image_committed <= 1'b1;
                            aud_cmt_valid         <= 1'b1;
                            cmt_pair              <= 1'b0;
                            cmt_buf               <= aud_disp_buf;
                            cmt_len               <= 21'd0;
                            if (wav_cnt != 6'd0) begin
                                scan_start_pulse <= 1'b1;
                            end
                            else begin
                                scan_nowav_pulse <= 1'b1;
                            end
                        end
                    end
                    else if (load_timeout_cnt > 32'd100_000_000) begin
                        // 超时（坏卡/坏文件卡住）：强制释放，恢复按键
                        load_busy        <= 1'b0;
                        load_timeout_cnt <= 32'd0;
                        write_done_seen  <= 1'b0;
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
                if (aud_scan_done_r && !ald_boot_done && !load_busy && fat_idle &&
                    first_image_committed) begin
                    ald_boot_done <= 1'b1;
                    if (pair_valid[img_idx[4:0]]) begin
                        boot_ald        <= 1'b1;
                        ald_active      <= 1'b1;
                        load_busy       <= 1'b1;
                        ald_buf         <= (aud_disp_buf == 2'd2) ? 2'd3 : 2'd2;
                        ald_wav_idx     <= pair_wav[img_idx[4:0]];
                        ld_kick         <= 1'b1;
                        ald_start_pulse <= 1'b1;
                    end
                end

                // ---- 按键请求（装载中只记一次，连按不累积）----
                if (key_next_press && fat_mounted && (bmp_cnt != 6'd0))
                    next_req_pending <= 1'b1;

                // ---- 自动轮播开/关 ----
                if (key_auto_press && fat_mounted && (bmp_cnt > 6'd1)) begin
                    auto_play_en <= ~auto_play_en;
                    auto_cnt     <= 32'd0;
                end

                // ---- 自动轮播 1s 计时（仅空闲且已首图提交）----
                if (fat_mounted && auto_play_en && display_valid && !load_busy &&
                    first_image_committed && (bmp_cnt > 6'd1)) begin
                    if (auto_tick) auto_cnt <= 32'd0;
                    else           auto_cnt <= auto_cnt + 32'd1;
                end
                else begin
                    auto_cnt <= 32'd0;
                end

                // ---- 发起装载：首图 / 手动 / 自动（扫描与 boot 音频安排期间不发起）----
                if (fat_mounted && fat_idle && !load_busy && !aud_scan_active &&
                    (!aud_scan_done_r || ald_boot_done) && (bmp_cnt != 6'd0)) begin
                    if (!first_image_committed) begin
                        // 首图：写 buffer0（首图候选可能已被坏图推进）
                        load_idx         <= first_idx_r;
                        pending_buf_idx  <= 2'd0;
                        write_buf_idx_r <= 2'd0;
                        load_busy        <= 1'b1;
                        load_start_pulse <= 1'b1;
                        write_done_seen  <= 1'b0;
                        next_req_pending <= 1'b0;
                        auto_cnt         <= 32'd0;
                    end
                    else if (next_req_pending) begin
                        // 手动下一张：写非当前显示缓冲
                        load_idx         <= next_idx;
                        pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                        write_buf_idx_r <= next_buf_lut(disp_buf_idx, display_valid);
                        load_busy        <= 1'b1;
                        load_start_pulse <= 1'b1;
                        write_done_seen  <= 1'b0;
                        next_req_pending <= 1'b0;
                        auto_cnt         <= 32'd0;
                    end
                    else if (auto_play_en && auto_tick && (bmp_cnt > 6'd1)) begin
                        load_idx         <= next_idx;
                        pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                        write_buf_idx_r <= next_buf_lut(disp_buf_idx, display_valid);
                        load_busy        <= 1'b1;
                        load_start_pulse <= 1'b1;
                        write_done_seen  <= 1'b0;
                        next_req_pending <= 1'b0;
                        auto_cnt         <= 32'd0;
                    end
                end
            end
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
    // 首图提交后启动。前导 npass：每拍快照一个播放列表条目的主名/类型
    // （pl 查找口组合读出，31 拍扫完 31 项上限），建 pl_names/pl_iswav_map。
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
            aud_req_idx         <= 5'd0;
            aud_item_done_pulse <= 1'b0;
            npass_active        <= 1'b0;
            npass_k             <= 6'd0;
            pl_iswav_map        <= 32'd0;
            aud_cur_name        <= 64'd0;
            pmatch_active       <= 1'b0;
            pmatch_j            <= 6'd0;
            pair_valid          <= 32'd0;
        end
        else begin
            aud_req_pulse       <= 1'b0;
            aud_item_done_pulse <= 1'b0;

            if (!sd_init_done) begin
                aud_scan_active <= 1'b0;
                aud_scan_done_r <= 1'b0;
                aud_k           <= 6'd0;
                aud_item_active <= 1'b0;
                npass_active    <= 1'b0;
                pl_iswav_map    <= 32'd0;
                pair_valid      <= 32'd0;
            end
            else if (scan_start_pulse) begin
                // 外控块首图提交：启动扫描（本块独占扫描相位寄存器，避免多驱动）
                aud_scan_active <= 1'b1;
                aud_k           <= 6'd0;
                npass_active    <= 1'b1;
                npass_k         <= 6'd0;
            end
            else if (scan_nowav_pulse) begin
                aud_scan_done_r <= 1'b1;
            end
            else if (aud_scan_active) begin
                if (npass_active) begin
                    // 名字快照：pl 查找口组合有效，一拍一项（i_pl_idx=npass_k）
                    pl_names[npass_k[4:0]]  <= pl_name;
                    pl_iswav_map[npass_k[4:0]] <= pl_is_wav;
                    if (npass_k + 6'd1 >= file_cnt)
                        npass_active <= 1'b0;
                    npass_k <= npass_k + 6'd1;
                end
                else if (pmatch_active) begin
                    // 合法 WAV 项关闭后：顺序比对 BMP 主名（同主名 = 配对）
                    if (pmatch_j >= file_cnt)
                        pmatch_active <= 1'b0;
                    else begin
                        if (!pl_iswav_map[pmatch_j[4:0]] &&
                            (pl_names[pmatch_j[4:0]] == aud_cur_name)) begin
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
                            aud_req_pulse   <= 1'b1;   // 请求文件 + 复位 wav_reader
                            aud_req_idx     <= aud_k[4:0];
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
