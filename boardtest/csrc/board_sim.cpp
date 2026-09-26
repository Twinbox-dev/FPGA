// board_sim.cpp — 板级 sd_card_bmp（新 FAT32 版）的 Verilator 验证驱动
//
// 目的：把「板上新逻辑」——sd_adapter + 装载 FSM + 外控 —— 在仿真里跑绿，
//      再上板。SD 层用测试桩（sd_spi + 引脚级卡模型），帧存储写口用 C++ 模型
//      （近似 frame_fifo_write 的 write_req/ack 与 write_finish）。
//
// 检查点：
//   S1 挂载 + 首图装载提交（display_valid）+ 像素与 golden 逐像素比对
//   S2 按键 → 第二张提交 + 比对
//   S3 按键 → 第三张提交 + 比对（回绕/跳过 WAV 项的逻辑由 order 计算验证）
//   S4 写口握手发生过（write_req 曾拉高）
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "verilated.h"
#include "Vboard_top.h"
#include "sd_card_model.h"
#include "fat32_golden.h"

static const size_t N_PIX = (size_t)640 * 480;

static VerilatedContext *ctx = new VerilatedContext;
static Vboard_top *dut = new Vboard_top;
static SdCardModel card;

static int pass = 0, fail = 0;
static void check(bool ok, const char *what) {
    std::printf("%s: %s\n", ok ? "  PASS" : ">>FAIL", what);
    if (ok) pass++; else fail++;
}

// ---- 与 RTL 一致的图片选择逻辑 ----
// tmap 只覆盖播放列表前 6 项（RTL o_type_map 语义）
static int first_bmp_idx(int cnt, uint32_t tmap) {
    for (int k = 0; k < 6 && k < cnt; k++)
        if (!((tmap >> k) & 1u)) return k;
    return 0;
}
static int next_bmp_idx(int cur, int cnt, uint32_t tmap) {
    int cand = cur;
    for (int k = 0; k < 6; k++) {
        cand = (cand + 1 >= cnt) ? 0 : cand + 1;
        bool is_wav = (cand < 6) && ((tmap >> cand) & 1u);
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
    return (w == 640 && h == 480 && bpp == 24 && comp == 0);
}

// ---- 写口模型（近似 frame_fifo_write）----
static std::vector<uint32_t> pixbuf;
static int   prev_wr = 0;
static int   wr_d1 = 0, wr_d2 = 0, wr_d3 = 0;
static int   wft = 0;
static bool  wft_set = false;

static void sample_write() {
    int wr = dut->write_req;
    if (wr && !prev_wr) {              // 新装载开始：清像素缓冲
        pixbuf.clear();
        wft_set = false;
    }
    prev_wr = wr;
    if (dut->write_en && pixbuf.size() < N_PIX)
        pixbuf.push_back((uint32_t)dut->write_data);
    if (dut->write_en && pixbuf.size() >= N_PIX && !wft_set) {
        wft ^= 1;                      // 整帧落盘 → 翻转 write_finish_toggle
        wft_set = true;
    }
    wr_d3 = wr_d2; wr_d2 = wr_d1; wr_d1 = wr;
    dut->write_req_ack      = wr_d3;   // ack ≈ write_req 延迟 3 拍
    dut->write_finish_toggle = wft;
}

// ---- 时钟 / 卡模型接线（同 csrc/main.cpp 模式）----
static void half_cycle() {
    dut->clk ^= 1;
    dut->eval();
    ctx->timeInc(1);
    dut->SD_MISO = card.eval(dut->SD_nCS, dut->SD_DCLK, dut->SD_MOSI);
    if (dut->clk) sample_write();      // 上升沿后采样写口输出
}
static uint64_t cycles = 0;
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
    dut->key_next = 0;                       // 按下
    for (int i = 0; i < 6000000; i++) cycle();
    dut->key_next = 1;                       // 松开
    for (int i = 0; i < 5500000; i++) cycle();
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
    if (sc != last_state) {
        std::printf("      [t=%llu] state=%d disp=%d dv=%d pixbuf=%zu wft=%d\n",
                    (unsigned long long)cycles,
                    sc, (int)dut->disp_buf_idx, (int)dut->display_valid,
                    pixbuf.size(), wft);
        last_state = sc;
    }
}

// pixbuf 与 golden BMP（文件序，BGR）逐像素比对
static bool compare_pixbuf(const std::vector<uint8_t> &bm) {
    if (pixbuf.size() != N_PIX) {
        std::printf("      pixbuf=%zu 需 %zu\n", pixbuf.size(), N_PIX);
        return false;
    }
    for (size_t i = 0; i < N_PIX; i++) {
        uint32_t got = (uint32_t)(pixbuf[i] >> 8);   // {R,G,B}
        uint32_t exp = ((uint32_t)bm[54 + 3 * i + 2] << 16)
                     | ((uint32_t)bm[54 + 3 * i + 1] << 8)
                     |  (uint32_t)bm[54 + 3 * i];
        if (got != exp) {
            std::printf("      首个失配 像素#%zu: got=%06x exp=%06x\n",
                        i, got, exp);
            return false;
        }
    }
    return true;
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
    GoldenFs g = fat32_parse_golden(img);
    std::printf("===== board sd_card_bmp 验证 (%s, golden: %s, %zu 项) =====\n",
                img_path, g.ok ? "OK" : "FAIL", g.bmps.size());

    // 期望播放顺序：首图 + 两次按键
    uint32_t tmap = 0;
    for (int i = 0; i < 6 && i < (int)g.bmps.size(); i++)
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
    dut->key_next = 1;    // 释放（低有效按键）
    dut->key_auto = 1;    // 释放
    dut->write_req_ack = 0;
    dut->write_finish_toggle = 0;
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

    // S2 按键 → 第二张
    press_next();
    guard = 120000000;
    while (guard-- && commits < 2) { cycle(); watch_commit(); }
    check(commits >= 2, "S2 按键切换 → 第二张提交");
    if (commits >= 2)
        check(compare_pixbuf(g.bmps[order[1]].data),
              "S2b 第二图像素与 golden 比对");

    // S3 按键 → 第三张
    press_next();
    guard = 120000000;
    while (guard-- && commits < 3) { cycle(); watch_commit(); }
    check(commits >= 3, "S3 按键切换 → 第三张提交");
    if (commits >= 3)
        check(compare_pixbuf(g.bmps[order[2]].data),
              "S3b 第三图像素与 golden 比对");

    // S4 第四张
    int exp4 = next_bmp_idx(order[2], (int)g.bmps.size(), tmap);
    press_next();
    guard = 120000000;
    while (guard-- && commits < 4) { cycle(); watch_commit(); }
    check(commits >= 4, "S4 第四张提交");
    if (commits >= 4)
        check(compare_pixbuf(g.bmps[exp4].data),
              "S4b 第四图像素与 golden 比对");

    // S5/S6：继续按。自适应——按到的项是合法图则期望提交+比对；
    //         坏图 / WAV（含越出 type_map 6 项的 WAV，按图片处理→img_err 跳过）则期望不提交。
    // 返回本次是否提交（供调用方续用）
    auto press_adaptive = [&](const char *tag, int &exp, int &c_after) -> bool {
        bool bad = !loadable_bmp(g.bmps[exp].data);
        if (bad)
            std::printf("      卡自检：索引 %d 非合法图，验证跳过路径\n", exp);
        int c_before = commits;
        press_next();
        uint64_t g2 = bad ? 3000000u : 120000000u;   // 坏图头校验快；合法图整帧慢
        while (g2-- && commits == c_before) { cycle(); watch_commit(); }
        if (bad) {
            check(commits == c_before, tag);          // 跳过：不应提交
            c_after = c_before;
            return false;
        } else {
            check(commits == c_before + 1, tag);      // 合法图：应提交
            if (commits == c_before + 1)
                check(compare_pixbuf(g.bmps[exp].data), "      像素与 golden 比对");
            c_after = commits;
            return true;
        }
    };

    int exp5 = next_bmp_idx(exp4, (int)g.bmps.size(), tmap);
    int c_after5;
    bool committed5 = press_adaptive("S5 下一项处理正确（合法图提交 / 坏图跳过）",
                                     exp5, c_after5);
    (void)committed5;

    int exp6 = next_bmp_idx(exp5, (int)g.bmps.size(), tmap);
    int c_after6;
    bool committed6 = press_adaptive("S6 下一项处理正确（合法图提交 / 坏图/WAV 跳过）",
                                     exp6, c_after6);
    (void)committed6;

    std::printf("===== %d passed, %d failed =====\n", pass, fail);
    return fail ? 1 : 0;
}
