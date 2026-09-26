// csrc/mem_sim-main.cpp — mem_sim 模块级测试（存储层契约验证）
//
//   make sim MODULE=mem_sim
//   make wave MODULE=mem_sim
//
// 为什么需要独立的模块测试：
//   mem_sim 的三个诊断输出（o_wr_ovf / o_rd_und / o_len_err）在系统仿真里
//   是**恒为 0** 的 —— 那正是系统健康的证明。但恒零的信号无法区分「没出问题」
//   和「检测器本身坏了」。这里主动制造三种故障，验证检测器确实会响。
//
// 同时在此独立验证 WRITE_V_FLIP 的地址映射：系统级是靠整图 golden 比对间接
// 覆盖的，这里用可计算的数列直接查每个字的落点，出错时能立刻定位到坐标。
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "verilated.h"
#include "Vmem_sim.h"

#if VM_TRACE_FST
    #include "verilated_fst_c.h"
    typedef VerilatedFstC TraceC;
    #define WAVE_FILE "dump.fst"
#elif VM_TRACE
    #include "verilated_vcd_c.h"
    typedef VerilatedVcdC TraceC;
    #define WAVE_FILE "dump.vcd"
#endif
#if VM_TRACE_FST || VM_TRACE
    #define HAS_TRACE 1
#else
    #define HAS_TRACE 0
#endif

static VerilatedContext *ctx = new VerilatedContext;
static Vmem_sim *dut = new Vmem_sim;
#if HAS_TRACE
static TraceC *tfp = NULL;
#endif

static const int      FRAME_W = 640;
static const int      FRAME_H = 480;
static const uint32_t FRAME_PIXELS = FRAME_W * FRAME_H;   // 307200 = 256 * 1200
static const uint32_t BUF0 = 0;
static const uint32_t BUF1 = 307200;

static int pass = 0, fail = 0;
static void check(bool ok, const char *what) {
    std::printf("%s: %s\n", ok ? "  PASS" : ">>FAIL", what);
    if (ok) pass++;
    else fail++;
}

static void half_cycle() {
    dut->clk ^= 1;
    dut->eval();
    ctx->timeInc(1);
#if HAS_TRACE
    tfp->dump(ctx->time());
#endif
}

static void single_cycle() {
    half_cycle();
    half_cycle();
}

static void reset(int n) {
    dut->rst_n = 0;
    dut->write_req = 0;
    dut->write_en = 0;
    dut->write_data = 0;
    dut->write_addr_0 = BUF0;
    dut->write_addr_1 = BUF1;
    dut->write_addr_index = 0;
    dut->write_len = FRAME_PIXELS;
    dut->read_req = 0;
    dut->read_en = 0;
    dut->read_addr_0 = BUF0;
    dut->read_addr_1 = BUF1;
    dut->read_addr_index = 0;
    dut->read_len = FRAME_PIXELS;
    for (int i = 0; i < n; i++) single_cycle();
    dut->rst_n = 1;
    single_cycle();
}

// 按协议开写通道：req 保持到 ack，再撤销。返回是否在限时内拿到 ack
static bool open_write(uint32_t len, int buf_idx, uint64_t guard = 100000) {
    dut->write_len = len;
    dut->write_addr_index = buf_idx;
    dut->write_req = 1;
    while (!dut->write_req_ack && guard--) single_cycle();
    if (!dut->write_req_ack) return false;
    dut->write_req = 0;
    single_cycle();
    return true;
}

static bool open_read(uint32_t len, int buf_idx, uint64_t guard = 100000) {
    dut->read_len = len;
    dut->read_addr_index = buf_idx;
    dut->read_req = 1;
    while (!dut->read_req_ack && guard--) single_cycle();
    if (!dut->read_req_ack) return false;
    dut->read_req = 0;
    single_cycle();
    return true;
}

// 按给定节奏推入 n 个字：每推 1 个字空 gap 拍。
//
// gap=0（满速 1 字/拍）**会溢出**，这不是模型缺陷而是接口的真实约束：
// 突发之间有 S_BURST_END + S_CHECK 两拍不排空，净排空率 256/258 ≈ 0.992 字/拍，
// 低于满速供数。例程结构相同（且 App_wr_en 还多一级流水），板级同样如此。
// 真实生产者 bmp_dec 是「3 个 SPI 字节出 1 像素」，约 0.01 字/拍，余量极大。
static void push_words(uint32_t n, uint32_t first_val, bool constant_val, int gap) {
    for (uint32_t i = 0; i < n; i++) {
        dut->write_en = 1;
        dut->write_data = constant_val ? first_val : (first_val + i);
        single_cycle();
        dut->write_en = 0;
        for (int gi = 0; gi < gap; gi++) single_cycle();
    }
    dut->write_en = 0;
}

// V_FLIP 映射：第 j 个推入的字（BMP 文件顺序）落到显示坐标
//   行 = FRAME_H-1 - j/FRAME_W，列 = j%FRAME_W
// 反过来，显示地址 a=(r,c) 处应当是第 (FRAME_H-1-r)*FRAME_W + c 个推入的字
static uint32_t expect_at(uint32_t addr) {
    uint32_t r = addr / FRAME_W;
    uint32_t c = addr % FRAME_W;
    return (FRAME_H - 1 - r) * FRAME_W + c;
}

int main(int argc, char **argv) {
    ctx->commandArgs(argc, argv);
#if HAS_TRACE
    ctx->traceEverOn(true);
    tfp = new TraceC;
    dut->trace(tfp, 5);
    tfp->open(WAVE_FILE);
#endif

    std::printf("===== mem_sim 模块测试：存储层契约 =====\n");

    // ================================================================
    // T1 正常整帧：写入可计算数列 → 读回，逐字验证 V_FLIP 落点
    // ================================================================
    reset(5);
    check(open_write(FRAME_PIXELS, 0), "T1a 写通道握手（req 保持到 ack）");

    // 供数节奏 gap=1（0.5 字/拍）：高于真实生产者两个数量级，仍在排空能力内
    push_words(FRAME_PIXELS, 0, false, 1);

    // 等全部落盘
    uint64_t guard = 2000000;
    while (!dut->write_finish && guard--) single_cycle();
    check(dut->write_finish, "T1b 整帧落盘（write_finish）");

    // 读回并逐字比对
    bool vflip_ok = true;
    uint32_t bad_addr = 0, bad_got = 0, bad_exp = 0;
    if (open_read(FRAME_PIXELS, 0)) {
        // 预填：读侧需要若干拍把 FIFO 填起来（板级靠场消隐完成）
        for (int i = 0; i < 600; i++) single_cycle();

        for (uint32_t a = 0; a < FRAME_PIXELS; a++) {
            dut->read_en = 1;
            single_cycle();                 // 本拍弹出，下一拍数据有效
            dut->read_en = 0;
            single_cycle();
            uint32_t got = dut->read_data;
            uint32_t exp = expect_at(a);
            if (got != exp) {
                vflip_ok = false;
                bad_addr = a; bad_got = got; bad_exp = exp;
                break;
            }
        }
    }
    else {
        vflip_ok = false;
    }
    if (!vflip_ok && bad_exp != bad_got) {
        std::printf("      首个失配：显示地址 %u (行%u 列%u) 期望第 %u 个写入字，实得 %u\n",
                    bad_addr, bad_addr / FRAME_W, bad_addr % FRAME_W, bad_exp, bad_got);
    }
    check(vflip_ok, "T1c WRITE_V_FLIP 地址映射逐字正确（307200 字）");
    check(!dut->o_wr_ovf && !dut->o_rd_und && !dut->o_len_err,
          "T1d 正常通路三个诊断均未点亮");

    // ================================================================
    // T2 写 FIFO 溢出：生产者持续满速推，快于突发排空的净速率
    //    （突发间的 S_BURST_END/S_CHECK 两拍没有排空，每轮净积压 2 字）
    //    板级现象：静默丢像素，没有任何信号提示 —— 正是要抓的
    // ================================================================
    reset(5);
    check(open_write(262144, 0), "T2a 写通道握手（长度 262144 = 1024*256）");
    uint32_t pushed = 0;
    guard = 200000;
    while (!dut->o_wr_ovf && guard--) {
        dut->write_en = 1;
        dut->write_data = pushed++;
        single_cycle();
    }
    dut->write_en = 0;
    check(dut->o_wr_ovf, "T2b 生产者超速 -> o_wr_ovf 点亮（板级会静默丢数据）");

    // ================================================================
    // T3 读 FIFO 下溢：未预填就弹
    //    板级现象：重复上一个像素，画面横向拖影
    // ================================================================
    reset(5);
    check(open_read(FRAME_PIXELS, 0), "T3a 读通道握手");
    dut->read_en = 1;
    single_cycle();                        // ack 后 FIFO 刚被清空，此拍必空
    dut->read_en = 0;
    single_cycle();
    check(dut->o_rd_und, "T3b 空 FIFO 弹出 -> o_rd_und 点亮（板级会横向拖影）");

    // ================================================================
    // T4 传输长度非突发整数倍
    //    板级现象：最后一个突发永远等不到 burst_cnt >= 256，状态机死锁
    //    640*480 恰好整除让例程躲过了，音频缓冲照搬这套接口就会踩中
    // ================================================================
    reset(5);
    check(open_write(1000, 0), "T4a 以 1000 字长度开写通道");
    check(dut->o_len_err, "T4b 长度非 256 整数倍 -> o_len_err 点亮（板级会死锁）");

    reset(5);
    check(open_write(307200, 0), "T4c 307200 是 256 的整数倍，不误报");
    check(!dut->o_len_err, "T4d 合法长度下 o_len_err 保持熄灭");

    // ================================================================
    // T5 双缓冲：写 BUF1 不污染 BUF0
    // ================================================================
    reset(5);
    // 先把 BUF0 写成全 0xAAAAAAAA
    if (open_write(FRAME_PIXELS, 0)) {
        push_words(FRAME_PIXELS, 0xAAAAAAAAu, true, 1);
        guard = 2000000;
        while (!dut->write_finish && guard--) single_cycle();
    }
    // 再把 BUF1 写成全 0x55555555
    if (open_write(FRAME_PIXELS, 1)) {
        push_words(FRAME_PIXELS, 0x55555555u, true, 1);
        guard = 2000000;
        while (!dut->write_finish && guard--) single_cycle();
    }
    // 读 BUF0，应仍为 0xAAAAAAAA
    bool buf0_clean = true;
    if (open_read(FRAME_PIXELS, 0)) {
        for (int i = 0; i < 600; i++) single_cycle();
        for (int i = 0; i < 4096; i++) {
            dut->read_en = 1;
            single_cycle();
            dut->read_en = 0;
            single_cycle();
            if (dut->read_data != 0xAAAAAAAAu) { buf0_clean = false; break; }
        }
    }
    else {
        buf0_clean = false;
    }
    check(buf0_clean, "T5 写 BUF1 不污染 BUF0（乒乓双缓冲隔离）");

    std::printf("===== %d passed, %d failed =====\n", pass, fail);
#if HAS_TRACE
    tfp->close();
#endif
    return fail ? 1 : 0;
}
