// board_sim.cpp — 板级 sd_card_bmp（新 FAT32 版）的 Verilator 验证驱动
//
// 目的：把「板上新逻辑」——sd_adapter + 装载 FSM + 外控 —— 在仿真里跑绿，
//      再上板。SD 层用测试桩（sd_spi + 引脚级卡模型），帧存储写口用 C++ 模型
//      （近似 frame_fifo_write 的 write_req/ack 与 write_finish）。
//
// 检查点：
//   S1 挂载 + 首图装载提交（display_valid）+ 像素与 golden 逐像素比对
//   SA 音频扫描相位：首图提交后遍历卡内 WAV 项，逐项校验
//      （合法：hdr_ok + PCM 字节流与 golden 逐字节比对 + data_bytes 一致；
//        非法：fmt_err + 无样本流出）——规则与 vsrc/wav_reader.v 逐条一致
//   SB 扫描项 BUF2 重建内容比对（写长度 + 0x80 填充）
//   SC boot 播放：首图配对 WAV 在 BUF3 循环（逐字节 ×2 上采样 + len/缓冲断言）
//   SD/SE/SF 随图切换：配对 WAV 重读入对侧 BUF2/3 与图原子提交；无配对→静音态
//   S2-S4 按键 → 第二/三/四张提交 + 像素比对
//   S5/S6 坏图 / WAV 项跳过不提交
//   SCb 全程零欠采样
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <chrono>
#include <vector>
#include "verilated.h"
#include "Vboard_top.h"
#include "Vboard_top___024root.h"
#include "sd_card_model.h"
#include "fat32_golden.h"

// 720p + RGB565：帧缓冲 1 字 = 2 像素，460800 字/帧
static const size_t N_WORDS = (size_t)1280 * 720 / 2;

static VerilatedContext *ctx = new VerilatedContext;
static const std::chrono::steady_clock::time_point g_t0 = std::chrono::steady_clock::now();
static Vboard_top *dut = new Vboard_top;
static SdCardModel card;

// SIM_FAST=1：SD 直连扇区档（fast_sd_stub），SPI 协议栈退出仿真覆盖。
// 日常迭代用；定位可疑 bug 时先用默认档（引脚级）排除 SPI 因素。
static const bool g_fast_sd = getenv("SIM_FAST") != nullptr;
static const std::vector<uint8_t> *g_img = nullptr;   // 快速档按 LBA 直取扇区字节

static int pass = 0, fail = 0;
static void check(bool ok, const char *what) {
    std::printf("%s: %s\n", ok ? "  PASS" : ">>FAIL", what);
    if (ok) pass++; else fail++;
}

// ---- 与 RTL 一致的图片选择逻辑 ----
// tmap 覆盖全部播放列表项（RTL 跳表按全范围 ext_is_wav 建链）
static int first_bmp_idx(int cnt, uint32_t tmap) {
    for (int k = 0; k < cnt; k++)
        if (!((tmap >> k) & 1u)) return k;
    return 0;
}
static int next_bmp_idx(int cur, int cnt, uint32_t tmap) {
    int cand = cur;
    for (int k = 0; k < cnt; k++) {
        cand = (cand + 1 >= cnt) ? 0 : cand + 1;
        // RTL bmp_nxt/bmp_prv 跳表全范围只链 BMP（ext_is_wav 全 32 项判定），
        // 不受遗留 o_type_map 6 项限制——这里必须用完整 tmap
        bool is_wav = (tmap >> cand) & 1u;
        if (!is_wav) return cand;
    }
    return cur;
}

// 循环序上一张（与 bmp_prv_map / prv 方向一致；WAV 项不算图）
static int prv_bmp_idx(int cur, int cnt, uint32_t tmap) {
    int cand = cur;
    for (int k = 0; k < cnt; k++) {
        cand = (cand == 0) ? cnt - 1 : cand - 1;
        bool is_wav = (tmap >> cand) & 1u;
        if (!is_wav) return cand;
    }
    return cur;
}

// 该播放列表项是否为 bmp_dec 可装载的图（与 RTL 头校验一致）
static bool loadable_bmp(const std::vector<uint8_t> &d) {
    if (d.size() < 54 || d[0] != 0x42 || d[1] != 0x4D) return false;
    uint32_t w = (uint32_t)d[18] | ((uint32_t)d[19] << 8)
               | ((uint32_t)d[20] << 16) | ((uint32_t)d[21] << 24);
    uint32_t h = (uint32_t)d[22] | ((uint32_t)d[23] << 8)
               | ((uint32_t)d[24] << 16) | ((uint32_t)d[25] << 24);
    uint16_t bpp = (uint16_t)d[28] | ((uint16_t)d[29] << 8);
    uint32_t comp = (uint32_t)d[30] | ((uint32_t)d[31] << 8)
                  | ((uint32_t)d[32] << 16) | ((uint32_t)d[33] << 24);
    // 2026-10-03 多分辨率：与 bmp_dec 逐条一致（24bit/不压缩/1<=尺寸<=720p）
    return (w >= 1 && h >= 1 && w <= 1280 && h <= 720 && bpp == 24 && comp == 0);
}

// ---- 写口模型（近似 frame_read_write）：图像 buf 0/1、音频 BUF2/BUF3 分缓冲重建 ----
static std::vector<uint32_t> pixbuf;      // 最近一次图像装载（buf 0/1）
static std::vector<uint32_t> audbuf;      // 音频 BUF2 重建（扫描固定写 2，ald 乒乓 2/3）
static std::vector<uint32_t> audbuf3;     // 音频 BUF3 重建
static int   prev_wr = 0;
static int   wr_d1 = 0, wr_d2 = 0, wr_d3 = 0;
static int   wft = 0;
static bool  wft_set = false;

static std::vector<uint32_t> *aud_buf_for(int idx) {
    return (idx == 3) ? &audbuf3 : &audbuf;
}

static uint64_t cycles = 0;
static const bool g_verbose = getenv("SD_VERBOSE") != nullptr;

// ---- 写会话历史环（像素比对失败时打印，定位"模型丢会话/串会话"类问题）----
struct WrOpenEv { uint64_t cyc; int buf, ld, scanA, fillA, req_r, aud_req, len;
                  int hdr_ok, h_dec, w_dec, fidx, aldA; };
static WrOpenEv wr_hist[8];
static int wr_hist_n = 0, wr_hist_i = 0;
#define D(name) dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__##name
static void wr_hist_push(uint64_t cyc, int buf, int ld, int scanA, int fillA,
                         int req_r, int aud_req, int len) {
    wr_hist[wr_hist_i] = {cyc, buf, ld, scanA, fillA, req_r, aud_req, len,
                          (int)D(img_hdr_ok_dec), (int)D(img_h_dec), (int)D(img_w_dec),
                          (int)D(file_idx), (int)D(ald_active)};
    wr_hist_i = (wr_hist_i + 1) % 8;
    if (wr_hist_n < 8) wr_hist_n++;
}
static void wr_hist_dump() {
    std::printf("      写会话历史(最近%d条)：\n", wr_hist_n);
    for (int k = 0; k < wr_hist_n; k++) {
        WrOpenEv &e = wr_hist[(wr_hist_i + 8 - wr_hist_n + k) % 8];
        std::printf("      [cyc=%lld] buf=%d ld=%d scanA=%d fillA=%d req_r=%d aud_req=%d len=%u "
                    "hdr_ok=%d h_dec=%d w_dec=%d fidx=%d aldA=%d\n",
                    (long long)e.cyc, e.buf, e.ld, e.scanA, e.fillA, e.req_r, e.aud_req, e.len,
                    e.hdr_ok, e.h_dec, e.w_dec, e.fidx, e.aldA);
    }
}

static void sample_write() {
    int wr = dut->write_req;
    if (wr && !prev_wr) {              // 新写通道：按目标缓冲清场
        wr_hist_push(cycles, (int)dut->write_buf_idx,
                     (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__ld_state,
                     (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__aud_scan_active,
                     (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__fill_active,
                     (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__write_req_r,
                     (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__aud_wr_req,
                     (unsigned)dut->write_len);
        if (g_verbose)
            std::printf("    [cyc=%lld] WR_OPEN buf=%d ald_active=%d ald_wav=%d aud_req_idx=%d load_idx=%d sz2=%zu sz3=%zu\n",
                        (long long)cycles, (int)dut->write_buf_idx,
                        (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__ald_active,
                        (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__ald_wav_idx,
                        (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__aud_req_idx,
                        (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__load_idx,
                        audbuf.size(), audbuf3.size());
        if (dut->write_buf_idx == 2 || dut->write_buf_idx == 3)
            aud_buf_for(dut->write_buf_idx)->clear();
        else
            pixbuf.clear();
        wft_set = false;
    }
    static int last_fst = -1;
    int fst = dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__u_fat__DOT__state;
    if (g_verbose && fst != last_fst) {
        std::printf("    [fat=%d cyc=%lld] lba=%u ferr=%d\n", fst,
                    (long long)cycles, (unsigned)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__u_fat__DOT__rd_lba,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__fat_err);
        last_fst = fst;
    }
    if (g_verbose && wr != prev_wr)
        std::printf("    [wr%c cyc=%lld] idx=%d fillA=%d ld=%d wen=%d psz=%zu wlen=%u ferr=%d retry=%d kind=%d lba=%u\n", wr ? '+' : '-',
                    (long long)cycles, (int)dut->write_buf_idx,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__fill_active,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__ld_state,
                    (int)dut->write_en, pixbuf.size(), (unsigned)dut->write_len,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__fat_err,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__u_fat__DOT__retry,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__u_fat__DOT__rd_kind,
                    (unsigned)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__u_fat__DOT__rd_lba);
    prev_wr = wr;
    // hdr_ok / img_err 上升沿监视：抓"假头/陈旧尺寸"现行（每装载至多 1 次）
    static int prev_hdr = 0, prev_ierr = 0;
    int hdr = (int)D(img_hdr_ok_dec), ierr = (int)D(img_err);
    if (hdr && !prev_hdr)
        std::printf("    [HDROK cyc=%lld] h_dec=%d w_dec=%d fidx=%d ld=%d lidx=%d scanA=%d aldA=%d\n",
                    (long long)cycles, (int)D(img_h_dec), (int)D(img_w_dec),
                    (int)D(file_idx),
                    (int)D(ld_state), (int)D(load_idx),
                    (int)D(aud_scan_active), (int)D(ald_active));
    if (ierr && !prev_ierr)
        std::printf("    [IMGERR cyc=%lld] fidx=%d ld=%d lidx=%d scanA=%d\n",
                    (long long)cycles, (int)D(file_idx), (int)D(ld_state),
                    (int)D(load_idx), (int)D(aud_scan_active));
    prev_hdr = hdr; prev_ierr = ierr;
    int idx = dut->write_buf_idx;
    if (dut->write_en) {
        if (idx == 2 || idx == 3) aud_buf_for(idx)->push_back((uint32_t)dut->write_data);
        // 图像/涂黑会话：镜像 RTL 弹出门槛（write_cnt < write_len 封顶）——
        // 发射器会话末尾的填充字不入 SDRAM（2026-10-04 尾部收尾修复）
        else if (pixbuf.size() < N_WORDS && (uint32_t)dut->write_len > 0 &&
                 pixbuf.size() < (uint32_t)dut->write_len)
            pixbuf.push_back((uint32_t)dut->write_data);
    }
    // 整帧/整音频落盘 → 翻转 write_finish_toggle（长度以 RTL 声明的 write_len 为准）
    // ⚠ 图像会话长度不可硬编码 N_WORDS：多分辨率信箱会话 = img_h×640（可小于
    //   460800），硬编码会让模型永远等不到 finish → 装载 3s 超时（S5-S8 连锁假失败）
    uint32_t exp_len = (uint32_t)dut->write_len;
    size_t   cur_sz  = (idx == 2 || idx == 3) ? aud_buf_for(idx)->size() : pixbuf.size();
    if (dut->write_en && cur_sz >= exp_len && !wft_set) {
        wft ^= 1;
        wft_set = true;
    }
    wr_d3 = wr_d2; wr_d2 = wr_d1; wr_d1 = wr;
    dut->write_req_ack      = wr_d3;   // ack ≈ write_req 延迟 3 拍
    dut->write_finish_toggle = wft;
}

// SIM_FAST：给 fast_sd_stub 投喂扇区字节（本拍寄存器值在下一 posedge 被采样；
// 块寻址：扇区协议层的地址单元就是扇区号，快速档无 SPI 初始化/HCS 协商）
// SIM_FAST：给 fast_sd_stub 投喂扇区字节（本拍寄存器值在下一 posedge 被采样；
// 块寻址：扇区协议层的地址单元就是扇区号，快速档无 SPI 初始化/HCS 协商）
static void feed_fast_sd() {
    if (g_fast_sd && dut->fast_serving && g_img) {
        // 扇区协议层的地址单元就是扇区号（fat32_ro 只发 LBA）——固定块寻址，
        // 与引脚级卡的 HCS 协商无关（快速档没有 SPI 初始化流程）
        uint64_t off = (uint64_t)dut->fast_lba * 512 + dut->fast_idx;
        dut->fast_val  = 1;
        dut->fast_byte = (off < g_img->size()) ? (*g_img)[off] : 0xFF;
    } else {
        dut->fast_val = 0;
    }
}

// ---- 时钟 / 卡模型接线（同 csrc/main.cpp 模式）----
static void watch_audio();
static void sample_read();
static void half_cycle() {
    dut->clk ^= 1;
    dut->eval();
    ctx->timeInc(1);
    dut->SD_MISO = card.eval(dut->SD_nCS, dut->SD_DCLK, dut->SD_MOSI);
    if (dut->clk) {                    // 上升沿后采样
        if (g_verbose) {               // fat32 状态迁移 + 打开文件跟踪
            static int last_fat = -1, last_ps = -1;
            int fat = (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__u_fat__DOT__state;
            int ps  = (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__pstate;
            if (fat != last_fat) {
                std::printf("    [cyc=%lld] FAT %d->%d clu=%u sz=%u ald=%d aldwav=%d\n",
                            (long long)cycles, last_fat, fat,
                            (unsigned)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__u_fat__DOT__file_cluster,
                            (unsigned)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__u_fat__DOT__cur_size,
                            (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__ald_active,
                            (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__ald_wav_idx);
                last_fat = fat;
            }
            if (ps != last_ps) {
                std::printf("    [cyc=%lld] PSTATE %d->%d ald=%d\n",
                            (long long)cycles, last_ps, ps,
                            (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__ald_active);
                last_ps = ps;
            }
            // 提交握手 / 播放态细跟踪（仅后期，避开扫描期噪声）
            if (cycles > 420000000) {
                static int last_cv = 0, last_rq = 0, last_pb = -1;
                auto &R = *dut->rootp;
                int cv = (int)R.board_top__DOT__u_sd_card_bmp_m0__DOT__aud_cmt_valid;
                int tk = (int)R.board_top__DOT__u_sd_card_bmp_m0__DOT__aud_cmt_taken;
                int rq = (int)dut->rd_req;
                int pb = (int)R.board_top__DOT__u_sd_card_bmp_m0__DOT__pb_buf;
                if (cv != last_cv || rq != last_rq || pb != last_pb) {
                    std::printf("    [cyc=%lld] CMT v=%d t=%d req=%d pb=%d ps=%d"
                                " cur=%08x nxt=%08x hc=%d hn=%d bp=%d ph=%d\n",
                                (long long)cycles, cv, tk, rq, pb, ps,
                                (unsigned)R.board_top__DOT__u_sd_card_bmp_m0__DOT__cur_word,
                                (unsigned)R.board_top__DOT__u_sd_card_bmp_m0__DOT__nxt_word,
                                (int)R.board_top__DOT__u_sd_card_bmp_m0__DOT__have_cur,
                                (int)R.board_top__DOT__u_sd_card_bmp_m0__DOT__have_nxt,
                                (int)R.board_top__DOT__u_sd_card_bmp_m0__DOT__byte_pos,
                                (int)R.board_top__DOT__u_sd_card_bmp_m0__DOT__phase);
                }
                last_cv = cv; last_rq = rq; last_pb = pb;
            }
        }
        sample_write();
        sample_read();
        watch_audio();
    }
    feed_fast_sd();   // 投喂值在下一 posedge 被采样
}
static void cycle() { half_cycle(); half_cycle(); cycles++; }
static void reset(int n) {
    dut->rst = 1;
    while (n-- > 0) cycle();
    dut->rst = 0;
    dut->eval();
}

// 按键低有效（PULLUP，按下=0）。去抖 50ms=5M 周期：
//   按住 6M 保证"按下"注册；松开 5.5M 保证"释放"也完成去抖，
//   否则下一次按下去抖器认为还在按下、不产生新沿。
static void press_next() {
    // 配合 boardtest 副本的 1ms 去抖（100k 周期）：按住/松开各留 2 倍余量。
    // 板级 50ms 去抖在 board/ 正式版不变。
    dut->key_next = 0;                       // 按下
    for (int i = 0; i < 200000; i++) cycle();
    dut->key_next = 1;                       // 松开
    for (int i = 0; i < 200000; i++) cycle();
}

static void press_auto() {                   // 自动轮播开关（同去抖参数）
    dut->key_auto = 0;
    for (int i = 0; i < 200000; i++) cycle();
    dut->key_auto = 1;
    for (int i = 0; i < 200000; i++) cycle();
}

static void press_prev() {                   // 上一张（key3，同去抖参数）
    dut->key_prev = 0;
    for (int i = 0; i < 200000; i++) cycle();
    dut->key_prev = 1;
    for (int i = 0; i < 200000; i++) cycle();
}

// ---- 提交检测：display_valid 上升沿（首图）或 disp_buf_idx 翻转（后续）----
static int   prev_dv = 0, prev_disp = 0;
static int   commits = 0;

static void watch_commit() {
    int dv = dut->display_valid;
    int disp = dut->disp_buf_idx;
    bool first = (dv && !prev_dv);
    bool next  = (dv && prev_dv && (disp != prev_disp));
    prev_dv = dv;
    prev_disp = disp;
    if (first || next) commits++;
}

// 诊断：状态码变化 + 像素缓冲
static int last_state = -1;
static void diag() {
    int sc = dut->state_code;
    static uint64_t last_dump = 0;
    if (cycles - last_dump >= 2000000 && last_state == sc) {
        last_dump = cycles;
        std::printf("      [p%llu] st=%d dv=%d lidx=%d fat=%d scanA=%d scanD=%d abd=%d nrp=%d prp=%d lb=%d ld=%d\n",
                    (unsigned long long)cycles, sc, (int)dut->display_valid,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__load_idx,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__u_fat__DOT__state,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__aud_scan_active,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__aud_scan_done_r,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__ald_boot_done,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__next_req_pending,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__prev_req_pending,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__load_busy,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__ld_state);
        return;
    }
    if (sc != last_state) {
        std::printf("      [t=%llu] st=%d dv=%d first=%d lidx=%d fat=%d scanA=%d scanD=%d abd=%d fic=%d nrp=%d prp=%d lb=%d ld=%d\n",
                    (unsigned long long)cycles,
                    sc, (int)dut->display_valid,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__first_bmp_w,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__load_idx,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__u_fat__DOT__state,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__aud_scan_active,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__aud_scan_done_r,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__ald_boot_done,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__first_idx_captured,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__next_req_pending,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__prev_req_pending,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__load_busy,
                    (int)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__ld_state);
        last_state = sc;
    }
}

// pack565：与 sd_card_bmp 打包器一致 {R[7:3],G[7:2],B[7:3]}
static inline uint16_t pack565(uint32_t R, uint32_t G, uint32_t B) {
    return (uint16_t)(((R >> 3) << 11) | ((G >> 2) << 5) | (B >> 3));
}

// pixbuf（RGB565 双像素字，低半字 = 偶数下标像素）与 golden BMP（文件序，BGR）比对
static bool compare_pixbuf(const std::vector<uint8_t> &bm) {
    // 多分辨率信箱模型（2026-10-03，与 sd_card_bmp 发射 FSM 逐条一致）：
    // 发射序列 = 流序 h 行 x 1280 px/行；行内 [x0, x0+w) 为图像像素（BMP 行序
    // 自底向上 = 流序），窗口外黑；写会话长度 = 640*h 字。
    if (bm.size() < 54 || bm[0] != 0x42 || bm[1] != 0x4D) {
        std::printf("      非 BMP\n");
        return false;
    }
    uint32_t w = (uint32_t)bm[18] | ((uint32_t)bm[19] << 8)
               | ((uint32_t)bm[20] << 16) | ((uint32_t)bm[21] << 24);
    uint32_t h = (uint32_t)bm[22] | ((uint32_t)bm[23] << 8)
               | ((uint32_t)bm[24] << 16) | ((uint32_t)bm[25] << 24);
    if (w < 1 || h < 1 || w > 1280 || h > 720) {
        std::printf("      尺寸 %ux%u 超界\n", w, h);
        return false;
    }
    uint32_t x0 = (1280 - w) / 2, x1 = 1280 - w - x0;
    size_t   words = (size_t)640 * h;
    if (pixbuf.size() != words) {
        std::printf("      pixbuf=%zu 需 %zu\n", pixbuf.size(), words);
        return false;
    }
    uint32_t stride = w * 3 + ((4 - (w * 3) % 4) % 4);   // BMP 行 4 字节对齐
    auto px = [&](uint32_t row, uint32_t col) {          // 流行 row = BMP 文件行
        // 解码器按文件序发射（文件行 0 = 显示最底行，BMP 自底向上），vflip 由
        // 真实写引擎补偿；本比对是发射序比对，行号即文件行号，不可再翻转。
        size_t   off = 54 + (size_t)row * stride + (size_t)col * 3;
        return ((uint32_t)bm[off + 2] << 16) | ((uint32_t)bm[off + 1] << 8)
             | (uint32_t)bm[off];
    };
    size_t j = 0;
    for (uint32_t r = 0; r < h; r++) {
        for (uint32_t cc = 0; cc < 1280; cc += 2) {
            uint32_t p0v = (cc >= x0 && cc < x0 + w) ? px(r, cc - x0) : 0;
            uint32_t p1v = (cc + 1 >= x0 && cc + 1 < x0 + w) ? px(r, cc + 1 - x0) : 0;
            uint32_t exp = ((uint32_t)pack565(p1v >> 16, (p1v >> 8) & 0xFF, p1v & 0xFF) << 16)
                         |  (uint32_t)pack565(p0v >> 16, (p0v >> 8) & 0xFF, p0v & 0xFF);
            if (pixbuf[j] != exp) {
                std::printf("      首个失配 字#%zu (行%u 列%u): got=%08x exp=%08x\n",
                            j, r, cc, pixbuf[j], exp);
                for (size_t k2 = j; k2 < j + 8 && k2 < words; k2++)
                    std::printf("      [%zu] got=%08x\n", k2, pixbuf[k2]);
                wr_hist_dump();
                return false;
            }
            j++;
        }
    }
    return true;
}
// ---- WAV golden 解析（规则与 boardtest/vsrc/wav_reader.v 逐条一致）----
// ok = RIFF/WAVE 魔数 && fmt 块存在且体 ≥16 字节 && PCM/1ch/24000Hz/8bit
//      && data 块存在（字节流 = data 体；超出文件尾截断）
// 其余情况 ok=false（RTL 会置 fmt_err 且不应流出样本）
struct WavGold { bool ok; std::vector<uint8_t> bytes; };
static WavGold parse_wav_golden(const std::vector<uint8_t> &d) {
    WavGold r; r.ok = false;
    if (d.size() < 12) return r;
    if (std::memcmp(d.data(), "RIFF", 4) != 0 ||
        std::memcmp(d.data() + 8, "WAVE", 4) != 0) return r;
    auto u16 = [&](size_t o) {
        return (uint32_t)d[o] | ((uint32_t)d[o + 1] << 8);
    };
    auto u32 = [&](size_t o) {
        return (uint32_t)d[o] | ((uint32_t)d[o + 1] << 8)
             | ((uint32_t)d[o + 2] << 16) | ((uint32_t)d[o + 3] << 24);
    };
    size_t p = 12;
    bool seen_fmt = false;
    uint32_t fmt = 0, ch = 0, rate = 0, bits = 0;
    while (p + 8 <= d.size()) {
        uint32_t id = u32(p);
        uint32_t sz = u32(p + 4);
        p += 8;
        if (p + sz > d.size()) sz = (uint32_t)(d.size() - p);   // 截断防御
        if (id == 0x20746D66u) {          // "fmt "
            if (sz < 16) return r;        // 体不足 16 字节：畸形
            fmt = u16(p); ch = u16(p + 2); rate = u32(p + 4); bits = u16(p + 14);
            seen_fmt = true;
        } else if (id == 0x61746164u) {   // "data"
            bool legal = seen_fmt && fmt == 1 && ch == 1 &&
                         rate == 24000 && bits == 8;
            if (!legal) return r;
            r.bytes.assign(d.begin() + p, d.begin() + p + sz);
            r.ok = true;
            return r;
        }
        p += sz;                          // 未知 chunk（LIST/INFO/fact...）按 sz 跳过
    }
    return r;                             // 没有 data 块
}

// ---- 音频扫描捕获：按 aud_item_done 切分各项；同时快照 BUF2 重建内容 ----
static std::vector<uint8_t>  aud_cur;
static std::vector<std::vector<uint8_t>> aud_items;
static std::vector<int>      aud_item_ok;
static std::vector<int>      aud_item_err;
static std::vector<uint32_t> aud_item_dbytes;
static std::vector<std::vector<uint32_t>> aud_bufs;    // 每项完成时的 BUF2 快照
static std::vector<uint32_t> aud_lens;                 // 每项完成时的 write_len
static std::vector<uint8_t>  play_bytes;               // S3/S4：播放输出捕获（u8 还原）
static std::vector<uint8_t>  play_buf_at;              // 每样本当时的 rd_addr_idx（音频乒乓验证）
static std::vector<uint8_t>  play_pair_at;             // 每样本当时的 aud_pair_on（静音验证）
static std::vector<size_t>   play_marks;               // aud_play_done 上升沿时的样本计数（圈标记）
static int                   play_underruns = 0;

// 与 RTL 一致的音频写长度：ceil(bytes/4) 向上取整 256 字
static uint32_t aud_round_len(size_t nbytes) {
    uint32_t words = (uint32_t)((nbytes + 3) / 4);
    return ((words + 255) / 256) * 256;
}

static void watch_audio() {
    if (dut->aud_sval) aud_cur.push_back((uint8_t)dut->aud_smp);
    // aud_valid 是电平（保持到下一 tick），须按 aud_tick 上升沿采样，每样本恰一次
    static int last_tick = 0;
    int tick_rise = dut->aud_tick && !last_tick;
    last_tick = dut->aud_tick;
    if (tick_rise) {
        if (dut->aud_valid) {
            play_bytes.push_back((uint8_t)(((dut->aud_l >> 16) + 128) & 0xFF));
            play_buf_at.push_back((uint8_t)dut->rd_addr_idx);
            play_pair_at.push_back((uint8_t)dut->aud_pair_on);
        }
        if (dut->aud_underrun) play_underruns++;
    }
    // 播放完成现在是脉冲（一圈放完），记录上升沿时的总样本数
    static int last_done = 0;
    if (dut->aud_play_done && !last_done)
        play_marks.push_back(play_bytes.size());
    last_done = dut->aud_play_done;
    if (dut->aud_item_done) {
        aud_items.push_back(aud_cur);
        aud_cur.clear();
        aud_item_ok.push_back(dut->wav_hdr_ok);
        aud_item_err.push_back(dut->wav_fmt_err);
        aud_item_dbytes.push_back(dut->wav_data_bytes);
        aud_bufs.push_back(audbuf);          // 快照（小文件，代价可忽略）
        aud_lens.push_back(dut->write_len);
    }
}

// ---- 读口模型（frame_read_write 读通道）----
// ack/finish 模拟真实 frame_fifo_read 的电平语义：
//   ack    = 请求保持期间恒高（S_ACK 等撤请求），RTL 见 ack 后撤请求即低
//   finish = 整段流末置位保持，至下一请求上升沿清零
// 电平宽到足以跨过双拍同步 + en25 采样（真实硬件即如此；旧 4 拍脉冲版在
// 加入 ack/finish 同步链后会落在 en25 节拍间隙被漏采）。
static int   rd_d1 = 0, rd_d2 = 0, rd_d3 = 0, rd_prev_d3 = 0;
static bool  rd_open = false;
static size_t rd_ptr = 0;
static uint32_t rd_len_l = 0;
static int   rd_idx_l = 0;
static uint32_t rd_data_hold = 0;
static bool  ack_hold = false, fin_hold = false;

static void sample_read() {
    rd_d3 = rd_d2; rd_d2 = rd_d1; rd_d1 = dut->rd_req;
    if (rd_d3 && !rd_prev_d3) {          // 请求上升沿：开新通道
        rd_open   = true;
        rd_ptr    = 0;
        rd_len_l  = dut->rd_len;
        rd_idx_l  = dut->rd_addr_idx;
        ack_hold  = true;
        fin_hold  = false;
    }
    rd_prev_d3 = rd_d3;
    if (!rd_d1) ack_hold = false;        // 请求撤 → ack 撤（真实 S_ACK 行为）
    // rd_en 为 en25 域 4 拍宽脉冲：按上升沿计一次取字
    static int rd_en_prev = 0;
    int rd_en_rise = dut->rd_en && !rd_en_prev;
    rd_en_prev = dut->rd_en;
    if (rd_en_rise && rd_open) {
        const std::vector<uint32_t> *src = (rd_idx_l == 2) ? &audbuf
                                       : (rd_idx_l == 3) ? &audbuf3
                                       : &pixbuf;
        rd_data_hold = (rd_ptr < src->size()) ? (*src)[rd_ptr] : 0;
        if (g_verbose && cycles > 420000000 && rd_ptr < 3)
            std::printf("    [cyc=%llu] RD1ST ptr=%zu idx=%d data=%08x srcsz=%zu\n",
                        (unsigned long long)cycles, rd_ptr, rd_idx_l,
                        rd_data_hold, src->size());
        rd_ptr++;
        if (rd_ptr >= rd_len_l) fin_hold = true;   // 流末：电平保持到下一请求
    }
    dut->rd_req_ack = ack_hold ? 1 : 0;
    dut->rd_finish  = fin_hold ? 1 : 0;
    dut->rd_data    = rd_data_hold;
    // [dbg] 读通道生命周期（FIN/ACK 事件稀疏，直接打）
    static int last_fin = 0, last_ack = 0;
    if (dut->rd_finish && !last_fin && std::getenv("SD_VERBOSE"))
        std::printf("    [cyc=%llu] FIN (rd_ptr=%zu len=%u)\n",
                    (unsigned long long)cycles, rd_ptr, (unsigned)rd_len_l);
    if (dut->rd_req_ack && !last_ack && std::getenv("SD_VERBOSE"))
        std::printf("    [cyc=%llu] ACK (len_latch=%u idx=%d)\n",
                    (unsigned long long)cycles, (unsigned)rd_len_l, rd_idx_l);
    last_fin = dut->rd_finish; last_ack = dut->rd_req_ack;
    static int last_en = 0;
    int en_rise = dut->rd_en && !last_en;
    last_en = dut->rd_en;
    if (en_rise && rd_open && std::getenv("SD_VERBOSE"))
        std::printf("    [cyc=%llu] RD_EN rise rd_ptr=%zu/%u\n",
                    (unsigned long long)cycles, rd_ptr, (unsigned)rd_len_l);
    if (cycles % 20000000 == 0 && std::getenv("SD_VERBOSE"))
        std::printf("    [cyc=%llu] tmr: rd_ptr=%zu len=%u open=%d en=%d req=%d play_n=%zu\n",
                    (unsigned long long)cycles, rd_ptr, (unsigned)rd_len_l,
                    (int)rd_open, (int)dut->rd_en, (int)dut->rd_req,
                    play_bytes.size());
}

int main(int argc, char **argv) {
    ctx->commandArgs(argc, argv);
    const char *img_path = argc > 1 ? argv[1] : "img/card.img";
    if (!card.load(img_path)) {
        std::printf("无法打开 %s\n", img_path);
        return 1;
    }
    card.verbose = std::getenv("SD_VERBOSE") != NULL;

    std::vector<uint8_t> img;
    {
        FILE *f = fopen(img_path, "rb");
        if (!f) return 1;
        fseek(f, 0, SEEK_END);
        long sz = ftell(f);
        fseek(f, 0, SEEK_SET);
        img.resize((size_t)sz);
        size_t rd = fread(img.data(), 1, (size_t)sz, f);
        fclose(f);
        if (rd != (size_t)sz) return 1;
    }
    g_img = &img;
    GoldenFs g = fat32_parse_golden(img);
    std::printf("===== board sd_card_bmp 验证 (%s, golden: %s, %zu 项) =====\n",
                img_path, g.ok ? "OK" : "FAIL", g.bmps.size());

    // 期望播放顺序：首图 + 两次按键
    // tmap 覆盖全部播放列表项——RTL bmp_nxt/prv 跳表按全范围 ext_is_wav 建链，
    // 金模型必须一致（曾只建前 6 项，第 6 项后的 WAV 被当 BMP，期望链错位）
    uint32_t tmap = 0;
    for (int i = 0; i < (int)g.bmps.size(); i++)
        if (g.bmps[i].is_wav) tmap |= (1u << i);
    std::vector<int> order;
    int cur = first_bmp_idx((int)g.bmps.size(), tmap);
    order.push_back(cur);
    cur = next_bmp_idx(cur, (int)g.bmps.size(), tmap);
    order.push_back(cur);
    cur = next_bmp_idx(cur, (int)g.bmps.size(), tmap);
    order.push_back(cur);
    std::printf("  期望顺序: 首图=%d 第二=%d 第三=%d\n", order[0], order[1], order[2]);

    dut->SD_MISO = 1;
    dut->fast_en = g_fast_sd ? 1 : 0;
    if (g_fast_sd)
        std::printf("  [SIM_FAST] SD 直连扇区档：SPI 协议栈不在本次覆盖内\n");
    dut->key_next = 1;    // 释放（低有效按键）
    dut->key_auto = 1;    // 释放
    dut->key_prev = 1;    // 释放
    dut->write_req_ack = 0;
    dut->write_finish_toggle = 0;
    dut->rd_req_ack = 0;
    dut->rd_finish = 0;
    dut->rd_data = 0;
    reset(30);

    // 无图卡：挂载后不应装载（bmp_cnt==0，display_valid 保持 0）
    bool has_bmp = false;
    for (auto &b : g.bmps) if (!b.is_wav) has_bmp = true;
    if (!has_bmp) {
        uint64_t guard = 2000000;
        while (guard--) cycle();
        check(!dut->display_valid, "S0 空卡：无图不装载不挂死");
        std::printf("===== %d passed, %d failed =====\n", pass, fail);
        return fail ? 1 : 0;
    }

    // S1 等待首图提交（SPI 25MHz，整图 ~35M 周期，护栏给足）
    bool wrote = false;
    uint64_t guard = 120000000;
    while (guard-- && commits == 0) { cycle(); watch_commit(); diag(); if (prev_wr) wrote = true; }
    std::printf("      [终态] state=%d disp=%d dv=%d pixbuf=%zu wft_set=%d\n",
                (int)dut->state_code, (int)dut->disp_buf_idx,
                (int)dut->display_valid, pixbuf.size(), (int)wft_set);
    check(commits >= 1, "S1 首图装载并提交（display_valid 上升）");
    check(wrote, "S1b 写口握手发生过（write_req 曾拉高）");
    if (commits >= 1)
        check(compare_pixbuf(g.bmps[order[0]].data),
              "S1c 首图像素与 golden 逐像素比对");

    // SA 音频扫描相位：首图提交后遍历卡内 WAV 项，逐项与 golden 比对
    guard = 200000000;
    while (guard-- && !dut->aud_scan_done) { cycle(); }
    check(dut->aud_scan_done, "SA 音频扫描完成（aud_scan_done）");
    std::vector<int> wav_items;
    for (int i = 0; i < (int)g.bmps.size(); i++)
        if (g.bmps[i].is_wav) wav_items.push_back(i);
    check((int)aud_items.size() == (int)wav_items.size(),
          "SA0 扫描项数与 golden 一致");
    size_t ncmp = aud_items.size() < wav_items.size()
                      ? aud_items.size() : wav_items.size();
    for (size_t k = 0; k < ncmp; k++) {
        WavGold wg = parse_wav_golden(g.bmps[wav_items[k]].data);
        char msg[96];
        if (wg.ok) {
            bool ok = aud_item_ok[k] && !aud_item_err[k]
                      && aud_items[k] == wg.bytes
                      && aud_item_dbytes[k] == wg.bytes.size();
            if (!ok && aud_items[k].size() == wg.bytes.size()) {
                for (size_t i = 0; i < wg.bytes.size(); i++)
                    if (aud_items[k][i] != wg.bytes[i]) {
                        std::printf("      音频项%zu 首个失配 字节#%zu: got=%02x exp=%02x\n",
                                    k, i, aud_items[k][i], wg.bytes[i]);
                        break;
                    }
            }
            std::snprintf(msg, sizeof msg,
                          "SA%zu 项#%d 合法 WAV：PCM %zu 字节逐字节比对 + data_bytes=%u",
                          k, wav_items[k], wg.bytes.size(),
                          (unsigned)wg.bytes.size());
            check(ok, msg);

            // SB：BUF2 重建内容比对（写长度 + 解包字节含 0x80 填充，与打包器约定一致）
            uint32_t exp_len = aud_round_len(wg.bytes.size());
            bool sb_ok = (aud_lens[k] == exp_len) &&
                         (aud_bufs[k].size() == exp_len);
            if (sb_ok) {
                std::vector<uint8_t> exp_bytes = wg.bytes;
                exp_bytes.resize((size_t)exp_len * 4, 0x80);
                for (size_t w = 0; w < exp_len && sb_ok; w++) {
                    uint32_t word = aud_bufs[k][w];
                    for (int b = 0; b < 4; b++) {
                        uint8_t got_b = (uint8_t)(word >> (8 * b));
                        if (got_b != exp_bytes[w * 4 + b]) {
                            std::printf("      BUF2 失配 字%zu 字节%d: got=%02x exp=%02x\n",
                                        w, b, got_b, exp_bytes[w * 4 + b]);
                            sb_ok = false;
                            break;
                        }
                    }
                }
            }
            std::snprintf(msg, sizeof msg,
                          "SB%zu 项#%d BUF2 内容：%u 字 + 0x80 填充逐字节比对（RTL %zu 字, len=%u）",
                          k, wav_items[k], (unsigned)exp_len,
                          aud_bufs[k].size(), (unsigned)aud_lens[k]);
            check(sb_ok, msg);
        } else {
            bool ok = aud_item_err[k] && !aud_item_ok[k]
                      && aud_items[k].empty();
            std::snprintf(msg, sizeof msg,
                          "SA%zu 项#%d 格式拒绝（fmt_err，无样本流出）",
                          k, wav_items[k]);
            check(ok, msg);
        }
    }

    // ---- 配对表（golden 独立计算：同 8 字节主名 + WAV 解析合法 ⇔ RTL pair_valid）----
    std::vector<int> pair_of(g.bmps.size(), -1);
    for (size_t b = 0; b < g.bmps.size(); b++) {
        if (g.bmps[b].is_wav) continue;
        for (size_t w = 0; w < g.bmps.size(); w++) {
            if (!g.bmps[w].is_wav) continue;
            if (g.bmps[b].name != g.bmps[w].name) continue;
            if (!parse_wav_golden(g.bmps[w].data).ok) continue;
            pair_of[b] = (int)w;
        }
    }
    std::printf("      配对表: ");
    {
        auto &pv = dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__pair_valid;
        auto &pw = dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__pair_wav;
        for (int b = 0; b < 5 && b < (int)g.bmps.size(); b++) {
            bool rtl_has = (pv >> b) & 1;
            int rtl_w = rtl_has ? (int)pw[b] : -1;
            int gold_w = pair_of[b];
            std::printf("[#%d→%s%s] ", b,
                        gold_w >= 0 ? g.bmps[gold_w].name.c_str() : "静音",
                        (rtl_has ? (rtl_w == gold_w ? "" : "≠RTL!")
                                 : (gold_w >= 0 ? "≠RTL缺!" : "")));
            if (rtl_has && rtl_w != gold_w)
                std::printf("(RTL=%d) ", rtl_w);
        }
    }
    std::printf("\n");
    for (size_t b = 0; b < g.bmps.size(); b++)
        if (!g.bmps[b].is_wav)
            std::printf("[#%zu→%s] ", b,
                        pair_of[b] >= 0 ? g.bmps[pair_of[b]].name.c_str() : "静音");
    std::printf("\n");

    // ---- 音频验证辅助 ----
    // 验证：新音频缓冲（exp_buf）首次出现 → 下一圈标记，字节流 == 指定 WAV ×2 上采样
    // base_in：外部捕获的圈起点（提交瞬间）。默认在入口自取——注意入口与提交
    // 之间若烧过周期（如按键去抖），base 会落进圈中间，整圈长度少相应样本数。
    auto verify_loop = [&](int wav_idx, int exp_buf, const char *tag,
                           size_t base_in = SIZE_MAX) {
        WavGold wg = parse_wav_golden(g.bmps[wav_idx].data);
        uint32_t exp_len = aud_round_len(wg.bytes.size());
        size_t   exp_n   = (size_t)exp_len * 4 * 2;
        size_t base = (base_in != SIZE_MAX) ? base_in : play_bytes.size();
        size_t idx = SIZE_MAX, mark = SIZE_MAX;
        size_t scan = base;   // 增量游标：idx 未命中时每拍全量重扫是 O(n)×窗口 的性能悬崖
        uint64_t g8 = 50000000ull + (uint64_t)exp_n * 2600;   // ≥1.25× 实时（2083 clk/样本）
        while (g8-- && mark == SIZE_MAX) {
            cycle();
            if (idx == SIZE_MAX) {
                while (scan < play_bytes.size()) {
                    if (play_buf_at[scan] == (uint8_t)exp_buf) { idx = scan; break; }
                    scan++;
                }
            } else {
                for (size_t m = 0; m < play_marks.size(); m++)
                    if (play_marks[m] >= idx) { mark = play_marks[m]; break; }
            }
        }
        char msg[128];
        bool ok = (idx != SIZE_MAX) && (mark != SIZE_MAX) &&
                  (mark - idx == exp_n);
        if (ok) {
            std::vector<uint8_t> exp_bytes = wg.bytes;
            exp_bytes.resize((size_t)exp_len * 4, 0x80);
            for (size_t i = 0; i < exp_n && ok; i++) {
                uint8_t exp = exp_bytes[i / 2];
                if (play_bytes[idx + i] != exp) {
                    std::printf("      播放失配 样本%zu: got=%02x exp=%02x\n",
                                i, play_bytes[idx + i], exp);
                    ok = false;
                }
            }
        }
        if (!ok && idx != SIZE_MAX && mark != SIZE_MAX) {
            std::printf("      圈样本数 %zu 期望 %zu（idx=%zu mark=%zu rd_len=%u pb_len=%u）\n",
                        mark - idx, exp_n, idx, mark, (unsigned)dut->rd_len,
                        (unsigned)dut->rootp->board_top__DOT__u_sd_card_bmp_m0__DOT__pb_len);
            std::printf("      [dbg-bound] base 后前样本 tag:");
            size_t lim = play_bytes.size() < idx + 3 ? play_bytes.size() : idx + 3;
            for (size_t i = (idx >= 6 ? idx - 6 : 0); i < lim; i++)
                std::printf(" %d:%02x", (int)play_buf_at[i], play_bytes[i]);
            std::printf("\n");
            std::printf("      [dbg-bound] audbuf3[0]=%08x [1]=%08x [2]=%08x（期望首字=ada09080=正弦头）\n",
                        audbuf3.size() > 0 ? audbuf3[0] : 0, audbuf3.size() > 1 ? audbuf3[1] : 0,
                        audbuf3.size() > 2 ? audbuf3[2] : 0);
            std::printf("      [dbg-bound] idx-base=%zu mark 前后:", idx - base);
            for (long i = -6; i <= 8; i++) {
                long j = (long)mark + i;
                if (j >= 0 && j < (long)play_bytes.size())
                    std::printf(" %ld:%d/%02x", i, (int)play_buf_at[j], play_bytes[j]);
            }
            std::printf("\n");
        }
        if (!ok && (idx == SIZE_MAX || mark == SIZE_MAX))
            std::printf("      [dbg] idx=%s mark=%s play_marks=%zu play_bytes=%zu"
                        " buf3_cnt=%zu buf2_cnt=%zu disp=%d pair_on=%d rd_req=%d\n",
                        idx == SIZE_MAX ? "MISS" : "ok",
                        mark == SIZE_MAX ? "MISS" : "ok",
                        play_marks.size(), play_bytes.size(),
                        [](const std::vector<uint8_t> &v, uint8_t b) {
                            size_t n = 0; for (auto x : v) if (x == b) n++; return n; }(play_buf_at, 3),
                        [](const std::vector<uint8_t> &v, uint8_t b) {
                            size_t n = 0; for (auto x : v) if (x == b) n++; return n; }(play_buf_at, 2),
                        (int)dut->aud_pair_on, (int)dut->rd_req);
        if (ok && (uint32_t)dut->rd_len != exp_len) {
            std::printf("      rd_len 断言失配: got=%u exp=%u（idx=%zu mark=%zu）\n",
                        (unsigned)dut->rd_len, (unsigned)exp_len, idx, mark);
            ok = false;
        }
        if (ok) ok = ((uint32_t)dut->rd_len == exp_len);
        std::snprintf(msg, sizeof msg, "%s：BUF%d %zu 样本逐字节比对（×2 上采样, len=%u）",
                      tag, exp_buf, exp_n, (unsigned)exp_len);
        check(ok, msg);
    };
    // 验证：静音态（无配对图）——pair_on 恒 0、样本全 0x80、不开读通道
    auto verify_silence = [&](const char *tag) {
        size_t base = play_bytes.size();
        uint64_t g8 = 40000000;
        while (g8--) cycle();
        bool ok = (play_bytes.size() - base >= 15000) && (dut->aud_pair_on == 0)
                  && (dut->rd_req == 0);
        for (size_t i = base; i < play_bytes.size() && ok; i++)
            if (play_pair_at[i] != 0 || play_bytes[i] != 0x80) ok = false;
        char msg[96];
        std::snprintf(msg, sizeof msg, "%s：静音态（pair_on=0、样本全 0x80、无读请求）",
                      tag);
        check(ok, msg);
    };

    // SC boot 播放：扫描完成后 boot ald 把首图配对 WAV 装入 BUF3 提交。
    // 首图提交→扫描期间是静音（配对表未建），样本 0 起有静音段，按 buf 首次出现定位。
    int exp_aud_buf = 3;              // boot 装载缓冲（aud_disp_buf 复位 2 的对侧）
    if (pair_of[order[0]] >= 0) {
        verify_loop(pair_of[order[0]], exp_aud_buf, "SC 首图配对播放（BUF3 循环）");
        exp_aud_buf = (exp_aud_buf == 3) ? 2 : 3;
    } else {
        verify_silence("SC 首图无配对");
    }

    // S2 按键 → 第二张（配对 WAV 重读入对侧音频缓冲，就绪后与图原子提交）
    press_next();
    guard = 200000000;                 // 图 + 音频两段装载
    while (guard-- && commits < 2) { cycle(); watch_commit(); diag(); }
    check(commits >= 2, "S2 按键切换 → 第二张提交");
    if (commits >= 2)
        check(compare_pixbuf(g.bmps[order[1]].data),
              "S2b 第二图像素与 golden 比对");
    if (commits >= 2 && pair_of[order[1]] >= 0) {
        verify_loop(pair_of[order[1]], exp_aud_buf, "SD 随图切换音频（原子提交）");
        exp_aud_buf = (exp_aud_buf == 3) ? 2 : 3;
    } else if (commits >= 2) {
        verify_silence("SD 第二图无配对");
    }

    // S3 按键 → 第三张
    press_next();
    guard = 200000000;
    while (guard-- && commits < 3) { cycle(); watch_commit(); diag(); }
    check(commits >= 3, "S3 按键切换 → 第三张提交");
    if (commits >= 3)
        check(compare_pixbuf(g.bmps[order[2]].data),
              "S3b 第三图像素与 golden 比对");
    if (commits >= 3 && pair_of[order[2]] >= 0) {
        verify_loop(pair_of[order[2]], exp_aud_buf, "SE 随图切换音频（原子提交）");
        exp_aud_buf = (exp_aud_buf == 3) ? 2 : 3;
    } else if (commits >= 3) {
        verify_silence("SE 第三图无配对");
    }

    // S4 第四张
    int exp4 = next_bmp_idx(order[2], (int)g.bmps.size(), tmap);
    press_next();
    guard = 200000000;
    while (guard-- && commits < 4) { cycle(); watch_commit(); diag(); }
    check(commits >= 4, "S4 第四张提交");
    if (commits >= 4)
        check(compare_pixbuf(g.bmps[exp4].data),
              "S4b 第四图像素与 golden 比对");
    if (commits >= 4 && pair_of[exp4] >= 0) {
        verify_loop(pair_of[exp4], exp_aud_buf, "SF 随图切换音频（原子提交）");
        exp_aud_buf = (exp_aud_buf == 3) ? 2 : 3;
    } else if (commits >= 4) {
        verify_silence("SF 第四图无配对");
    }

    check(play_underruns == 0, "SCb 播放零欠采样（underrun 应恒 0）");

    // S5/S6：继续按。自适应——按到的项是合法图则期望提交+比对；
    //         坏图 / WAV（含越出 type_map 6 项的 WAV，按图片处理→img_err 跳过）则期望不提交。
    // 返回本次是否提交（供调用方续用）。prev_dir=true 走上一张键（S10 用）。
    // ⚠ 2026-10-04 教训：S10 首版忘传方向，prev 环遍历实际全按了 next——
    //   4 个"像素失配"全是测试自身假失败（模型按 prv 链出期望、RTL 按 nxt 执行）。
    auto press_adaptive = [&](const char *tag, int &exp, int &c_after,
                              bool prev_dir = false) -> bool {
        bool bad = !loadable_bmp(g.bmps[exp].data);
        if (bad)
            std::printf("      卡自检：索引 %d 非合法图，验证跳过路径\n", exp);
        int c_before = commits;
        if (prev_dir) press_prev(); else press_next();
        uint64_t g2 = bad ? 3000000u : 1500000000u;  // 坏图头校验快；合法图整帧+配对音频两段装载：全保真最坏 ~1.4G（720p 图+0.7MB WAV+SPI），220M 会把慢装载误判成超时（2026-10-04 S10 实测）
        while (g2-- && commits == c_before) { cycle(); watch_commit(); diag(); }
        if (bad) {
            check(commits == c_before, tag);          // 跳过：不应提交
            c_after = c_before;
            return false;
        } else {
            check(commits == c_before + 1, tag);      // 合法图：应提交
            if (commits == c_before + 1) {
                check(compare_pixbuf(g.bmps[exp].data), "      像素与 golden 比对");
                // 配对图的 ald 音频占用对侧缓冲并切换播放——与显式 verify_loop
                // 的调用方一样翻转 exp_aud_buf，否则后续 S7c/S8c 期望 buffer 错位
                if (pair_of[exp] >= 0)
                    exp_aud_buf = (exp_aud_buf == 3) ? 2 : 3;
            }
            c_after = commits;
            return true;
        }
    };

    // 光标语义（RTL）：img_idx = 最近一次尝试的项（提交与失败都写 img_idx<=load_idx），
    // S5/S6 跳过坏图后光标停在坏图上——S7/S8 的期望链必须基于光标而非最后提交的图。
    int cursor = exp4;                     // S4 已提交
    int exp5 = next_bmp_idx(exp4, (int)g.bmps.size(), tmap);
    int c_after5;
    bool committed5 = press_adaptive("S5 下一项处理正确（合法图提交 / 坏图跳过）",
                                     exp5, c_after5);
    (void)committed5;
    cursor = exp5;

    int exp6 = next_bmp_idx(exp5, (int)g.bmps.size(), tmap);
    int c_after6;
    bool committed6 = press_adaptive("S6 下一项处理正确（合法图提交 / 坏图/WAV 跳过）",
                                     exp6, c_after6);
    (void)committed6;
    cursor = exp6;

    // ---- S7 自动轮播（仅 SIM_AUTO=1 的卡，即 card.img）：开 → 1s 自动切一张 → 关 ----
    // 演示要用 key_auto，RTL 里这是唯一没被常规用例走到 path。
    if (getenv("SIM_AUTO")) {
        // 期望链要复刻 RTL 行为：坏图（bmp_dec 拒）不提交且自动下一拍重试，
        // 跨多个 1s 周期推进到下一个合法图（本卡 ZBADSIZE 即此例）。
        int exp7 = next_bmp_idx(cursor, (int)g.bmps.size(), tmap);
        while (exp7 != cursor && !loadable_bmp(g.bmps[exp7].data))
            exp7 = next_bmp_idx(exp7, (int)g.bmps.size(), tmap);
        press_auto();                      // 开
        int c_base = commits;
        uint64_t g3 = 400000000u;          // 坏图拒载重试要跨 2 个 1s 周期 + 装载
        while (g3-- && commits == c_base) { cycle(); watch_commit(); diag(); }
        check(commits == c_base + 1, "S7 自动轮播：开启后自动提交下一张");
        if (commits == c_base + 1) {
            // 提交瞬间先捕获音频圈起点，再烧按键去抖周期；
            // 否则 base 落进圈中间，整圈样本数会少 400000/2084=192 个。
            size_t s7_base = play_bytes.size();
            // 提交检出后 2ms 内关掉（下一拍要再等 1s，不可能有在途装载），
            // 后续像素/音频校验期间自动轮播已停，不会有中途切缓冲干扰。
            press_auto();                  // 关
            check(compare_pixbuf(g.bmps[exp7].data), "S7b 自动轮播图像素与 golden 比对");
            if (pair_of[exp7] >= 0) {
                verify_loop(pair_of[exp7], exp_aud_buf, "S7c 自动轮播音频（原子提交）",
                            s7_base);
                exp_aud_buf = (exp_aud_buf == 3) ? 2 : 3;
            }
            cursor = exp7;
            c_base = commits;
            uint64_t g4 = 130000000u;      // >1s 自动周期：不应再有新提交
            while (g4--) { cycle(); watch_commit(); diag(); }
            check(commits == c_base, "S7d 自动轮播关闭后停止切换");
        }
    }

    // ---- S8 上一张（key3）：从光标回退，坏图继续回退直到提交（≤8 步防兜圈）----
    // 光标语义：失败也写 img_idx，故从 cursor 回退（非最后提交的图）。
    // 坏图不提交且光标停在坏图上，下一次 prev 继续回退——与 next 镜像。
    {
        int exp8 = prv_bmp_idx(cursor, (int)g.bmps.size(), tmap);
        for (int step = 0; step < 8; step++) {
            bool bad8 = !loadable_bmp(g.bmps[exp8].data);
            if (bad8)
                std::printf("      卡自检：索引 %d 非合法图，上一张继续回退\n", exp8);
            int c_before = commits;
            press_prev();
            uint64_t g8 = bad8 ? 3000000u : 1500000000u;
            while (g8-- && commits == c_before) { cycle(); watch_commit(); diag(); }
            if (bad8) {
                check(commits == c_before, "S8 上一张：坏图跳过不提交");
                if (commits != c_before) break;
                exp8 = prv_bmp_idx(exp8, (int)g.bmps.size(), tmap);
            } else {
                check(commits == c_before + 1, "S8 上一张提交");
                if (commits == c_before + 1) {
                    check(compare_pixbuf(g.bmps[exp8].data),
                          "S8b 上一图像素与 golden 比对");
                    if (pair_of[exp8] >= 0) {
                        verify_loop(pair_of[exp8], exp_aud_buf, "S8c 上一张音频（原子提交）");
                        exp_aud_buf = (exp_aud_buf == 3) ? 2 : 3;
                    } else {
                        verify_silence("S8d 上一张无配对");
                    }
                    cursor = exp8;   // 写回光标：S9/S10 全环遍历从这里出发
                }
                break;
            }
        }
    }

    // ---- S9/S10 全环遍历（2026-10-04 板级"环端失灵"盲区补洞）----
    // 此前用例从 boot 图最多 next×2 + prev 回退到首个合法图——多图卡的
    // 回绕边（尾图 next→首图 / 首图 prev→尾图）从未被踩到。这里双向各绕
    // 整环一圈回到起点，每步自适应期望（合法图提交比对 / 非法项跳过）。
    {
        int start9 = cursor;
        int cur9 = cursor;
        for (int k = 0; k <= (int)g.bmps.size(); k++) {
            int target = next_bmp_idx(cur9, (int)g.bmps.size(), tmap);
            int c_after;
            press_adaptive("S9 下一张环步进（合法图提交 / 非法项跳过）",
                           target, c_after);
            cur9 = target;
            if (target == start9) break;
        }
        check(cur9 == start9, "S9 下一张绕整环回到起点（尾→头回绕边）");
        cur9 = cursor;
        for (int k = 0; k <= (int)g.bmps.size(); k++) {
            int target = prv_bmp_idx(cur9, (int)g.bmps.size(), tmap);
            int c_after;
            press_adaptive("S10 上一张环步进（合法图提交 / 非法项跳过）",
                           target, c_after, true);
            cur9 = target;
            if (target == start9) break;
        }
        check(cur9 == start9, "S10 上一张绕整环回到起点（首→尾回绕边）");

        // ---- S11 播放列表转储（'L'）：直接观测 RTL 跳表/配对表/光标 ----
        // 板级排障主通道（串口/以太网发 'L' 即可拿到同一份数据）。期望表与
        // fat32_ro 建表算法逐步同构：BMP 链 + 收口回填（prv[首]=末，nxt[末]=首）。
        {
            int n_items = (int)g.bmps.size();
            // 模型侧重构 nxt/prv 表（与 RTL 逐拍同构）
            int em_nxt[32] = {0}, em_prv[32] = {0};
            {
                int last = 0, first = 0;
                bool seen = false;
                for (int i = 0; i < n_items; i++) {
                    if (!g.bmps[i].is_wav) {
                        em_prv[i] = last;
                        if (seen) em_nxt[last] = i; else first = i;
                        last = i; seen = true;
                    }
                }
                if (seen) { em_nxt[last] = first; em_prv[first] = last; }
            }
            int exp_first = -1;
            for (int i = 0; i < n_items && exp_first < 0; i++)
                if (!g.bmps[i].is_wav) exp_first = i;

            int ent_isbmp[32], ent_pv[32], ent_pw[32], ent_nx[32], ent_pr[32];
            int n_ent = 0, sum_fc = -1, sum_bc = -1, sum_wc = -1, sum_fb = -1, sum_ii = -1;
            dut->pl_dump_start = 1; cycle(); dut->pl_dump_start = 0;
            uint64_t g11 = 40000000u;   // (项数+2)×40k 间隔的 10 倍裕量
            while (g11-- && sum_fc < 0) {
                cycle(); watch_commit(); diag();
                if (dut->pl_pkt_val) {
                    uint64_t pkt = (uint64_t)dut->pl_pkt;
                    // uart_link 线序 = LSB 字节先行：按线序重组再大端解码（与控制台一致）
                    pkt = ((pkt & 0x00000000000000FFULL) << 56) |
                          ((pkt & 0x000000000000FF00ULL) << 40) |
                          ((pkt & 0x0000000000FF0000ULL) << 24) |
                          ((pkt & 0x00000000FF000000ULL) << 8)  |
                          ((pkt & 0x000000FF00000000ULL) >> 8)  |
                          ((pkt & 0x0000FF0000000000ULL) >> 24) |
                          ((pkt & 0x00FF000000000000ULL) >> 40) |
                          ((pkt & 0xFF00000000000000ULL) >> 56);
                    int tag = (int)(pkt >> 62) & 0x3;
                    if (tag == 1 && n_ent < 32) {
                        int idx = (int)(pkt >> 57) & 0x1F;
                        ent_isbmp[idx] = (int)(pkt >> 56) & 1;
                        ent_pv[idx]    = (int)(pkt >> 55) & 1;
                        ent_pw[idx]    = (int)(pkt >> 49) & 0x3F;
                        ent_nx[idx]    = (int)(pkt >> 43) & 0x3F;
                        ent_pr[idx]    = (int)(pkt >> 37) & 0x3F;
                        n_ent++;
                    } else if (tag == 2) {
                        // {2'b10, file_cnt[61:56], bmp_cnt[55:50], wav_cnt[49:44],
                        //  first_bmp[43:38], img_idx[37:33], first_idx_r[32:28],
                        //  load_busy[27], scan_active[26], ld_state[25:23], 23'b0}
                        sum_fc = (int)(pkt >> 56) & 0x3F;
                        sum_bc = (int)(pkt >> 50) & 0x3F;
                        sum_wc = (int)(pkt >> 44) & 0x3F;
                        sum_fb = (int)(pkt >> 38) & 0x3F;
                        sum_ii = (int)(pkt >> 33) & 0x1F;
                    }
                }
            }
            check(sum_fc >= 0, "S11 转储收到收口包");
            if (sum_fc >= 0) {
                check(n_ent == n_items, "S11 条目包数=播放列表项数");
                check(sum_fc == n_items, "S11 file_cnt 与 golden 一致");
                int exp_bc = 0, exp_wc = 0;
                for (int i = 0; i < n_items; i++)
                    (g.bmps[i].is_wav ? exp_wc : exp_bc)++;
                check(sum_bc == exp_bc && sum_wc == exp_wc, "S11 bmp/wav 计数一致");
                check(sum_fb == exp_first, "S11 first_bmp 一致");
                check(sum_ii == start9, "S11 光标=环遍历起点");
                for (int i = 0; i < n_items; i++) {
                    if (i >= n_ent) break;
                    check(ent_isbmp[i] == !g.bmps[i].is_wav,
                          "S11 项类型与 golden 一致");
                    if (pair_of[i] >= 0) {
                        check(ent_pv[i] == 1 && ent_pw[i] == pair_of[i],
                              "S11 配对表与 golden 一致");
                    }
                    if (!g.bmps[i].is_wav) {
                        check(ent_nx[i] == em_nxt[i] && ent_pr[i] == em_prv[i],
                              "S11 跳表与 golden 建表一致");
                    }
                }
            }
        }
    }

    {
        auto el = std::chrono::steady_clock::now() - g_t0;
        double sec = std::chrono::duration<double>(el).count();
        std::printf("===== %d passed, %d failed | %.1f Mcyc, %.1fs, %.1f Mcyc/s =====\n",
                    pass, fail, cycles / 1e6, sec, sec > 0 ? cycles / 1e6 / sec : 0.0);
    }
    return fail ? 1 : 0;
}