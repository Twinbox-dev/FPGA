# 嵌赛'2026 安路选题一 —— TF 卡 720p BMP 轮播 + 配对 WAV 伴音（单仓）

> **重点：TD CLI 可从命令行综合、布局布线并下载 FPGA bit。**
> 项目工程的 `syn_1`、`phy_1` 目录分别用 `settings.cfg` 选择综合和布局布线流程；
> `td_commands_prompt.exe` 执行 TD 自带的 `DefaultFlow.tcl`。JTAG SRAM 下载命令为
> `download -mode jtag -bit <bit路径>`。详细命令、步骤和模式差异见
> [TD CLI 综合与 SRAM 下载指南](docs/td_cli_programming.md)。

## 基线来源（provenance）
- 仿真框架 + boardtest：`anlogic` 仓 `6956e5d`（boardtest 即为 board 工程对应
  版本的 Verilator 验证台快照，两者 RTL 逐字节一致）
- 板级 TD 工程：`workspace` 仓 `8974d52`（FAT32 文件系统层替换 + sd_card_bmp
  重写，已上板验证图像轮播）
- 旧的「3a 音频 FIFO 方案」（workspace `6290eba` / anlogic `e958ee4`）**不带入**，
  音频改为：WAV 整文件入 SDRAM，复用帧缓冲乒乓与原子提交；格式约定
  **24kHz / 8bit / mono**（板内 ×2 上采样到 48k 喂 HDMI 核）。旧仓封存不动。

## 当前形态（多分辨率 BMP + 配对 WAV + 切换特效，2026-10-07 上板验证）
HDMI 固定输出 1280×720@60；较小的 BMP 居中显示并填黑，RGB565 每个 32 位字存两个像素。
SDRAM 2M 字中，视频 A/B 各 460,800 字，音频 A/B 各 587,776 字（98s）。
以太网控制台支持写侧预览、SDRAM 返回抽样与 BMP 全帧黑边对照。
串口和网页可选直接切、交叉溶解或 32 像素柔边替换；特效只在 HDMI 播放，
完成时才提交新图及配对 WAV，PC 的 `D` 读回仍取原始显示帧。
多分辨率故障的完整修复证据、曾被推翻的假设和后续调试准则见
[`docs/multires_fix_postmortem.md`](docs/multires_fix_postmortem.md)；当前板卡资源/时序基线见
[`docs/board_status.md`](docs/board_status.md)，按改动范围选择仿真见
[`docs/verification.md`](docs/verification.md)。

HDMI 滚动字幕与 OSD 面板已上板验证；协议、操作和验收见
[`docs/osd_subtitle.md`](docs/osd_subtitle.md)。
真实频谱可视化已于 2026-10-09 上板验证；自研 DFT 算法、资源变化、
当前 8-bit 音源的限制与后续 24-bit 升级见
[`docs/audio_spectrum.md`](docs/audio_spectrum.md)。
GT911 触控板的单指相对移动、角色光标和左右横划切图已上板验证；接线、实现和验收见
[`docs/gt911_trackpad.md`](docs/gt911_trackpad.md)。

## 目录
- `board_display/` —— 当前已验证的显示板 TD 工程（`user_source` 源 + `td_project` 工程文件）
- `board_media/` —— 媒体板正式 SD/解析/控制与图像/PCM 发送工程；分工见 `docs/dual_board_architecture.md`
- `boardtest/` —— 板级 RTL 的 Verilator 验证台（SD 引脚级卡模型 + 帧写口 C++ 模型）
  - `make -C boardtest regress`：7 卡全量回归
  - `make -C boardtest smoke`：单卡首图/BMP/WAV 扫描快速集成检查
  - `make -C boardtest regress CARDS="card_user card_user_2wav"`：只运行指定卡型
  - `make -C boardtest readeng`：读写引擎真实 RTL 自检（主仿真盲区补充）
  - `make -C boardtest framepath`：真实异步 FIFO 的帧写入/读回字序
  - `make -C boardtest arbrace`：写突发寄存判决与读忙仲裁竞态回归
  - `make -C boardtest vdelay`：video_delay 565 解包/像素序自检（同上）
  - `make -C boardtest transition-unit`：切换混合、行缓存与读口仲裁快速验证
  - `make -C boardtest transitionpair`：带 WAV 的切换完成回执与原子提交
  - `make -C boardtest gt911-unit`：GT911 地址探测、坐标读取与 HDMI 光标自检
- `scripts/` —— 素材生成（gen_bmp / gen_wav / prep_media / gen_card / gen_diag_card）
- `img/` —— 卡镜像与生成媒体（脚本可再生，不入 git）
- `docs/` —— 架构、调试面板、时序排查、板卡盘点等

## 开发流程（单仓两步）
1. RTL 改动改 `board_display/user_source/hdl_source/`，涉及 SD/图像路径时同步
   `boardtest/vsrc/` 副本（两副本差异 = 探针 + VERILATOR 加速块）。开发时先跑
   对应模块自检或单卡检查，收口时跑七卡全量回归。
2. `board_display/` 综合上板；对照 `docs/board_status.md` 的资源与时序基线。

注意：`boardtest/vsrc` 不含视频读通道（C++ 模型替代 frame_read_write），
video_delay/frame_fifo_* 类改动必须跑 readeng/vdelay 自检。
