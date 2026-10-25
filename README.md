# 双板 HDMI 多媒体系统

媒体板从 SD 卡读取 BMP/WAV，显示板负责 SDRAM、HDMI 和图像后处理。两板通过千兆以太网交换机直连传输，PC 负责控制和按需源图预览。

## 当前功能与入口

- 原生 4-bit SD High Speed 50 MHz 只读、FAT32、24-bit BMP 解析及同名 WAV 配对。
- 固定 1280×720 HDMI 输出；网络只传源图尺寸的 RGB565，显示板居中填黑。
- 单图、左右双图、四宫格；多窗口等比例双线性缩小，不放大。切图只更新请求发生时光标所在的窗口，加载期间该窗口为黑色。
- 单图保留直接切、交叉溶解、32 像素柔边替换和配对音频；多窗口静音、直接切图。
- 全屏原图、灰度、二值化、Sobel、锐化、雪花六种运行时 CV 模式；字幕、OSD、频谱和 GT911 角色光标继续叠加；字幕/OSD 使用透明背景的 16×32 彩色字形，频谱最高 160px，雪花使用双层六瓣样式。
- Ethernet、USB UART、HC-08（9600 baud）及实体按键控制；GT911 支持相对移动和横划切图。
- Web 控制台保留 D 源图快照、BMP 对比及板卡忙状态互锁。

2026-10-23 双板 V2.2 全功能版已验收；本轮后续显示样式也已由用户在 HDMI 上确认。复位默认值保持原样：无字幕、频谱关、CV 原图、OSD 调节后 3 秒。正式 RTL、已验收 bit/报告及文档一并保存。本轮状态和资源数字见 [板卡资源与验收](docs/board_status.md)。

## 工程与网络

| 角色 | 目录 / TD 工程 | IP | JTAG |
| --- | --- | --- | --- |
| 显示板 | `board_display/td_project/lab_ex5_i2s_v1.0.al` | 192.168.137.2 | cable0 |
| 媒体板 | `board_media/td_project/media_net.al` | 192.168.137.3 | cable1 |
| PC | `scripts/web_console/app.py` | 192.168.137.1/24 | 回包 UDP :2 |

两套板级工程各自包含 RTL、厂商 IP 和约束。生产显示板的精简网络栈只服务固定媒体端；PC 直接 ping 显示板不能作为它是否在线的判断，使用经媒体板返回的状态/布局结果。

启动控制台：

```powershell
python scripts/web_console/app.py
```

浏览器打开 `http://127.0.0.1:5000`。依赖为 Flask、pyserial；以太网目标固定到媒体板。Web 操作和 HC-08 十六进制命令分别见 [控制台](docs/web_console.md)、[命令字节表](docs/hc08_control_commands.md)。

## 开发与复现

1. 按两板职责修改对应工程；先与稳定提交 diff，检查新增行为逻辑，再扩大排查范围。
2. 根据改动运行 [定向仿真](docs/verification.md)。`boardtest` 保留历史单板/SPI 模型，也包含原生 SD、双板协议、多窗口和 CV 测试；旧主仿真不等于当前双板全系统仿真。
3. 分别完成综合和布局布线；正式 bit 与对应 RTL、报告必须成套保存。
4. 上板功能通过后，按用户指示提交。仓库规则见 [提交与产物策略](docs/repository_commit_policy.md)。

**TD CLI 综合和 SRAM 下载已实证可用。** 完整命令、权限与 USB 故障判定见 [TD CLI 指南](docs/td_cli_programming.md)，下载入口固定使用：

```powershell
.\scripts\program_sram.ps1 -Board display
.\scripts\program_sram.ps1 -Board media
```

## 文档导航

| 内容 | 文档 |
| --- | --- |
| 当前分工、SDRAM 与路由 | [双板架构](docs/dual_board_architecture.md) |
| 字段、字节序、校验与重试 | [板间协议](docs/media_link_protocol.md) |
| 可变帧、多窗口、黑窗更新、仲裁 | [多窗口实现](docs/native_frame_multiview_handoff.md) |
| SD 原生模式与 HC-08 | [读卡与蓝牙](docs/native_sd_hc08.md) |
| CV、字幕/OSD、频谱、触控 | [CV](docs/display_cv_effects_exploration.md)、[OSD](docs/osd_subtitle.md)、[DFT](docs/audio_spectrum.md)、[GT911](docs/gt911_trackpad.md) |
| 验证入口、资源、时序 | [验证](docs/verification.md)、[资源](docs/board_status.md)、[时序判读](docs/timing_report_howto.md) |
| 典型故障与修复证据 | [多分辨率复盘](docs/multires_fix_postmortem.md)、[双板联调](docs/dual_board_live_debug_20261020.md)、[音频回卷](docs/media_sd_audio_reject_debug.md) |
| 多窗口调试与优化历史 | [开发记录](docs/history/multiview_development_log.md) |
| 后续视频、局部播放与多窗口音频/转场方向（尚未实现） | [讨论记录](docs/video_multiview_direction.md) |
| 当前分支资源回收候选与独立构建 | [优化记录](docs/resource_optimization_20261024.md) |

`docs/architecture.md`、`docs/design.md` 与 `docs/TODO.md` 保存早期单板架构和开发历史，不再是当前双板的实施计划。所有历史仿真保留，测试镜像和可再生输出按 `.gitignore` 管理；正式已跟踪 bit/报告不因忽略规则而停止跟踪。
