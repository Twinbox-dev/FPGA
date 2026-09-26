# 嵌赛'2026 安路选题一 —— TF 卡 BMP 轮播 + 配对 WAV 伴音（重构仓）

## 基线来源（provenance）
- 仿真框架 + boardtest：`anlogic` 仓 `6956e5d`（boardtest 即为 board 工程对应
  版本的 Verilator 验证台快照，两者 RTL 逐字节一致）
- 板级 TD 工程：`workspace` 仓 `8974d52`（FAT32 文件系统层替换 + sd_card_bmp
  重写，已上板验证图像轮播）
- 旧的「3a 音频 FIFO 方案」（workspace `6290eba` / anlogic `e958ee4`）**不带入**，
  音频改为：WAV 整文件入 SDRAM，复用帧缓冲乒乓与原子提交；格式约定
  **24kHz / 8bit / mono**（上板 ×2 上采样到 48k 喂 HDMI 核）。旧仓封存不动。

## 目录
- `vsrc/` `csrc/` `docs/` `scripts/` `img/` `tests/` —— 仿真主仓（Verilator + golden）
- `boardtest/` —— 板级 RTL 的 Verilator 验证台（SD 引脚级卡模型 + 帧写口模型）
- `board/` —— TD 工程（`user_source` 源 + `td_project` 工程文件）

## 开发流程（单仓三步，无跨仓同步）
1. RTL 改动先进 `vsrc/`，`make regress` 全绿
2. 同步 `boardtest/vsrc/`，`make run` 四张卡全绿
3. 进 `board/` 综合上板；`report_area` 必须看到大存储阵列进 bram
