# 视频接入与功能恢复历史（2026-10-27—28）

本文合并两份视频接入记录，保留初次集成、失败构建、协议和验收证据。原尺寸左上显示、暂关 CV 或后续计划均属于当时阶段；当前已支持 2×全屏视频和六种 CV，见 [全屏视频](../video_fullscreen_optimization_20261030.md)、[完整 CV](../video_statistics_full_cv_20261030.md) 及 [板卡状态](../board_status.md)。

- [最初接入与逐阶段记录](#initial-integration)
- [2026-10-28 核心功能恢复](#feature-restore)

<a id="initial-integration"></a>

## 视频重新接入约定与验收顺序

**本文保留 2026-10-27 起的视频接入历史。2026-10-30 已验收横纵 2×全屏显示，当前版本见 [全屏视频与资源优化](../video_fullscreen_optimization_20261030.md) 和 [资源基线](../board_status.md)。下文的左上角原尺寸显示属于历史阶段。第 9 节的 18:40 构建曾在 A/B 中确认网络失败，不是已验收基线。**

### 1. 本轮确认（2026-10-27）

用户已确认：从 `dual-V3-beta` 接入；首轮以视频功能能够正确验收为目标，其他叠加功能以后逐步打开。

- 产品基线：`dual-V3-beta`，即 `cb2c4c6`。该版本包含多窗口转场、布局切换保持音频、PC 图片上传及相关仲裁修复。
- 开发分支：重新创建的 `feature/direct-video-playback`。main、所有标签和其他分支保持原状；不推送。
- 视频参考：独立仓库 `C:/Users/23506/Desktop/video_display_cleanroom` 的 `ba1f949`。只提取需要的实现，不复制整个顶层或替换产品已有网络栈。
- 原 feature 的 `c615325` 是未完成的实验基线，不作为新功能验收或源码/bit 配套依据。旧分支已删除，同名新分支从稳定标签重建；GC 已清除旧实验提交对象。
- 旧提交补丁、旧工作区、仿真源码及修改清单已核验归档到忽略目录 `boardtest/captures/integration_backup/retired_feature_20261027_160554.zip`。这是排查参考，**不是稳定版本或已验收的源码/bit 配套包**。不得以该归档的候选 bit 冒充新分支构建结果。
- 本次重建没有烧录 FPGA。已有历史仿真保留；归档内有价值的集成测试在实际移植对应模块时恢复并更新。

### 2. 首轮产品范围

PC 选择视频，由现有 Windows FFmpeg 解码，直接通过以太网送显示板。媒体板继续承担既有 SD 图片、WAV 和控制职责，首轮不新增 SD 视频读取。

```text
PC 视频文件
  -> FFmpeg: 640×360 RGB565 + 24 kHz unsigned 8-bit 单声道
  -> 显示板既有 UDP 接收通路
  -> 视频包 CRC / 完整行发布
  -> BRAM 接收页 / SDRAM 行队列 / BRAM 输出缓存
  -> 既有 HDMI 时序与发送器
```

- 640×360 原尺寸显示在左上角，外围黑色；尺寸等于四宫格单窗，不放大；本次只改尺寸参数，
  不代表视频已可与另外三张图片同时布局显示。
- 使用现有 75 MHz、1650×750 的 HDMI 时序，实际帧率 `2000/33 ≈ 60.606 Hz`；音轨每视频帧 396 个原始样本，每样本重复两次进入 48 kHz HDMI 音频通路。
- 首轮为独占视频播放：保存原单图/双图/四宫格状态，播放期间临时接管 HDMI，停止后恢复。
- 不新增视频缩放、局部视频窗口、逐帧转场、拖动进度、SD 视频文件解析或新的视频编码器。

### 3. 与原功能的关系

| 原功能 | 视频期间 | 停止视频后 |
| --- | --- | --- |
| 原图片与多窗口布局 | 保留内容，暂不扫描显示 | 恢复原布局和图片 |
| 已开始的图片/配对音频装载 | 必须先完成，视频等待准入 | 沿用原有完成语义 |
| 新图片装载、N/P、布局切换、PC 图片上传和图像读取事务 | 拒绝或返回忙，不建立等待队列 | 恢复原规则 |
| GT911 切图手势和自动轮播 | 不触发新的图片事务 | 恢复，轮播计时重新开始 |
| 原 WAV 播放 | 暂停并保留当前源、内容和播放进度 | 恢复原源；无配对音频则静音 |
| 视频音轨 | 使用独立的小型 PCM 流接收缓存，复用 HDMI 输出及音量通路 | 清理本次会话，不复用旧样本 |
| 音量、状态查询、停止视频 | 保持可用 | 保持可用 |
| CV、字幕、OSD、频谱、可见光标 | 首轮旁路/隐藏，保留原配置和功能源码 | 恢复原配置 |

前端置灰只提供交互提示，板内仍须执行相同的忙状态规则。不能用 HTTP 成功代替板卡 READY，不能用页面本地状态代替停止和资源释放完成。

原设置接收器与媒体控制入口保留，不因视频接入删除正常功能。原功能恢复和视频首轮验收完成后，再逐项决定并验证视频期间的叠加效果。

### 4. 缓冲和 SDRAM 所有权

采用 cleanroom 已验证的混合行队列，不采用整帧 A/B 写完、提交、再扫描的旧视频方案。

- BRAM 接收页只发布 CRC 正确的完整行。
- SDRAM 提供约 512 行的提前量；后台短突发搬运到 BRAM 输出缓存。HDMI 不等待单次 SDRAM 读取结束。
- 稳态多数视频行仍经过 SDRAM，不能称为完全绕过 SDRAM 的直通架构。
- 优先复用产品现有 SDRAM 控制器和时钟，不新增 PLL。BRAM 头部行数由资源/时序和回归决定，不能未经验证照搬精简实验配置。
- 拟借用**非活动音频缓冲中的约 1 MiB**作为临时行队列；保留图片区和当前已提交 WAV。准入时锁定基址，播放中不随配置变化移动。
- 获得使用权前：等待已有事务完成，在帧边界停原扫描，停止新旧客户端请求，排空在途读返回及写突发，再交出端口。
- 释放前：结束视频内存请求，排空在途突发；在安全帧边界恢复原图扫描和原音频。不得只在组合 mux 上切换地址/数据。
- 视频期间任何可能写入被借用区域的新事务都必须被板内忙规则拦截。

基线地址均为 32-bit 字地址：BUF0=0、BUF1=460800，BUF2=921600、BUF3=1509376。BUF0/1 为图片区，BUF2/3 为音频区；多窗口也可能占用两个图片区，不能把“当前没有显示的图像 bank”当作天然空闲区。

### 5. 协议和会话边界

沿用 cleanroom 已验证的 VD 视频行、VA 反馈与 AD 音频块格式，不另行创造协议。

- VD：12-byte 头，完整 RGB565 行及 CRC16；640 像素时 UDP 应用包长 1294 bytes。
- 行序号为 `(frame_id × 360 + y) mod 65536`。队列内部必须有扩展序号/会话标签，不能只按 16-bit 标签判断有效。
- READY：PC 先发送会话首行，等待匹配的 READY；准入未完成不能推进其余行。重试相同首行不能再次清空已建立的会话。
- CREDIT/NACK：沿用已有提前量和补发规则，避免以平均网速代替逐行截止时间约束。
- AD：8-byte 头、396 个 unsigned PCM 字节、CRC16，共 406 bytes。坏块/缺块静音，不阻塞视频。
- 停止或接收超时必须结束会话、释放 SDRAM 使用权。相同会话编号重新播放也必须清除旧音频有效状态。
- 视频/音频包先分类，AD 原始 PCM 不得进入旧控制帧解析器，避免样本中的偶然字节组合触发命令。

### 6. 分步推进和验收

#### 第一步：准入与退出

先从稳定顶层接入资源使用权状态机、旧 WAV 暂停和控制忙规则。定向仿真覆盖已有事务在途、SDRAM 读返回排空、帧边界交接、停止/超时、重复启动和恢复原状态。此时不扩大媒体板功能。

#### 第二步：视频数据与音轨

移植 cleanroom 的实际数据通路，复用既有 UDP、SDRAM、HDMI。验证真实尺寸逐像素 golden、坏 CRC 不发布、行/帧序号回绕、延迟供数、PCM golden、音频缺块静音、停止后相同编号重播。随后综合、布局布线，检查 LUT、MSlice、两种 BRAM、时钟和实际时序路径。

cleanroom 的约 9.9K LUT 是独立工程占用，不能与产品占用直接相加；共享模块和新增逻辑都要以新分支的完整报告为准。稳定标签所跟踪显示板布局报告为 15,320 LUT、10,149 FF、35 BRAM9K、11 BRAM32K、18 DSP、4 PLL。

#### 第三步：产品界面及板级回归

PC 页面提供选视频、发送、停止、音轨选择和真实状态显示。协议/状态完成后再接 UI，不先用页面动画掩盖硬件状态。

板级必须检查：

1. 640×360 真实视频、正常黑色、连续播放及视频音轨。
2. 从单图、双图、四宫格进入视频，再停止并恢复原布局、图片及原 WAV。
3. 视频期间忙请求正确拒绝；停止后图片切换、PC 图片上传、字幕、CV、OSD、频谱和 GT911 恢复。
4. 网络中断/停止、重复播放、相同会话编号、长时序号回绕。
5. 显示板与媒体板联动控制，不用独立工程的通过结果代替产品通过。

人眼画面、耳听音质/同步与机器 CRC 分别记录；cleanroom 音频自动校验通过不代表已经人工验收音质。

### 7. 构建、下载与提交规则

- 按 `docs/td_cli_programming.md` 使用已有 CLI 脚本：显示板 cable0，媒体板 cable1，仅 SRAM。媒体板无必要改动时不重新综合。
- 构建使用本阶段冻结的源码/工程/配置，保留完整日志；若采用非默认综合参数，必须登记为可复现构建输入，不能只在临时控制台设置。
- 候选源码、bit、报告和测试证据必须配套。中断的构建或旧目录残留 bit 不能用于新版本验收。
- 临时构建/抓包放忽略目录；验证通过的正式 bit/报告随对应源码提交，不能只把唯一成功 bit 放在 captures 中。
- 每阶段只报告实际完成的检查。首轮未通过前不继续恢复叠加效果，不扩展高分辨率、SD 视频或窗口视频。
- 本次清理及约定文档不作为“视频已接入”的功能提交。当前 feature 可开发，main 不改、不合并、不推送。

### 8. 本轮移植与可复现入口

#### 原功能交接

新增 `video_memory_lease`；`view_session_manager` 和 `media_audio_playback` 只增加可选的视频忙状态/暂停入口。已有图像事务不被视频抢断；WATCHDOG 仍只计算原图像事务，不把正常视频播放当作装图超时。

网络新增包边界输出及 VD/AD 分类。音频 PCM 不进入旧控制解析器。另启用 `ISOLATE_VIDEO_PEER=1`：只由普通控制 UDP 更新控制回复来源；VD/AD 和 ARP 不覆盖该来源，PC 的反馈 MAC 单独学习。对应回归在隔离关闭时重现 `VD packet replaced the control response peer`，开启后媒体控制、VD、AD 交错全部通过。

生产配置关闭详细验收计数回包，仍保留包 CRC、内存行校验、READY/CREDIT/NACK。CREDIT 第 7 字节原诊断位之外增加粘滞健康位：bit1 视频缺行、bit2 音频缺块；每次新会话清除。它们提供低成本异常提示，不能代替逐像素或耳听验收。原产品 S、ACK、D 格式不变。

#### 仿真和 PC 回归

```sh
make -C boardtest video-integration-unit
make -C boardtest video-hybrid-integration video-hybrid-raster
make -C boardtest video-hybrid-integration-crc video-hybrid-integration-tag
make -C boardtest video-ready-delay hdmi-symbols display-udp-lite
python -m unittest discover -s scripts -p test_direct_video_sender.py -v
python -m unittest discover -s scripts/web_console -p 'test_*.py' -v
```

Verilator 使用 WSL；Windows 下 UDP 回环测试需使用正常用户进程，普通沙箱可能使回包不可达，不因此修改防火墙。原 `test_console_protocol.py`、`test_subtitle.py`、`test_media_snapshot.py`、`test_media_upload.py`、`test_view_status.py`、`test_stream.py` 还各有独立脚本入口，应另行执行，不能把 unittest discovery 当作这些脚本也已经运行。

#### 构建配置

```powershell
.\scripts\build_display_video.ps1
python scripts/check_video_build.py
.\scripts\program_sram.ps1 -Board display
```

构建脚本先完整综合，再布局布线；校验构建期间源码/工程/配置没有变化，成功后写入 `board_display/td_project/video_build_manifest.json`。下载仍使用既有脚本和 cable0 SRAM。

本轮综合策略为 `gate opt_area high`、`gate pack_effort high`、`gate map_mode area_prior`；布局为 `place pr_strategy 2`、`place effort high`、`place seed 2`，布线 effort 保持 `normal`。策略已用 TD 官方工程管理接口写入 `.al`，并由脚本同步至运行目录的 `settings.cfg`，不依赖临时交互会话：

```tcl
open_project {C:/Users/23506/Desktop/anlogic/board_display/td_project/lab_ex5_i2s_v1.0.al}
set_param gate opt_area high -run syn_1 -projmngr
set_param gate pack_effort high -run syn_1 -projmngr
set_param gate map_mode area_prior -run syn_1 -projmngr
set_param place pr_strategy 2 -run phy_1 -projmngr
set_param place effort high -run phy_1 -projmngr
set_param place seed 2 -run phy_1 -projmngr
close_project
```

命令依据为本机 CLI 的 `set_param ... -run ... -projmngr` 以及 SDK `DefaultFlow.tcl` 的 `synWildParams/phyWildParams`。`route effort high` 在本机工程管理接口会被警告并改回 `normal`，不能将其记作有效优化。最初默认布局候选虽通过容量检查，仍因 3 处布线冲突失败；该候选没有烧录，不能用残留 bit 交付。

#### 板级自动检查

```powershell
python scripts/direct_video_product_probe.py --input C:/path/video.mp4 --audio --frames 1800 --upload-still
```

该脚本使用普通图片事务建立测试图片，检查视频 READY、实际反馈推进、忙时 PREPARE 拒绝、停止释放及原布局/图片索引/尺寸恢复；输出证据在忽略目录。它不读取 HDMI 实际像素，也不证明耳听效果，报告明确保留人工观察项。`--upload-still` 会替换当前焦点窗口内容，需要保留现有图像时不要传该参数。产品运行不依赖 cleanroom 的目录；视频输入必须显式提供路径。

`--layout 0/1/2` 还可让 PC 按原媒体事务创建单图、双图或四宫格测试页，再检查视频播放及恢复；该选项会替换图片。双图和四宫格之间仍先经过单图，不绕过产品规则。播放期间测试脚本还会查询设置、改变并恢复音量，核查 ACK 没有被 VD/AD 路由抢走。

### 9. 接入候选构建现场（2026-10-27）

本轮完整构建入口为 `build_display_video.ps1`；成功日志目录
`boardtest/captures/video_integration/build_20261027_182618/`。正式工程路径中的 bit、
报告与 `video_build_manifest.json` 已生成，`check_video_build.py` 配套核验通过。

| 项目 | dual-V3-beta 布局报告 | 当前候选布局报告 |
| --- | ---: | ---: |
| LUT | 15,320 | 18,259 |
| FF | 10,149 | 12,479 |
| BRAM9K | 35 | 49 |
| BRAM32K | 11 | 13 |
| DSP | 18 | 18 |
| PLL | 4 | 4 |

当前 setup WNS 为 −7.064 ns、hold WNS 为 −2.935 ns；**未完成时序收敛**。
最差 setup 路径位于原有图片缩小链路，`u_geometry/dest_height` 到 `u_shrink/state`，
125 MHz 域数据路径约 14.784 ns、15 层逻辑。不能将全部违例归因于异步 CDC，
也不能通过放宽全局约束来宣称通过。现有 SDC 未作此类改动。

为帮助布线，本轮仅对新增视频通路做了等价精简：完整 64-bit 标签暂存复用；
四行头缓冲利用已分配 BRAM 的空余空间改为每行 512 字行距；原生突发按已验证的
256 字列边界使用低 8-bit 地址增量。未减小 512 行提前量、4 行头缓存或 4 页接收容量。
两个真实音频区基址的逐拍地址检查、CRC/标签故障、延迟 READY 和经过产品 CV 旁路的
三帧 2,764,800 像素 golden 均通过。媒体板文件与稳定标签没有差异。

18:43 下载失败：系统没有在线 Anlogic USB 下载器，只剩 `Unknown` 历史记录，
见 `td_cli_programming.md` 对应现场。因此该候选尚无产品实板通过记录，不能提交为
已上板基线；待 USB 恢复后先下载本候选并执行板级回归，勿先改动冻结的 RTL。

### 10. 网络回归现场与诊断候选（恢复上下文先读）

用户重新上电后，原脚本于 19:44 将 18:40 候选成功下载到显示板 cable0 SRAM，
无 UAC，日志 `program_display_20261027_194406.log`。但 PC 原图片入口 `0x20` 无回包，
直接 VD 首行的 READY 也超时。没有进入真实视频播放，不能称视频已通过。

受控 A/B：

1. 19:51 从 `dual-V3-beta` 直接提取其已跟踪显示板 bit 下载，未切分支、未改源码。
   同一 PC `.1`、显示板 `.2`、同一接线，立即收到 `aabbccdd2000010001`。
2. 19:54 重新下载同一个 18:40 视频候选，重复请求 15 秒，仍零回复。
3. 因此确认候选引入网络回归。不能继续归因于下载权限、初始化等待或 PC 连接。
   稳定回放副本只用于 A/B；它的源码与正式 bit 始终保存在稳定标签中。

相关证据在 `boardtest/captures/video_integration/stable_replay/`、
`candidate_ready_replay.json`、`ready_only.json`。受控 50 次请求的网卡增量为发送组播帧
50、接收与错误计数均零。产品沿用历史 `01:23:45:67:89:ab`，故这些发送在网卡计数中
属于组播；稳定 bit 用相同地址也能回复，不能据此断言 MAC 地址就是本轮根因。

新增完整连接测试 `video-network-bridge`：实际 UDP -> demux -> media_protocol_rx ->
media_display_tx -> 控制/视频反馈 mux -> UDP Ethernet，普通 READY 及交错反馈全部通过。
这排除了测试所覆盖的理想时钟逻辑错误，不排除物理时序或复位问题。

对照 cleanroom 后补齐其已验证的 RX IP 校验精简：累加器 32 -> 20 bits；
末字校验由两次 carry-fold 改为等价布尔式。`video-ipv4-sum` 穷举十个 16-bit IPv4
字的全部 655,351 种可能累加值，与原算法完全一致。上述完整连接测试及 UDP 媒体/PC
交错回归也已重新通过。尚未以实板证明这项精简修好了本轮网络，不能提前写成根因修复。

#### 当前正在构建的完整功能诊断版

- 构建目录 `boardtest/captures/video_integration/build_20261027_201648/`。
- 临时 `VIDEO_LINK_DIAGNOSTICS=1`，只将原数码管改成下述稳定阶段标记，不裁剪 CV、
  音频或其他模块；不增加外部引脚。正常产品验收前恢复为 0 并重新构建/下载/验证。
- `eth_subsys.link_trace` 提供 MAC 客户端 RX/TX、MAC 坏帧粘滞标志和网络复位状态。
- 前缀保持 `2D`，其后四个 HEX 位依次为 `P M XY`：

| 字段 | 含义 |
| --- | --- |
| P bit3..0 | SYS PLL锁定、VIDEO PLL锁定、rst_all、网络reset；健康空闲通常为 C |
| M bit3..0 | SDRAM初始化、video_request、memory_grant、video_ready；无视频时通常为 8 |
| XY bit0 | 曾收到 MAC 客户端有效字节 |
| XY bit1 | 曾收到有效 UDP 应用字节 |
| XY bit2 | 曾将普通数据送到旧应用解析器 |
| XY bit3 | 曾生成旧图片 READY 请求 |
| XY bit4 | 普通控制发送器曾获得 UDP ACK |
| XY bit5 | 曾向 MAC 客户端发送字节 |
| XY bit6 | MAC 曾报告坏帧 |

XY 是只置位的阶段标志，不是高速计数；普通请求完整走通时通常为 `3F`，例如
`2DC83F`。标志随应用复位清除，旧启动看门狗仍可能在未显示图片时产生有限次复位。
用户反馈候选画面黑，显示器未明确提示无信号，不能据此确定 PLL/复位故障；下一步以
上述稳定阶段码继续定位，不再反复要求用户拔插 HDMI。

当前分支仍为新 `feature/direct-video-playback`，HEAD 与 main 仍在 `cb2c4c6`，未提交。
**索引暂存的是此前 18:40 失败候选；工作区已继续修改，不能直接提交旧索引。**
下一版完成后先检查 `check_video_build.py`，确认 profile 中 `link_diagnostics=1`，
再下载读取阶段码、复测普通 `0x20`，随后才测试视频。最后必须回到诊断关闭的正常版，
按用户“布局布线和板测均通过才提交基线”的要求重新暂存最新版。

### 12. 首轮 capability 缩减和更新的诊断（2026-10-27）

用户确认首轮综合暂时关闭 CV 和频谱，源码、仿真、图片/布局/音频/字幕/OSD/触摸保留；
前端将 CV/频谱选项置灰，FPGA 拒绝直接通过 USB、蓝牙或 UDP 发来的启用命令。
原图及关闭频谱、亮度、对比度、音量等命令仍走旧 ACK/状态协议。`scripts/direct_video_profile.json`
与顶层两个参数一致，构建脚本会在综合前校验这项能力约定。

21:13 之前已下载的第一版阶段码字节含义是：`2D` 固定标记、`C` 表示 PLL/复位、`8`
表示 SDRAM 就绪且暂无视频租约、`3F` 表示七个 Ethernet/应用发送阶段均曾发生。
用户实读 `2DC83F`。随后定位到该码不能区分 IP 头校验失败；当前源代码新增第八个粘滞位，
XY 的 bit7 表示 IPv4/UDP 头字段/校验曾失败，工作区源/仿真测试已更新，**21:13 旧 bit
不包含这个位，不能按新版码表解读**。

稳定标签的 A/B 对照已完成：稳定 bit 收到 0x20 READY 并成功提交渐变图，候选 bit 对
相同请求无回包。完整 UDP/demux/旧控制响应路径仿真通过；改变幅度和耗时均受控的更新
诊断候选仍在重新综合/布局布线。当前阶段没有可上板验收的新版 bit。

近期资源快照对应 CV/频谱仍开启的 area 策略诊断候选，不可当作当前精简版数据：

| 候选 | gate LUT | place LUT | BRAM9K | BRAM32K | setup WNS | hold WNS | 结果 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 完整功能 area 策略 A/B 候选 | 18,171 | 18,166 | 49 | 13 | −5.770 ns | −2.935 ns | 有三处布线冲突；没有烧录 |

该候选的三个局部布线冲突不等于已经通过完整布局布线。当前应以最新诊断构建日志和
实际下载记录为准，不复用这些数字描述新的首轮 bit。

媒体板源码/bit 与 `dual-V3-beta` 完全一致；目前只枚举到一个 Anlogic USB 下载器，
没有尝试不存在的 cable1。cleanroom `ba1f949` 保留且未改，不在产品程序中引用其目录；
本次测试 MP4 路径仅作为外部输入样本。PLL频率、引脚、网络全局配置和主 SDC 均未改。

### 13. 首行租约门控修复与实际 MP4 验收（2026-10-28）

#### 根因和 RTL 修复

实板诊断证据显示 PC 状态请求可正常收发，但视频首行没有 READY。定位到顶层原条件：
`video_row_commit && video_row_stream_start && video_row_index == 0`。解析器在有效行头结束时
先脉冲 `video_row_stream_start`，而 `video_row_commit` 要等完整行及 CRC 收到后才脉冲，两者相隔
整行数据，不会同周期为真，显示板因此从未向 SDRAM lease 请求器申请视频租约。

新增 `direct_video_session_gate`：按首行 frame ID 暂存 start 意图，在同一 frame 的 row 0
通过 CRC 并 commit 后才发单周期 lease request；首行 CRC 被拒绝时清除待定请求，坏帧不能
独占 SDRAM。`tb_direct_video_row_parser` 将实际 parser 与 gate 串接，覆盖头部先到/CRC 提交晚到
以及坏 CRC 两条路径。定向 Verilator 测试通过。

另将 `view_session_manager.external_busy` 接为 `video_request || video_stream_active`，确保
视频会话启动后的状态仍报告 busy；结束后随实际会话释放。busy 状态轮询需容忍异步状态发布延迟，
产品探针现在等到板卡状态确认 busy 后才继续，并非只采第一份可能过期的状态快照。

#### 板级与数字验收

- 显示板 area build 使用本节修复版，cable0 SRAM 下载完整成功；媒体板没有重烧或改动。
- 内部彩条连续 180 帧通过：64,800 行，0 跳行、0 NACK 缺缓存、`video_missing=false`。
- 实际 MP4 连续 180 帧通过：64,800 行，0 跳行、`video_missing=false`；产品探针确认匹配 READY、
  busy=1、忙时 PREPARE 返回拒绝、音量设置 ACK、视频结束 busy=0，原布局及图像元数据不变。
- 同一 MP4 含 48 kHz AAC 立体声音轨；转为 24 kHz unsigned 8-bit mono 后发送 180 个音频块，
  `audio_missing=false`，视频仍 0 跳行、`video_missing=false`。
- 用户确认最终无诊断 bit 上的实际 MP4 画面持续稳定、音频正常。自动探针本身不采 HDMI
  像素也不评判耳听音质；此项由用户肉眼/听感确认。
- Flask `/api/eth/video/start` 实际上传 MP4 并启动 sender：默认 16 帧解码预取，收到 READY，
  213 帧/76,799 行、0 跳行、`video_missing=false`；随后 `/api/eth/video/stop` 使页面状态回到 stopped。

#### PC 解码预取和回归

实测同一 MP4、180 帧：无预取时跳过 508 行；4 帧预取跳过 116 行；16 帧预取为 0 行、
`video_missing=false`。内部彩条 180 帧同样为 0 跳行，证明这轮丢行来自 PC 解码/发送调度，
不是 FPGA 入站链路。网页默认使用 `--prefetch 16`，仅增加 PC 侧有界内存（最大 720×360 RGB565
约 8 MiB）；`VIDEO_PREFETCH` 可设为 0–16 做诊断。两帧 loopback API 夹具显式用预取 0，独立
覆盖网络包和 ACK；另有真实 endpoint 测试使用产品默认预取 16。

验证记录：`boardtest/captures/video_integration/final_clean_bit_product_probe.json`、
`final_clean_bit_product_probe_audio.json`、
`pattern_180_frames.json`、`mp4_prefetch4_180_frames.json`、
`mp4_prefetch16_180_frames.json` 及 `web_api_live/result.json`（本机忽略目录）。
Verilator `direct-video-parser`、`video-ready-delay`、`video-product-chain`、
`video-network-bridge` 通过；Python sender 29 项、Web/API 9 项通过。loopback/API 测试
必须在普通用户可访问本机网络的运行环境执行；受限沙箱的本地 UDP 包无法送达，不能据此判断 RTL。

#### 当前诊断码和交付状态

复核用 bit 保留 diagnostics。前缀 `2D` 后是 `P M XY`：P 继续表示 PLL/reset；M 现在是实时
`{SDRAM ready, video_request, memory_grant, session_active}`；XY 八个粘滞位依次为 MAC RX、
UDP payload、VD demux、首行 CRC commit、视频 READY 事件、MAC TX valid、MAC/IP 接收错误、
MAC TX 完成。用户读到 `2DC8BF` 时，XY 显示首行 commit/READY 和 TX 均发生且没有接收错误；
M 为 C8 是在有限时长探针停止后读取的空闲状态，不代表正在播放时 lease 未申请。

#### 最终无诊断构建

最终产品构建已将 `VIDEO_LINK_DIAGNOSTICS=0`；诊断 RTL、阶段标记和对应仿真全部保留，
但不会进入正式 bit。构建新鲜度脚本通过，显示板 cable0 SRAM 下载成功。最终布局报告：

| 项目 | 最终 area build |
| --- | ---: |
| LUT | 16,358 / 19,600（83.46%） |
| FF | 11,641 / 19,600（59.39%） |
| BRAM9K | 46 / 64 |
| BRAM32K | 8 / 16 |
| DSP | 16 / 29 |
| PLL | 4 / 4 |
| Slices | 8,736 / 9,800（89.14%） |
| Setup WNS | −6.465 ns |
| Hold WNS | −3.056 ns |

最终 bit 的正式 SRAM 下载日志为 `boardtest/captures/sram_download/program_display_20261028_012607.log`。
无诊断配置下，实际 MP4 180 帧（含音轨）产品探针和 Flask 实际上传入口均通过；用户确认最终
HDMI 画面持续稳定、音频正常。此次验证只烧录显示板，媒体板源码/bit 未改。当前主机工作仍在
`feature/direct-video-playback`；正式 bit、RTL、项目配置、报告、manifest、测试及文档均已核对为
同一无诊断构建，待本轮最终暂存审查后提交。

#### 早期历史诊断记录（后续根因与验收见第 13 节）

显示板上 `dual-V3-beta` 收到普通图片 READY 并提交了 320×180 渐变图，HDMI 确认有画面。
再烧入阶段诊断候选后，PC 普通 0x20 与视频 READY 都无回复。其 7 个阶段位读为 `3F`：
以太网 MAC 字节、UDP 字节、旧应用解析、READY 请求、控制发送 grant、MAC TX 客户端
valid 均到达；MAC 报告位也曾置位。CRC/IP 校验综合精简及完整连接理想时钟仿真通过，
仍未能由物理状态码确定板上没回复的具体位置。

为细分接收阶段，早期诊断版曾增加 IPv4/UDP 头校验错误粘滞标志。该阶段用户读数
`2DC83F` 来自更早的 7 阶段布局；其后曾读到 `2DC800` 和 `2DC8B7`，含义随诊断映射版本变化，
不能交叉套用。它们都属于诊断过程中的历史读数；首行同周期门控根因、修复版 READY 和最终
无诊断构建的验收，以第 13 节记录为准。

### 14. 视频尺寸改为四宫格单窗（2026-10-28）

用户更正首版视频源尺寸应为多窗口四宫格单窗尺寸 **640×360**。本阶段只调整尺寸参数，
仍由现有独占视频模式在左上 640×360 画面区显示，外围黑色；尚不实现与另外三窗图片同时合成。

更新项：显示顶层、视频区域 mux、行解析器、hybrid pipeline/head/ingress 默认宽度和 PC profile
统一为 640；Windows 前端默认 640×360，产品构建脚本会校验 profile 与 RTL 宽高一致，并将实际
参数写入构建 manifest。协议头、序号规则、高度 360、窗口缓冲、音频格式和 SDRAM 租约不变。
一行 UDP 应用包由 1454 bytes 降为 **1294 bytes**，其他显示布局和帧缓冲行为未改。

640×360 seed2 area bit 虽通过布局布线、PLL 锁定并能正常 UDP 收发，但在板上没有 HDMI 信号；
已恢复到原 720×360 基线。保持相同 640×360 RTL/profile、将 area placement seed 改为 3 后，
诊断版 HDMI 恢复；最终将 diagnostics 关闭并以 seed3 重新综合/布局布线，最终 bit 已烧录至
显示板 cable0。seed2/seed3 的实板差异说明本次输出异常与该网表的物理实现有关；本轮采用
经过实测的 seed3 构建作为 640×360 参数基线。

最终 seed3 无诊断资源：16,294 LUT、11,664 FF、BRAM9K 46/64、BRAM32K 8/16、DSP 16/29、
PLL 4/4、Slices 8,697/9,800；setup WNS −6.247 ns，hold WNS −2.935 ns。构建清单核对通过，
SRAM 下载日志为 `boardtest/captures/sram_download/program_display_20261028_025719.log`。

最终 640×360 实际 MP4+AAC 产品探针通过：180 帧、64,800 行、180 音频块，0 跳行，视频/音频
缺失标志均为 false；忙时布局请求拒绝、音量 ACK 和停止后元数据恢复均通过。连续 640×360
播放时用户确认区域正好在左上四宫格单窗大小，画面和音频正常；本次仍只实现单视频窗口/独占
播放模式，多窗口混合布局尚未实现。

<a id="feature-restore"></a>

## 视频接入与核心功能恢复记录（2026-10-28）

本文记录当时的功能恢复。2026-10-30 后续版本已将视频按 2×最近邻放大全屏，并精简视频缓存路径、保护多窗口返回单图的读写交接，见 [最新实现与验收](../video_fullscreen_optimization_20261030.md)；当前资源以 [板卡状态](../board_status.md) 为准，下文资源和左上原尺寸显示均为历史记录。

### 当前状态与基线

本记录对应 `feature/direct-video-playback` 分支、提交 `7afa04d` 之后的工作区候选。产品来源是 `dual-V3-beta`，视频参考实现来自 cleanroom，但本仓库的板级 RTL、控制仲裁和资源配置均按双板产品工程接入。显示板和媒体板的当前正式构建及其输入源码清单分别保存在：

- `board_display/td_project/video_build_manifest.json`
- `board_media/td_project/media_build_manifest.json`

综合和布局布线生成的 bit 与报告随工程目录保存。显示板本轮布局布线使用 seed 7；媒体板使用 seed 3。应以 manifest 中的工程配置、源码清单和构建时间确认 bit 与 RTL 对应关系，不要把临时诊断 bit 当作产品构建。

### 本轮产品功能

#### PC 视频播放

- App 选择 MP4 后，由 PC 上的 FFmpeg 解码为 `640×360 RGB565` 视频帧和 `24 kHz / unsigned 8-bit / mono` PCM 音频，再通过 UDP 发送给显示板。
- 视频是 HDMI 独占内容，按 640×360 在左上区域显示，其余显示区域保持黑色。视频行缓冲使用 BRAM，配合 SDRAM 行读写与显示时钟域中的行缓存；它不是逐帧存储到 SDRAM 的普通图片播放方式。
- 视频按行发送，接收端通过会话 READY、信用反馈及帧/行校验协调发送与消费。自然播放结束或用户停止后，PC 等待显示板确认视频会话已释放，之后才将控制界面恢复为空闲。
- 多窗口、SD 图片/WAV、控制和 OSD 等既有数据通路继续存在。视频播放期间与 HDMI/SDRAM 所有权冲突的图像事务由板卡忙状态拒绝；停止或自然结束后恢复视频开始前的图片布局与音频。
- 视频尺寸为 `640×360`，与四宫格窗口一致。MP4 本身按比例缩放并补黑，不拉伸。

#### 既有功能及资源配置

- 恢复显示板 CV 与频谱的综合配置。当前启用原图、灰度、二值化、雪花，以及频谱；**Sobel 梯度和锐化暂时关闭**，这是为通过资源和布局布线而经用户确认的折中，不代表这两个效果已经恢复。
- 字幕、OSD、GT911 光标/触控、多窗口、转场、SD 图片和 WAV 播放、PC 图片上传及现有控制入口保留。
- App 根据产品 profile 隐藏当前不可用的 Sobel/锐化选项；无视频功能的控制仍按板卡 ACK/忙状态更新。
- 媒体板 `media_view_scheduler` 增加忙状态期间的周期状态查询：若 UDP 的视图空闲通知丢失，媒体板会重新向显示板确认租约状态，避免控制端永久停留在忙状态。

### 综合与布局布线资源

报告对应当前产品配置，不包含 Sobel/锐化卷积通路：

| 板卡 | 综合 LUT | 布局布线 LUT | FF/Reg | BRAM9K | BRAM32K | DSP | PLL |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 显示板 | 16,544 / 19,600 | 17,501 / 19,600 | 12,329 / 19,600 | 49 / 64 | 10 / 16 | 18 / 29 | 4 / 4 |
| 媒体板 | — | 14,061 / 19,600 | 8,881 / 19,600 | 19 / 64 | 2 / 16 | 5 / 29 | — |

显示板布局布线的资源膨胀后 LUT 使用率约 89.29%，剩余约 2,099 LUT；综合阶段的 16,544 LUT 不能代替最终布局布线占用。媒体板约 5,539 LUT 的名义余量也不等于所有余量都能安全用于逻辑，仍需考虑布线和时序。

显示板相关时序基线记录在 `board_display/td_project/lab_ex5_i2s_v1.0_Runs/phy_1/final_timing.rpt`；最终报告的最差 setup/hold 结果应直接以该文件和当前 manifest 对应的构建为准。本轮没有把“资源低于 17,000 LUT”作为已达成结果。

### 已完成的自动与板级验证

本轮验证覆盖当前功能配置；Sobel/锐化因显式关闭而不在通过范围内。

- CV 像素流水线和关闭卷积后的点处理模式仿真通过；CV 能力测试确认原图、灰度、二值化、雪花可选，Sobel/锐化会被拒绝。
- 双线性缩小边界、图像/媒体协议路径、音频播放和 PC 视频音频行桥接回归通过。
- Python 视频发送器、App 视频控制和图像上传 API 测试通过；覆盖 MP4 有音轨、无音轨/静音收尾、自然播放完成、显式停止以及视图忙状态释放。
- 通过 Flask API 上传 8×8 与 1280×720 PC 图片，显示板均返回完成结果；D 快照读回 460,800 字，序号缺口为 0。
- 媒体板 SD 图片启动与上一张/下一张事务完成，视图状态回报的布局、索引和有效窗口掩码正确。
- PC 视频自动化探针分别在单图、双图、四宫格场景覆盖 READY、播放忙拒绝、音量控制和停止后的原布局恢复；自然结束的 App 发送器测试持续到完整文件尾并释放显示板会话。
- API 控制回归覆盖图像效果、频谱、OSD、转场、音量、亮度、对比度、轮播周期、自动轮播与上一张/下一张 ACK；不可用的 Sobel/锐化返回明确拒绝。
- 用户对当前两板版本进行了 App/板级测试，反馈“基本没问题”。本记录不把未逐项人工确认的画面和声音细节写成全部通过。

### 本轮改动重点

1. 在保留视频行缓存和现有 HDL 模块的前提下，将可路由资源折中限定为关闭 Sobel/锐化；频谱及其他点处理效果保持启用。
2. 调整显示板 UDP 响应 MAC 的选择逻辑，复用已判定的目的路由，避免重新对目的 IP 做级联比较，改善关键发送路径的时序压力。
3. 补齐 PC 视频结束后的释放确认；发送器自然结束不再仅凭 PC 进程退出就向前端报告空闲。
4. 修正频谱灵敏度 ACK 显示映射，并将能力信息接入 App 控件，避免界面显示可选但 FPGA 拒绝的设置。
5. 媒体板在视图事务忙时重试状态查询，以恢复丢失的 UDP 空闲事件。
6. 补充对应仿真、构建清单与正式 bit/报告；失败的自定义显示发送 FIFO 仅留在仿真目录作为实验，不进入 TD 产品源文件列表。

### 后续架构评估边界

- PC 静态图片仍使用显示板的图片事务接收和 SDRAM 写入通路；这与媒体板从 SD 发送的图片共享显示端接收逻辑。仅把 PC 发包目标改为媒体板、再原样转发，不会消除显示板的图片解析/存储路径。
- PC 视频目前直达显示板。若改由媒体板转发，显示板仍需保留视频行解析、信用反馈和显示缓冲；媒体板需增加高吞吐接收、转发、反馈路由和仲裁。因此转发本身不能视为显示板的大幅减负。
- 更有直接资源收益的候选是把频谱 DFT 放到媒体板，并让 SD WAV 与 PC 音频样本都经过媒体板，再把频谱结果回送显示板。这样有机会释放显示板 DFT 的 LUT/BRAM/DSP，但需要新增频谱结果协议，并核算媒体板的时序、存储和双向以太网负载。
- 这些架构项是评估结论，不包含在本轮 RTL 实现中。
