// csrc/main.cpp — 系统级仿真入口（3a 音画同步）
//
// 数据流：卡 ─sd_spi←sd_arbiter→ 图/音两个 fat32_ro → bmp_dec / wav_reader →
//         mem_sim(乒乓) → vga_ctrl → VGA；audio_path(乒乓FIFO) → 48kHz 音频输出。
//
// 用例（按卡内容自适应）：
//   S1  挂载 + 文件数/分类与 golden 一致
//   S2  首图：提交(双就绪) + 像素比对 + 配对音频(同名 WAV)从头逐样本比对 + 无下溢
//   S3  按键→第二张：同上（若第二张有配对 WAV）
//   S4  按键→第三张（无配对）：提交 + 像素比对 + 静音（无音频输出）
//   S5  配对 WAV 非法 → 静音不阻塞提交
//   S6  全程无音频下溢
//   S7  存储层无溢出/下溢/长度错
//   S8  死卡 → sd_spi 重试耗尽 → o_sd_err
//
// make sim CARD=img/card.img ...
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <map>
#include "verilated.h"
#include "Vtop.h"
#include "sd_card_model.h"
#include "fat32_golden.h"

static const int SCREEN_W = 640;
static const int SCREEN_H = 480;
static const size_t N_PIXELS = (size_t)SCREEN_W * SCREEN_H;
static const size_t N_AUD_SAMPLES = 4000;   // 每个音频比对取的样本数（~83ms）

static VerilatedContext *ctx = new VerilatedContext;
static Vtop *dut = new Vtop;
static SdCardModel card;
static GoldenFs g_cur;

static int pass = 0, fail = 0;
static void check(bool ok, const char *what) {
    std::printf("%s: %s\n", ok ? "  PASS" : ">>FAIL", what);
    if (ok) pass++; else fail++;
}

// ---- 与 RTL 一致的轮播图片选择（跳过 WAV 项）----
static int first_img_of(int cnt, uint32_t tmap) {
    for (int k = 0; k < 6 && k < cnt; k++)
        if (!((tmap >> k) & 1u)) return k;
    return 0;
}
static int next_img_of(int cur, int cnt, uint32_t tmap) {
    int cand = cur;
    for (int k = 0; k < 6; k++) {
        cand = (cand + 1 >= cnt) ? 0 : cand + 1;
        bool is_wav = (cand < 6) && ((tmap >> cand) & 1u);
        if (!is_wav) return cand;
    }
    return cur;
}

// 配对：主名 → WAV 播放列表索引
static std::map<uint64_t, int> wav_by_name;
static int pair_of(int idx) {
    auto it = wav_by_name.find(g_cur.bmps[idx].name64());
    return it == wav_by_name.end() ? -1 : it->second;
}

static bool watch_commit();
static void half_cycle() {
    dut->clk ^= 1;
    dut->eval();
    ctx->timeInc(1);
    dut->spi_miso = card.eval(dut->spi_cs_n, dut->spi_sclk, dut->spi_mosi);
    watch_commit();
}
static void cycle() { half_cycle(); half_cycle(); }
static void reset(int n) {
    dut->rst_n = 0;
    while (n-- > 0) cycle();
    dut->rst_n = 1;
    dut->eval();
}
static void press_button() {
    dut->btn_next = 1;
    for (int i = 0; i < 20; i++) cycle();
    dut->btn_next = 0;
    for (int i = 0; i < 20; i++) cycle();
}

// ---- 提交检测：o_disp_valid 上升（首图）或 o_disp_idx 翻转（后续）----
static int prev_dv = 0, prev_disp = 0;
static int commits = 0;
static bool watch_commit() {
    int dv = dut->o_disp_valid;
    int disp = (int)dut->o_disp_idx;
    bool c = (dv && !prev_dv) || (dv && prev_dv && disp != prev_disp);
    prev_dv = dv;
    prev_disp = disp;
    if (c) commits++;
    return c;
}

// 捕一帧（VGA 输出，对齐 vsync）
static bool capture_frame(std::vector<uint32_t> &frame) {
    frame.assign(N_PIXELS, 0);
    int prev_vs = dut->vga_vsync;
    uint64_t guard = (uint64_t)800 * 525 * 4 * 3;
    bool synced = false;
    while (guard--) {
        cycle();
        if (prev_vs == 1 && dut->vga_vsync == 0) { synced = true; break; }
        prev_vs = dut->vga_vsync;
    }
    if (!synced) return false;
    size_t idx = 0;
    uint64_t limit = (uint64_t)800 * 525 * 4 + 8000;
    while (idx < N_PIXELS && limit--) {
        bool ce = dut->o_pix_ce;
        cycle();
        if (ce && dut->vga_blank_n) {
            frame[idx++] = ((uint32_t)dut->vga_r << 16)
                         | ((uint32_t)dut->vga_g << 8)
                         | (uint32_t)dut->vga_b;
        }
    }
    return idx == N_PIXELS;
}

static bool compare_frame(const std::vector<uint32_t> &frame,
                          const std::vector<uint8_t> &bm) {
    if (bm.size() < 54 + 640 * 480 * 3) return false;
    for (int y = 0; y < SCREEN_H; y++) {
        for (int x = 0; x < SCREEN_W; x++) {
            size_t off = 54 + ((size_t)(479 - y) * 640 + x) * 3;
            uint32_t exp = ((uint32_t)bm[off + 2] << 16)
                         | ((uint32_t)bm[off + 1] << 8)
                         | (uint32_t)bm[off];
            if (frame[(size_t)y * SCREEN_W + x] != exp) {
                std::printf("      首个失配 (%d,%d): got=%06x expect=%06x\n",
                            x, y, frame[(size_t)y * SCREEN_W + x], exp);
                return false;
            }
        }
    }
    return true;
}

// 收集 48kHz 音频输出样本（从"下一次有效样本"开始，即新音频的第 0 帧）
// 顺带记录收集期间是否出现播放 FIFO 下溢（有音频时应无下溢）
static bool saw_underrun = false;
static size_t collect_audio(std::vector<int16_t> &l, std::vector<int16_t> &r,
                            size_t want, uint64_t guard) {
    l.clear(); r.clear();
    saw_underrun = false;
    while (l.size() < want && guard--) {
        cycle();
        if (dut->o_aud_underrun) saw_underrun = true;
        if (dut->o_audio_valid) {
            l.push_back((int16_t)dut->o_audio_left);
            r.push_back((int16_t)dut->o_audio_right);
        }
    }
    return l.size();
}

// 装载提交（双就绪）等待：等 commits 计数增加
static bool wait_commit(uint64_t guard) {
    int before = commits;
    while (guard-- && commits == before) cycle();
    return commits > before;
}

int main(int argc, char **argv) {
    ctx->commandArgs(argc, argv);
    const char *img_path = argc > 1 ? argv[1] : "img/card.img";
    if (!card.load(img_path)) {
        std::printf("无法打开 %s（先跑 ./scripts/gen_card.sh）\n", img_path);
        return 1;
    }
    std::vector<uint8_t> img;
    {
        FILE *f = fopen(img_path, "rb");
        if (!f) return 1;
        fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
        img.resize((size_t)sz);
        size_t rd = fread(img.data(), 1, (size_t)sz, f);
        fclose(f);
        if (rd != (size_t)sz) return 1;
    }
    g_cur = fat32_parse_golden(img);
    std::printf("===== system sim (3a 音画同步): %s golden=%s %zu 项 =====\n",
                img_path, g_cur.ok ? "OK" : "FAIL", g_cur.bmps.size());

    uint32_t tmap = 0;
    for (int i = 0; i < 6 && i < (int)g_cur.bmps.size(); i++)
        if (g_cur.bmps[i].is_wav) tmap |= (1u << i);
    int cnt = (int)g_cur.bmps.size();
    for (int i = 0; i < cnt; i++)
        if (g_cur.bmps[i].is_wav) wav_by_name[g_cur.bmps[i].name64()] = i;

    // 期望播放顺序（首图 + 后续按键）
    std::vector<int> order;
    {
        int cur = first_img_of(cnt, tmap);
        order.push_back(cur);
        for (int k = 0; k < 3; k++) {
            cur = next_img_of(cur, cnt, tmap);
            order.push_back(cur);
        }
    }
    std::printf("  期望顺序: %d→%d→%d→%d\n", order[0], order[1], order[2], order[3]);

    dut->spi_miso = 1;
    dut->btn_next = 0;
    dut->i_tb_file_req = 0;
    dut->i_tb_file_idx = 0;
    reset(10);

    // ---- 诊断：DIAG=1 时有界跑并打印状态（定位挂载/提交卡点）----
    if (std::getenv("DIAG")) {
        int last_seg = -1;
        uint64_t d = 80000000;     // 80M 周期：覆盖挂载→首图装载→提交→音频播放到 audf 水位停流
        while (d--) {
            cycle();
            int segv = (int)dut->seg;
            if (segv != last_seg || d % 500000 == 0) {
                std::printf("[t=%llu] seg=%d mnt=%d file=%d arb=%d/%d/%d "
                            "img=%d aud=%d ldcnt=%d ld=%d pair_v=%d pair_i=%d "
                            "audf=%d disp=%d\n",
                            (unsigned long long)(80000000 - d),
                            segv, (int)dut->o_mounted, (int)dut->o_file_cnt,
                            (int)dut->o_arb_state, (int)dut->o_arb_owner,
                            (int)dut->o_arb_pending,
                            (int)dut->o_img_fat_state, (int)dut->o_aud_fat_state,
                            (int)dut->o_aud_file_cnt, (int)dut->o_ld_state,
                            (int)dut->o_aud_pair_valid, (int)dut->o_aud_idx,
                            (int)dut->o_aud_prim_fill, (int)dut->o_disp_idx);
                last_seg = segv;
            }
        }
        std::printf("===== DIAG done =====\n");
        return 0;
    }

    // ---- S1 挂载 + 文件数 ----
    uint64_t guard = 10000000;
    while (!dut->o_mounted && guard--) half_cycle();
    check(guard > 0 && dut->o_mounted && dut->o_file_cnt == (uint32_t)cnt,
          "S1 挂载完成，文件数与 golden 一致");
    check(dut->o_bmp_cnt + dut->o_wav_cnt == (uint32_t)cnt &&
          dut->o_bmp_cnt == (uint32_t)(cnt - (int)wav_by_name.size()),
          "S1b 播放列表分类（BMP/WAV 计数与 golden 一致）");

    // ---- 逐张验证：提交 + 像素 + 音频（空卡无图可放，整段跳过）----
    bool first = true;
    for (int step = 0; step < 4 && cnt > 0; step++) {
        if (!first) press_button();
        first = false;

        int expect_img = order[step];
        int expect_aud = pair_of(expect_img);   // -1 = 无配对

        char msg[96];
        std::snprintf(msg, sizeof msg, "S%d 图片#%d 双就绪提交", 2 + step, expect_img);
        guard = 300000000;   // 下一张装载需等当前 WAV 流完（最长 ~1s）+ 读图 ~1.4s
        check(wait_commit(guard), msg);

        // 配对信息与 golden 一致
        std::snprintf(msg, sizeof msg, "S%d 配对 WAV 索引正确(%s)", 2 + step,
                      expect_aud >= 0 ? "有" : "无");
        check((int)dut->o_aud_pair_valid == (expect_aud >= 0) &&
              (!(expect_aud >= 0) || (int)dut->o_aud_idx == expect_aud), msg);

        // 音频（有配对时）：提交后立刻收——装载期 FIFO 仅 ~2k 样本（~40ms），
        // 若先采帧（~2M 周期 ≈ 同量级）会把 FIFO 放干导致下溢/样本丢失
        if (expect_aud >= 0) {
            GoldenWav gw = wav_parse_golden(g_cur.bmps[expect_aud].data);
            check(gw.ok, "      配对 WAV 应可解析");
            std::vector<int16_t> l, r;
            size_t want = gw.left.size() < N_AUD_SAMPLES ? gw.left.size() : N_AUD_SAMPLES;
            size_t got = collect_audio(l, r, want, 200000000ULL);
            bool match = (got == want);
            for (size_t i = 0; i < got && match; i++)
                if (l[i] != gw.left[i] || r[i] != gw.right[i]) {
                    std::printf("      音频首个失配 样本#%zu: L=%d R=%d expect L=%d R=%d\n",
                                i, l[i], r[i], gw.left[i], gw.right[i]);
                    match = false;
                }
            std::printf("      音频 %zu/%zu 帧 与 golden 逐样本比对（从头）\n", got, want);
            std::snprintf(msg, sizeof msg, "S%d 配对音频从头逐样本比对", 2 + step);
            check(match, msg);
            std::snprintf(msg, sizeof msg, "S%d 音频播放期间无下溢", 2 + step);
            check(!saw_underrun, msg);
        }

        // 像素（帧缓冲持久，音频收完再采帧不影响）
        std::vector<uint32_t> frame;
        bool cap = capture_frame(frame);
        std::snprintf(msg, sizeof msg, "S%d 图片#%d 像素与 golden 比对", 2 + step, expect_img);
        check(cap && compare_frame(frame, g_cur.bmps[expect_img].data), msg);

        if (expect_aud < 0) {
            // 无配对：应静音——收集一段，确认没有音频样本输出
            std::vector<int16_t> l, r;
            size_t got = collect_audio(l, r, 64, 1000000ULL);
            std::snprintf(msg, sizeof msg, "S%d 无配对图静音（收到 %zu 样本，应为 0）", 2 + step, got);
            check(got == 0, msg);
        }
    }

    // ---- S7 存储层诊断 ----
    check(!dut->o_mem_wr_ovf && !dut->o_mem_rd_und && !dut->o_mem_len_err,
          "S7 存储层无溢出/下溢/长度错");

    // ---- S8 死卡 → sd_spi 初始化重试耗尽 ----
    card.dead_card = true;
    reset(10);
    bool got_err = false;
    guard = 5000000;
    while (guard--) {
        half_cycle();
        if (dut->o_sd_err) got_err = true;
        if (dut->seg == 16) break;
    }
    check(got_err && dut->seg == 16, "S8 死卡 -> o_sd_err 卡死");

    std::printf("===== %d passed, %d failed =====\n", pass, fail);
    std::printf("card: cmds=%llu sectors_read=%llu\n",
                (unsigned long long)card.cmds_seen,
                (unsigned long long)card.sectors_read);
    return fail ? 1 : 0;
}
