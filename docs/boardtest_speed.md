# 仿真提速记录（boardtest）

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

- **Fast-SD 旁路**：boardtest 专用桩直接按字节喂 sd_adapter 的 sec 口
  （绕开 sd_spi 引脚级）。能再砍 ~40% 单卡时间，但 SPI 协议栈出 sim 覆盖，
  默认档别轻易开。
- SD_VERBOSE 的 FAT/PSTATE 迁移打印按迁移次数限速（现在状态迁移多时会刷屏）。

## 性能自检

每次跑结束打 `Mcyc / 秒 / Mcyc/s`，回归异常变慢先看这个数
（基线单卡 7.4，7 卡并行 3.7–4.2 属正常争用）。
