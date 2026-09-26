// csrc/sd_spi-main.cpp — sd_spi 模块级排障入口（隔离复现用，主流程是 make sim）
//
//   make sim MODULE=sd_spi            # 只跑 sd_spi，不带 top 集成
//   make wave MODULE=sd_spi           # 带波形并打开 surfer
//   SD_VERBOSE=1 make sim MODULE=sd_spi
//
// 用例与系统级（csrc/main.cpp 的 S1..S9）同源，此处保留模块隔离视角：
// sd_spi 在系统里出问题时，先在这里单独复现。
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "verilated.h"
#include "Vsd_spi.h"
#include "sd_card_model.h"

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
static Vsd_spi *dut = new Vsd_spi;
static SdCardModel card;
#if HAS_TRACE
static TraceC *tfp = NULL;
#endif

static bool verbose = false;
static uint8_t last_state = 0xFF;

static void half_cycle() {
    dut->clk ^= 1;
    dut->eval();
    ctx->timeInc(1);
#if HAS_TRACE
    tfp->dump(ctx->time());
#endif
    dut->spi_miso = card.eval(dut->spi_cs_n, dut->spi_sclk, dut->spi_mosi);
    if (verbose && dut->o_dbg_state != last_state) {
        std::printf("[t=%llu] state=%u\n",
                    (unsigned long long)ctx->time(), (unsigned)dut->o_dbg_state);
        last_state = dut->o_dbg_state;
    }
}

static void single_cycle() {
    half_cycle();
    half_cycle();
}

static void reset(int n) {
    dut->rst_n = 0;
    while (n-- > 0) single_cycle();
    dut->rst_n = 1;
    dut->eval();
}

static void wave_open() {
#if HAS_TRACE
    ctx->traceEverOn(true);
    tfp = new TraceC;
    dut->trace(tfp, 0);
    tfp->open(WAVE_FILE);
#endif
}

static void wave_close() {
    dut->final();
#if HAS_TRACE
    tfp->close();
#endif
}

static int pass = 0, fail = 0;
static void check(bool ok, const char *what) {
    std::printf("%s: %s\n", ok ? "  PASS" : ">>FAIL", what);
    if (ok) pass++;
    else fail++;
}

static bool wait_ready(uint64_t guard) {
    while (!dut->o_ready && guard--) half_cycle();
    return dut->o_ready == 1;
}

// 发起一次扇区读；返回 0=done 1=err 2=guard 超时
static int read_sector(uint32_t lba, uint8_t *out) {
    if (!wait_ready(2000000)) return 2;
    dut->i_lba = lba;
    dut->i_req = 1;
    single_cycle();
    dut->i_req = 0;
    int n = 0;
    uint64_t guard = 1000000;
    while (guard--) {
        single_cycle();
        if (dut->o_dval) out[n++] = dut->o_data;
        if (dut->o_done) return 0;
        if (dut->o_err)  return 1;
    }
    return 2;
}

static std::vector<uint8_t> img;

int main(int argc, char **argv) {
    ctx->commandArgs(argc, argv);
    wave_open();
    verbose = std::getenv("SD_VERBOSE") != NULL;
    card.verbose = verbose;

    const char *img_path = argc > 1 ? argv[1] : "img/card.img";
    if (!card.load(img_path)) {
        std::printf("无法打开 %s（先跑 ./scripts/gen_card.sh）\n", img_path);
        return 1;
    }
    FILE *f = fopen(img_path, "rb");
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    img.resize((size_t)sz);
    if (fread(img.data(), 1, (size_t)sz, f) != (size_t)sz) {
        fclose(f);
        return 1;
    }
    fclose(f);

    dut->i_req = 0;
    dut->i_lba = 0;
    dut->spi_miso = 1;
    uint8_t buf[512];

    std::printf("===== sd_spi unit test (%s, %llu sectors) =====\n",
                img_path, (unsigned long long)card.sector_count());

    reset(10);
    check(wait_ready(2000000), "T1 初始化完成 (CMD0/CMD8/ACMD41 -> o_ready)");

    int r = read_sector(0, buf);
    check(r == 0 && std::memcmp(buf, img.data(), 512) == 0,
          "T2 读 0 号扇区，512B 与镜像比对");

    r = read_sector(100, buf);
    check(r == 0 && std::memcmp(buf, img.data() + 100ULL * 512, 512) == 0,
          "T3 读 100 号扇区（LBA 传参）");

    r = read_sector((uint32_t)card.sector_count() + 1, buf);
    check(r == 1, "T4 越界 LBA -> o_err（参数错不重试）");

    card.inject_drop_idx = 0;        // 丢下一条 CMD0
    reset(10);
    check(wait_ready(2000000), "T5 CMD0 无应答 -> 重试后初始化成功");

    card.inject_cmd_drop = true;     // 丢下一条命令（CMD17）
    r = read_sector(7, buf);
    check(r == 0 && std::memcmp(buf, img.data() + 7ULL * 512, 512) == 0,
          "T6 CMD17 丢命令 -> 重试后数据正确");

    check(card.sectors_read == 3, "T7 模型统计 sectors_read == 3");

    // 死卡：所有命令无应答 → CMD0 重试耗尽 → o_err + S_ERR(16) 卡死
    card.dead_card = true;
    reset(10);
    {
        uint64_t guard = 5000000;
        bool got_err = false;
        while (guard--) {
            half_cycle();
            if (dut->o_err) got_err = true;
            if (dut->o_dbg_state == 16) break;
        }
        check(got_err && dut->o_dbg_state == 16,
              "T8 死卡 -> 重试耗尽 o_err + S_ERR(16) 卡死");
    }

    std::printf("===== %d passed, %d failed =====\n", pass, fail);
    std::printf("card: cmds=%llu sectors_read=%llu\n",
                (unsigned long long)card.cmds_seen,
                (unsigned long long)card.sectors_read);
    wave_close();
    return fail ? 1 : 0;
}
