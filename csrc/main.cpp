// csrc/main.cpp — 系统级仿真入口（图像轮播 golden）
//
// 数据流：卡 ─ sd_spi ← fat32_ro → bmp_dec → mem_sim(乒乓) → vga_ctrl → VGA。
// 音频链路（24k/8b/mono → SDRAM）在 boardtest/vsrc 线开发，本顶层保持图像专用。
//
// 用例（按卡内容自适应）：
//   S1  挂载 + 文件数/分类与 golden 一致
//   S2-S5  逐张：提交 + 像素与 golden 比对（无配对/坏图场景由卡内容驱动）
//   S7  存储层无溢出/下溢/长度错
//   S8  死卡 → sd_spi 重试耗尽 → o_sd_err
//
// make sim CARD=img/card.img ...
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "verilated.h"
#include "Vtop.h"
#include "sd_card_model.h"
#include "fat32_golden.h"

static const int SCREEN_W = 640;
static const int SCREEN_H = 480;
static const size_t N_PIXELS = (size_t)SCREEN_W * SCREEN_H;

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

// 装载提交等待：等 commits 计数增加
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
    std::printf("===== system sim (图像轮播): %s golden=%s %zu 项 =====\n",
                img_path, g_cur.ok ? "OK" : "FAIL", g_cur.bmps.size());

    uint32_t tmap = 0;
    int wav_cnt = 0;
    for (int i = 0; i < 6 && i < (int)g_cur.bmps.size(); i++)
        if (g_cur.bmps[i].is_wav) tmap |= (1u << i);
    int cnt = (int)g_cur.bmps.size();
    for (int i = 0; i < cnt; i++)
        if (g_cur.bmps[i].is_wav) wav_cnt++;

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
        uint64_t d = 80000000;     // 80M 周期：覆盖挂载→首图装载→提交
        while (d--) {
            cycle();
            int segv = (int)dut->seg;
            if (segv != last_seg || d % 500000 == 0) {
                std::printf("[t=%llu] seg=%d mnt=%d file=%d imgfat=%d "
                            "ld=%d disp=%d\n",
                            (unsigned long long)(80000000 - d),
                            segv, (int)dut->o_mounted, (int)dut->o_file_cnt,
                            (int)dut->o_img_fat_state, (int)dut->o_ld_state,
                            (int)dut->o_disp_idx);
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
          dut->o_wav_cnt == (uint32_t)wav_cnt,
          "S1b 播放列表分类（BMP/WAV 计数与 golden 一致）");

    // ---- 逐张验证：提交 + 像素（空卡无图可放，整段跳过）----
    bool first = true;
    for (int step = 0; step < 4 && cnt > 0; step++) {
        if (!first) press_button();
        first = false;

        int expect_img = order[step];

        char msg[96];
        std::snprintf(msg, sizeof msg, "S%d 图片#%d 提交", 2 + step, expect_img);
        guard = 300000000;   // 读图 ~1.4s @ 100M
        check(wait_commit(guard), msg);

        std::vector<uint32_t> frame;
        bool cap = capture_frame(frame);
        std::snprintf(msg, sizeof msg, "S%d 图片#%d 像素与 golden 比对", 2 + step, expect_img);
        check(cap && compare_frame(frame, g_cur.bmps[expect_img].data), msg);
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
