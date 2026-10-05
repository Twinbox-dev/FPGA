# 嵌赛'2026 安路选题一 —— TF 卡 720p BMP 轮播 + 配对 WAV 伴音（单仓）

## 基线来源（provenance）
- 仿真框架 + boardtest：`anlogic` 仓 `6956e5d`（boardtest 即为 board 工程对应
  版本的 Verilator 验证台快照，两者 RTL 逐字节一致）
- 板级 TD 工程：`workspace` 仓 `8974d52`（FAT32 文件系统层替换 + sd_card_bmp
  重写，已上板验证图像轮播）
- 旧的「3a 音频 FIFO 方案」（workspace `6290eba` / anlogic `e958ee4`）**不带入**，
  音频改为：WAV 整文件入 SDRAM，复用帧缓冲乒乓与原子提交；格式约定
  **24kHz / 8bit / mono**（板内 ×2 上采样到 48k 喂 HDMI 核）。旧仓封存不动。

## 当前形态（多分辨率 BMP + 配对 WAV，2026-10-06 上板验证）
HDMI 固定输出 1280×720@60；较小的 BMP 居中显示并填黑，RGB565 每个 32 位字存两个像素。
SDRAM 2M 字中，视频 A/B 各 460,800 字，音频 A/B 各 587,776 字（98s）。
以太网控制台支持写侧预览、SDRAM 返回抽样与 BMP 全帧黑边对照。
多分辨率故障的完整修复证据、曾被推翻的假设和后续调试准则见
[`docs/multires_fix_postmortem.md`](docs/multires_fix_postmortem.md)；板卡资源/时序盘点见 `docs/board_status.md`。

## 目录
- `board/` —— TD 工程（`user_source` 源 + `td_project` 工程文件），真机唯一真源
- `boardtest/` —— 板级 RTL 的 Verilator 验证台（SD 引脚级卡模型 + 帧写口 C++ 模型）
  - `make -C boardtest regress`：7 卡全量回归
  - `make -C boardtest readeng`：读写引擎真实 RTL 自检（主仿真盲区补充）
  - `make -C boardtest framepath`：真实异步 FIFO 的帧写入/读回字序
  - `make -C boardtest arbrace`：写突发寄存判决与读忙仲裁竞态回归
  - `make -C boardtest vdelay`：video_delay 565 解包/像素序自检（同上）
- `scripts/` —— 素材生成（gen_bmp / gen_wav / prep_media / gen_card / gen_diag_card）
- `img/` —— 卡镜像与生成媒体（脚本可再生，不入 git）
- `docs/` —— 架构、调试面板、时序排查、板卡盘点等

## 开发流程（单仓两步）
1. RTL 改动改 `board/user_source/hdl_source/`，涉及 SD/图像路径的把补丁同步
   `boardtest/vsrc/` 副本（两副本差异 = 探针 + VERILATOR 加速块），回归全绿
2. `board/` 综合上板；时序重点查 clk0（100M）与 hdmi_5x（375M）组

注意：`boardtest/vsrc` 不含视频读通道（C++ 模型替代 frame_read_write），
video_delay/frame_fifo_* 类改动必须跑 readeng/vdelay 自检。
