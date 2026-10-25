# 多窗口切图转场与音频连续播放实现记录

日期：2026-10-25  
基线：`main` 上的双板 V2.3。多窗口转场已在提交 `65003f2` 中实现。本轮补充显示板音频跨布局保持，已完成 RTL 仿真、综合、布局布线、双板 SRAM 下载，并由用户上板确认功能符合预期。

## 用户确认的行为

- 单图直显、左右双图、四宫格沿用现有布局和窗口编号。
- 多窗口中只更新鼠标所在窗口。目标窗口在切图请求开始时锁定。
- 切图期间旧图继续显示；新图完整写入并校验后，只对目标窗口运行当前配置的转场。直接切换仍可配置。
- 转场完成后才把目标窗口的读指针切到新图。多窗口布局切换保持当前音频源继续播放；只有单图直显切图提交时才更新配对 WAV，未配对图片提交静音。多窗口不按窗口切换音频源。
- 单图模式现有转场行为保持不变。

## SDRAM 页与窗口指针

显示板现有两个图像页仍各为 460,800 个 32-bit 字；音频 BUF2/BUF3 不改。每页按单图、左右双图、四宫格布局解释，窗口槽容量分别为 460,800、230,400、115,200 字。

多窗口现在为每个窗口保存一个相对页选择位。其物理页由全局图像页和该窗口选择位异或得到。例：全局页为 A、窗口选择为 1 时，该窗口显示 B 页对应槽。不同窗口可以分别指向 A 或 B 页，因此能让未更新窗口继续显示旧图，同时在另一页的对应槽写新图。

同布局切图时，媒体事务写入目标窗口当前未显示的物理页。写入失败不改页选择位，因此屏幕保留原图。写入成功且效果模式为“直接切”时，管理器在帧边界提交目标窗口页选择位，并等待 SDRAM 读 FIFO 排空确认。

启用交叉溶解或柔边滑动时，顺序如下：

1. 新图写入目标窗口的非显示页，旧图继续扫描显示。
2. 转场控制器从新页按目标窗口行读取像素。双图每行读 320 个字；四宫格也每行读 320 个字，四宫格下半部使用本地行号并映射到正确的屏幕行。
3. 混合器仅对目标窗口生效；其他窗口保持原始视频 FIFO 像素。柔边滑动的进度范围是目标窗口宽度 640 像素，进入方向仍由上一张/下一张决定。
4. 转场达到新图全覆盖后进入保持态。管理器提交目标窗口页选择位，并等待显示侧帧边界配置和旧读请求排空。
5. 收到排空确认后，管理器释放转场保持态，显示侧改从新页扫描该窗口，事务返回最终完成。

首次从单图切入多窗口的整页准备仍使用非活动页，全部窗口写完后一次性切换布局；本次“逐窗 A/B 页选择”只用于已经处于双图或四宫格时的同布局更新。

## RTL 改动范围

- `view_session_manager.v`：移除同布局更新前隐藏窗口的等待阶段；为各窗口保存页选择；失败保留旧页；转场结束后原子提交窗口指针并等待读侧排空。
- `view_video_config.v`、`frame_read_write.v`、`frame_fifo_read.v`、`view_scan_address.v`：把 4 个窗口页选择位跨到视频/内存读侧；扫描地址按窗口槽、局部行和物理页生成。
- `transition_ctrl.v`、`transition_line_read.v`、`transition_blender.v`：支持 320 字窗口行读取、双/四宫格目标槽定位、目标窗专用进度和只混合目标窗口。多窗口转场完成后保持最终新图，直到页指针切换和读侧排空。
- `top_tf_hdmi_audio.v`：连接管理器、帧边界配置、窗口扫描、转场控制器及行读取/混合路径。现有单图转场仍由图像写入事务驱动；多窗口转场由视图管理器驱动。
- `boardtest/vsrc/` 和 `boardtest/Makefile`：补充窗口混合、行地址、页指针、配置跨帧边界、真实转场完成/释放等测试。历史仿真文件保留。

## 已执行的仿真

在 WSL 中执行：

```sh
cd /mnt/c/Users/23506/Desktop/anlogic/boardtest
make view-session view-control-path view-video-config view-framepath view-scan-address view-write-address transition-unit
```

当前工作区已通过以上目标，覆盖：

- 管理器与真实 `transition_ctrl` 的握手，交叉溶解和柔边滑动完成、页指针提交、排空后释放。
- 双图右窗及四宫格目标窗的 320 字行读取、槽基址和底部窗口绝对行标记。
- 双/四宫格目标窗的交叉溶解，以及柔边从左右两个方向推进；非目标窗口不变。
- A/B 页混合扫描、失败后保留旧图、帧边界配置、SDRAM FIFO 排空和写地址边界。
- 原有全屏转场和控制面协议回归。

多窗口转场通过上述 RTL 仿真、TD 综合/布局布线和此前的板级验收。音频跨布局保持的本轮仿真、构建和板级确认记录见下文。

## 多窗口模式切换时保持音频（2026-10-25 已验证）

- 显示板的 `aud_pair_on` 现在直接反映已提交图像是否有 WAV 配对，不再与 `view_active_layout` 相与；进入、离开双图/四宫格不再将 I2S 播放器静音。
- `media_transaction_writer.audio_commit_enable` 仅在 `view_active_layout==0 && view_target_layout==0` 时为 1。单图直显切图时，图像/转场和活动音频源在同一图像提交中更新；无 WAV 时活动配对标志置零，播放器静音。
- writer 另存已提交的音频缓冲指针和配对标志。进入多窗口、窗口内切图、返回单图布局时不改这两个活动值，也不翻转 `audio_source_toggle`。播放器只在 toggle 改变时采样新缓冲元数据，因此布局事务不会重置读地址、样本进度或音源。
- 由于媒体板无需改动，布局进入准备期间媒体仍可能发送其既有音频事务；显示板可将 PCM 写入未播放缓冲，候选元数据可以随图像事务变化，但不会发布为活动音源或打断当前播放。当前多窗口本身没有逐窗口音频选择。
- writer 仿真检查通过：布局型图像提交保持活动音频源和源切换 toggle；后续允许音频更新的无配对单图提交将输出静音。普通/直通时钟、播放器、显示传输及 WAV 配对回归均通过。

### 音频跨布局保持的仿真与板卡构建（2026-10-25）

定向仿真通过：`make VERILATOR='verilator -Wno-fatal' media-writer view-direct-writer media-display-path media-pair-504 media-audio-playback`。其中 writer 仿真验证了活动 WAV 的 committed buffer/pair 状态和源切换 toggle 在布局型图像提交时保持；随后允许音频提交的单图无配对事务会切换到静音。普通/直通 writer、协议显示链路、504×720 SDRAM 配对路径及 PCM 播放器回归均通过。

显示板 RTL 改动包含 `top_tf_hdmi_audio.v`、`media_transaction_writer.v` 和 `media_audio_playback.v`；媒体板源码/bit 未改。显示板综合、布局布线和 bitgen 使用本文件前述 `source {DefaultFlow.tcl}` + `exit` CLI 调用完成。最终资源：LUT 14,810/19,600（75.56%）；slice 8,450/9,800（86.22%）；BRAM9K 35/64；BRAM32K 11/16；DSP 18/29；PLL 4/4。最终 setup WNS −5.858 ns，hold WNS −3.188 ns，仍有时序违例。

本轮初次布局布线在局部路由资源 `(x3y5_local2)` 报 `PHY-8023`，冲突网名为 `transition_ctrl_m0/mux8_syn_2[9]` 与 `transition_line_read_m0/mux16_syn_105`。将音频保持改为仅锁存活动音频 buffer/pair 状态及 source toggle、允许候选元数据更新后，重新综合和布局布线通过。

新显示 bit 位于 `board_display/td_project/lab_ex5_i2s_v1.0_Runs/phy_1/lab_ex5_i2s_v1.0.bit`，SHA-256 `4E9B4AFDB457983581EAB04DF07FE95D5C644785668F842C048539BDE7EF38C9`，生成于 2026-10-25 19:18（本地时间）。以 `scripts/program_sram.ps1 -Board display` 下载到 cable 0，日志为 `boardtest/captures/sram_download/program_display_20261025_191914.log`；TD 输出 `PRG-2014 : Chip validation success`、`program -cable 0 -mode svf -spd 8 -p` 完成和 `finish command "download ..."`。本记录证明 CLI 下载成功；HDMI/音频板级验收待用户确认。
