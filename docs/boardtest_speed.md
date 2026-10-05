# 仿真提速记录（boardtest）

> 本文记录早期加速实验。当前日常用例选择、`smoke` 和七卡回归入口以
> [验证文档](verification.md) 为准；本文件中的耗时是当时机器与镜像的测量值。

**2026-10-06 当前基线（同一 WSL 主机）**：默认七卡回归 433/433，墙钟
12m00s；大卡各约 2.1–2.35 Gcycle、3.2–3.3 Mcycle/s。新增的单卡
`smoke` 在首图/BMP/WAV 扫描比对后退出，13/13，墙钟 20.9s（含一次
约 2.4s 的 C++ 重编）。旧“≤2 分钟”结果不能直接比较，因为后续检查路径
及仿真周期数均已增长。保持七卡默认完整覆盖，开发时先跑相关模块自检或
`smoke`。

> 目标：全量回归（7 卡）≤ 2 分钟。2026-09-27 从 12+ 分钟降到 ~2 分钟。
> 单卡 ~50s（RTL 已定型后的迭代基本单位）。

## 钱花在哪（card.img 实测 382 Mcyc / 52s）

| 项 | 占比 | 能否压缩 |
|---|---|---|
| 图像装载 ×6（S1–S6） | ~45% | SPI 已跑满 25MHz（DIV_FAST=2，bit=4clk），**位宽层面到底**；再快只能绕过 sd_spi（见下"未做"） |
| 按键去抖等待 ×9 | ~25% | ✅ 已压（boardtest 副本 1ms 去抖 + 驱动按住 2ms） |
| 音频播放逐字节验证 ×4 | ~25% | 必须实时放一整圈（RTL 播放速率 2083clk/样本是设计本身），只能缩短测试 WAV |
| 扫描 WAV 读 | ~5% | 缩短测试 WAV |

## 已落地的提速项

1. **测试 WAV 缩短**（时长直接线性于仿真时长）：
   - `scripts/gen_diag_card.sh`：诊断卡仿真版 0.5s（上板 5s 版在 Desktop/diag_audio 不动）
   - `scripts/truncate_wav_in_img.py`：用户卡镜像内 WAV 原地截断到 1s
     （FAT 链截断 + 目录项 + RIFF/data 头同步改；保留目录结构/碎片/删项）
     原始镜像备份 `img/*.img.bak`
2. **并行回归**：`make -C boardtest regress` = 7 卡 7 进程并行，
   脚本 `scripts/run_all_sims.sh`，日志 `boardtest/logs/<卡>.log`，墙钟≈最慢单卡
3. **boardtest 副本 1ms 去抖**（`` `ifdef VERILATOR ``，board/ 正式版 50ms 不变）
   + 驱动 `press_next` 按住/松开各 200k 周期（余量 2×）
4. **Makefile `-O3 -march=native`**：+12%（6.6→7.4 Mcyc/s）
5. **`getenv` 缓存成 static**（调试打印 gating 每拍都 getenv 是隐藏大坑，
   并行 7 进程时系统调用争用掉一半吞吐）

## 试过没用的

- `--threads 4`：模型太小、eval 太短，线程调度开销反噬，显著变慢。放弃。

## 未做（要更快时的下一步）

- ~~Fast-SD 旁路~~ → **已落地为 SIM_FAST 档**（见下节），默认档仍全保真。
- SD_VERBOSE 的 FAT/PSTATE 迁移打印按迁移次数限速（现在状态迁移多时会刷屏）。

## SIM_FAST：SD 直连扇区档（2026-09-29 落地，日常迭代用）

```bash
SIM_FAST=1 make -C boardtest regress     # 7 卡并行，墙钟 ~2.5min
SIM_FAST=1 ./boardtest/build_board/sim_board img/card.img   # 单卡 ~50s
```

机制：`fast_sd_stub`（vsrc/stub_sd_card_top.v）按扇区协议直接应答，
字节由 C++ 从镜像按 LBA 投喂（`feed_fast_sd`），**绕开 sd_spi 翻译 +
引脚级卡模型**。`fast_en` 在 boardtest 顶层二选一，默认档（不带 SIM_FAST）
走原引脚级路径不变。

实测（card.img，含 S8）：**1104 Mcyc / 135s → 369 Mcyc / 50s（~2.7×）**；
7 卡并行墙钟 ~6min → ~2.5min。装载类周期下降最明显（单图 ~2.8M 拍）。

### 代价与注意事项

- **SPI 协议栈退出仿真覆盖**（含 HCS 协商、CRC、重试、引脚时序）。
  板上已验证；**默认档保留全保真**——出现查不出的可疑 bug 时，先切默认档
  跑一遍排除 SPI 因素。
- **字节节拍 PACE_DIV=4**（每 4 拍 1 字节；SPI 档约 32 拍/字节）：
  1 拍/字节会超出下游节拍假设（音频打包器按 ack 节奏取字节、扫描项永不关闭，
  表现为挂载后空转 20 分钟）；**实测 2 拍/字节仍崩，4 是边界内侧**，勿改小。
- 快速档的扇区寻址固定块寻址（协议层地址单元即扇区号；无 SPI 初始化流程，
  卡模型的 HCS 不参与）。
- 调试开关仍有效：`SD_VERBOSE=1` 的 FAT/PSTATE 跟踪在快速档同样可用。

## 性能自检

每次跑结束打 `Mcyc / 秒 / Mcyc/s`，回归异常变慢先看这个数
（基线单卡 7.4，7 卡并行 3.7–4.2 属正常争用；2026-09-29 复测单卡
8.1–8.2、并行 3.0–4.8，均正常）。
