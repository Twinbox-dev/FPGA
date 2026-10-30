# 验证与日常迭代

当前验证对象是媒体板与显示板的双板产品，功能入口见 [双板架构](dual_board_architecture.md) 和 [多窗口实现](native_frame_multiview_handoff.md)。SDRAM 维持 100 MHz。历史单板七卡框架、SPI 模型和仿真副本全部保留；它们验证对应模块，不能冒充当前双板全系统或物理层仿真。

> **重要：TD CLI 综合和 SRAM 下载命令已确认。** 可从项目 `syn_1`/`phy_1`
> 工作目录调用 TD `DefaultFlow.tcl`，再用 `download -mode jtag -bit <bit路径>`
> 下载到 JTAG 目标的易失 SRAM。详见
> [TD CLI 综合与 SRAM 下载指南](td_cli_programming.md)。

字幕、OSD 及控制协议修改时，先运行 `make -C boardtest osd-unit`、
`make -C boardtest uart` 和 `python scripts/web_console/test_subtitle.py`；
板级观察步骤见 [`osd_subtitle.md`](osd_subtitle.md)。
频谱模块或音频采样接线修改时，先运行 `make -C boardtest spectrum-unit`；
当前 8-bit 音源与后续 24-bit 升级边界见 [`audio_spectrum.md`](audio_spectrum.md)。

## 按改动范围选择验证

| 改动 | 开发时先运行 | 收口时 |
|---|---|---|
| `frame_fifo_write/read`、仲裁或跨域 FIFO | `make -C boardtest framepath arbrace readeng` | 相关数据路径回归、TD、上板 |
| `video_delay`、AXI 像素适配 | `make -C boardtest vdelay axis` | 视频路径回归、HDMI 上板 |
| `eth_front`、命令、Web 预览 | `make -C boardtest ethfront cmdarb uart`；`node scripts/web_console/test_frame_view.js`；`python scripts/web_console/test_stream.py` | 控制/预览回归、PC/板卡联测 |
| SD/FAT/BMP/WAV 状态机 | `make -C boardtest smoke`；涉及配对时加 `paircheck` | 七卡回归、真实卡上板 |
| 媒体板 WAV 解析器 | `make -C boardtest wav-reader-unit media-sd-image-source` | 逐拍参考/golden、配对 PCM 与实卡音频 |
| 原生 SD / HC-08 | `make -C boardtest sd-native bt-uart-unit` | 实卡/手机及双板控制 |
| 可变帧、多窗口、缩小 | `make -C boardtest view-geometry view-image-pipeline view-session view-control-path` | 地址/排空测试与实际双板布局 |
| 运行时 CV | `make -C boardtest cv-unit axis` | HDMI 切模式和像素观察 |
| 仅文档或不执行的脚本 | 相应格式/脚本检查 | 无需为了文档重跑全部仿真 |

`boardtest` 需要 WSL/Linux 的 Verilator、make 和测试卡镜像。已有构建结果可复用；
修改对应源码后 make 会重编。只跑一张卡：

```sh
make -C boardtest smoke
make -C boardtest paircheck
make -C boardtest transition-unit
make -C boardtest transitionpair
SIM_TRANSITION=2 SIM_PAIR=1 boardtest/build_board/sim_board img/card_user.img
make -C boardtest lean-smoke
SIM_LEAN_LIST=1 SIM_PAIR=1 boardtest/build_board_lean/sim_board img/card_diag.img
make -C boardtest regress CARDS="card_user card_user_2wav"
make -C boardtest regress
```

`smoke` 使用 `card_diag`，在首图像素逐字比对与全部 WAV 扫描/BUF2 打包比对后
结束（`SIM_SMOKE=1`），**不覆盖播放回卷、切图、上一张或自动轮播**；
`paircheck` 在全列表配对 golden 断言、首图音频和第一次图音切换后结束
（`SIM_PAIR=1`），实测诊断卡 18/18、约 1 分 21 秒；不覆盖后续轮播/回卷。
`transition-unit` 覆盖混合器、逐像素相位、行就绪、100/75 MHz 双时钟行缓存、
SDRAM 阻塞时整行回退及真实帧 FIFO 与行预取同时工作，共六项；最后的寄存式
读口预留修改后仍全部通过。`transitionpair` 使用诊断卡验证带 WAV 的图音延迟
原子提交（19/19）；`SIM_TRANSITION=2` 的 `card_user` 用例验证无配对 WAV 时
完成切换后才静音（13/13）。默认直接切的 `paircheck` 保持 18/18。
`regress` 默认仍运行全部七卡。可选卡名固定为
`card card_mbr card_empty card_frag card_diag card_user card_user_2wav`，脚本会先检查
镜像存在。日志生成在 `boardtest/logs/`，属于可再生输出，不纳入 Git。
历史 `boardtest/vsrc/sd_card_bmp.v` 保留其 SPI/SIM_FAST 增量；当前产品源在媒体板，新增定向目标直接引用对应产品模块。旧 `sync_boardtest_sd.py` 依赖已删除的显示板 SD 源文件，已清除；不要用生产单文件覆盖历史仿真副本。

## 覆盖边界

`boardtest` 主仿真用 C++ SD 卡模型和简化的显存/读写行为，不包含厂商 SDRAM
控制器、板级布线、完整 HDMI/TMDS 或以太网物理层。模型顶替的接口不能被误当成
真实 RTL 的逐拍证据。真实写 FIFO 和突发时序要看 `framepath`、
`arbrace`、`readeng`；视频读和封包分别看 `vdelay`、`axis`。
厂商 IP 的物理时序和真实显示效果仍需 TD 报告与上板确认。

历史单板 1/3 读回及临时显示扫描探针只证明其覆盖位置；当前网页 D 从媒体板 SD 重读原始源图，不观察显示 SDRAM、黑边、缩小或 CV。显示端验证应使用实际 HDMI 或专用扫描诊断，不能用源图 D 代替。新增功能若在稳定版上失败，
先 diff 新旧源码并检查新引入的行为逻辑，再扩展到时序/IP 假设。

## 容易重犯的实现错误

- TD 推断 BRAM 时，存储数组需要合适的 `force_ram`/style 标注、无复位的独立
  读写 always 和支持的深度；之前 1030×8 的缓冲落成 LUT/FF，资源直接超限。
- 同一寄存器的复位与更新不能分属多个 always；TD 会报多驱动。
- Gray 异步 FIFO 的 full/empty 应寄存，读出当前队头 `mem[rbin]`；
  曾有组合环和跳过首字的失败实例。
- CDC toggle 发出时，同拍锁存并保持跨域数据；单拍 `tx_pkt` 直接跨域曾让
  以太网转储包退化为 ACK。
- 修改 Web 模板后重启 `app.py` 并刷新浏览器，否则可能仍在看缓存页面。
- TD 重生成 `sys_pll` 后可能删掉生成封装中的 `extlock` 输出；顶层仍连接
  `sys_pll_lock` 用于复位释放。综合前检查 `sys_pll.v` 的端口声明和原语连线。

## 合并前检查

涉及功能 RTL 的变更先运行相关定向测试，再按实际风险选择必要的组合回归；修改历史单板公共 SD/FAT/BMP/WAV 路径时运行七卡回归，不要求每次独立模块微调都跑全部镜像。查看 TD 资源和时序报告；影响显示、音频、SDRAM、时钟或硬件接口时安排上板对照。不要把
“仿真通过”写成“硬件时序收敛”。完整七卡、特定模块测试以及板级现象分别记录。

尚未实现的增强验证包括厂商 SDRAM IP 等价模型、完整 TMDS 接收器和可听音频
golden；旧文档曾将这些规划写成已存在的测试结构，此处明确标为未来工作。

## 双板媒体路径验证

显示板与媒体板的协议级 RTL 回归：

```sh
make -C boardtest mediamux media-protocol media-writer media-control media-tx media-audio-playback media-display-path media-image-tx ctrlset uart ethfront
```

`media-display-path` 覆盖正式媒体包接收、像素/PCM SDRAM 写入、提交回包；`media-image-tx` 检查媒体发送 BEGIN 的自动轮播 bit4 与 WAV 配对 bit3。实网 PC 对端模拟及最终 TD 资源/时序报告见 [双板架构](dual_board_architecture.md) 和 [`media_link_protocol.md`](media_link_protocol.md)。
PC WebTransport 快照接收回包单测：python scripts/web_console/test_media_snapshot.py。

## 现有工具取舍

- `boardtest/diagnostics/prepare_resource_experiment.py`：冻结整份板级源码和 TD 输入到独立实验目录，避免资源实验覆盖已验收正式 bit；`--display-diagnostics` 只在副本中启用扫描摘要/测试光标。步骤和对比见 [资源优化记录](resource_optimization_history.md#optimization-20261024)。

- `scripts/media_sd_board_acceptance.py`：真实双板单图 N/D 和源 BMP golden；不是显示端扫描验收。
- `scripts/dual_board_cmd_probe.py`：经媒体板往返显示设置并恢复原音量。
- `scripts/pc_media_display_stub.py` / `pc_display_media_probe.py`：隔离构建下分别代接媒体板/显示板；生产固定 peer 参数需匹配。
- `scripts/media_sd_diag_probe.py`、`media_mac_ready_probe.py`：SD/历史 MAC 抓包诊断入口；当前媒体顶层 `MAC_CAPTURE=0`，MAC 探针工具需配套启用抓包的隔离 bit，正式 bit 不会提供该捕获。
- `scripts/analyze_frame_dump.py`、`pl_dump.py`：历史探针分析，使用前检查对应 bit 是否实际包含探针。
- `boardtest/diagnostics/check_multiview_scan.py` 读取 64-byte 诊断体；`check_multiview_scan_short.py` 读取 16-byte 诊断体。二者只有包长度判断不同，但对应不同硬件协议，均保留。

仅等待早期 media demo 固定 `E1 53 45 4D` 回复的 `media_eth_probe.py` 已清除；当前在线检查用 S/VIEW_STATUS 或上述控制探针。所有仿真 RTL、模型、桩、测试目标和参考诊断 bit 均保留。
