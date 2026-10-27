# 视频重新接入约定与验收顺序

**当前进度见第 10 节。第 9 节的 18:40 构建已在 A/B 中确认网络失败，不是已验收基线。**

## 1. 本轮确认（2026-10-27）

用户已确认：从 `dual-V3-beta` 接入；首轮以视频功能能够正确验收为目标，其他叠加功能以后逐步打开。

- 产品基线：`dual-V3-beta`，即 `cb2c4c6`。该版本包含多窗口转场、布局切换保持音频、PC 图片上传及相关仲裁修复。
- 开发分支：重新创建的 `feature/direct-video-playback`。main、所有标签和其他分支保持原状；不推送。
- 视频参考：独立仓库 `C:/Users/23506/Desktop/video_display_cleanroom` 的 `ba1f949`。只提取需要的实现，不复制整个顶层或替换产品已有网络栈。
- 原 feature 的 `c615325` 是未完成的实验基线，不作为新功能验收或源码/bit 配套依据。旧分支已删除，同名新分支从稳定标签重建；GC 已清除旧实验提交对象。
- 旧提交补丁、旧工作区、仿真源码及修改清单已核验归档到忽略目录 `boardtest/captures/integration_backup/retired_feature_20261027_160554.zip`。这是排查参考，**不是稳定版本或已验收的源码/bit 配套包**。不得以该归档的候选 bit 冒充新分支构建结果。
- 本次重建没有烧录 FPGA。已有历史仿真保留；归档内有价值的集成测试在实际移植对应模块时恢复并更新。

## 2. 首轮产品范围

PC 选择视频，由现有 Windows FFmpeg 解码，直接通过以太网送显示板。媒体板继续承担既有 SD 图片、WAV 和控制职责，首轮不新增 SD 视频读取。

```text
PC 视频文件
  -> FFmpeg: 720×360 RGB565 + 24 kHz unsigned 8-bit 单声道
  -> 显示板既有 UDP 接收通路
  -> 视频包 CRC / 完整行发布
  -> BRAM 接收页 / SDRAM 行队列 / BRAM 输出缓存
  -> 既有 HDMI 时序与发送器
```

- 720×360 原尺寸显示在左上角，外围黑色；不放大，不合成到多窗口中的某一个窗口。
- 使用现有 75 MHz、1650×750 的 HDMI 时序，实际帧率 `2000/33 ≈ 60.606 Hz`；音轨每视频帧 396 个原始样本，每样本重复两次进入 48 kHz HDMI 音频通路。
- 首轮为独占视频播放：保存原单图/双图/四宫格状态，播放期间临时接管 HDMI，停止后恢复。
- 不新增视频缩放、局部视频窗口、逐帧转场、拖动进度、SD 视频文件解析或新的视频编码器。

## 3. 与原功能的关系

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

## 4. 缓冲和 SDRAM 所有权

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

## 5. 协议和会话边界

沿用 cleanroom 已验证的 VD 视频行、VA 反馈与 AD 音频块格式，不另行创造协议。

- VD：12-byte 头，完整 RGB565 行及 CRC16；720 像素时 UDP 应用包长 1454 bytes。
- 行序号为 `(frame_id × 360 + y) mod 65536`。队列内部必须有扩展序号/会话标签，不能只按 16-bit 标签判断有效。
- READY：PC 先发送会话首行，等待匹配的 READY；准入未完成不能推进其余行。重试相同首行不能再次清空已建立的会话。
- CREDIT/NACK：沿用已有提前量和补发规则，避免以平均网速代替逐行截止时间约束。
- AD：8-byte 头、396 个 unsigned PCM 字节、CRC16，共 406 bytes。坏块/缺块静音，不阻塞视频。
- 停止或接收超时必须结束会话、释放 SDRAM 使用权。相同会话编号重新播放也必须清除旧音频有效状态。
- 视频/音频包先分类，AD 原始 PCM 不得进入旧控制帧解析器，避免样本中的偶然字节组合触发命令。

## 6. 分步推进和验收

### 第一步：准入与退出

先从稳定顶层接入资源使用权状态机、旧 WAV 暂停和控制忙规则。定向仿真覆盖已有事务在途、SDRAM 读返回排空、帧边界交接、停止/超时、重复启动和恢复原状态。此时不扩大媒体板功能。

### 第二步：视频数据与音轨

移植 cleanroom 的实际数据通路，复用既有 UDP、SDRAM、HDMI。验证真实尺寸逐像素 golden、坏 CRC 不发布、行/帧序号回绕、延迟供数、PCM golden、音频缺块静音、停止后相同编号重播。随后综合、布局布线，检查 LUT、MSlice、两种 BRAM、时钟和实际时序路径。

cleanroom 的约 9.9K LUT 是独立工程占用，不能与产品占用直接相加；共享模块和新增逻辑都要以新分支的完整报告为准。稳定标签所跟踪显示板布局报告为 15,320 LUT、10,149 FF、35 BRAM9K、11 BRAM32K、18 DSP、4 PLL。

### 第三步：产品界面及板级回归

PC 页面提供选视频、发送、停止、音轨选择和真实状态显示。协议/状态完成后再接 UI，不先用页面动画掩盖硬件状态。

板级必须检查：

1. 720×360 真实视频、正常黑色、连续播放及视频音轨。
2. 从单图、双图、四宫格进入视频，再停止并恢复原布局、图片及原 WAV。
3. 视频期间忙请求正确拒绝；停止后图片切换、PC 图片上传、字幕、CV、OSD、频谱和 GT911 恢复。
4. 网络中断/停止、重复播放、相同会话编号、长时序号回绕。
5. 显示板与媒体板联动控制，不用独立工程的通过结果代替产品通过。

人眼画面、耳听音质/同步与机器 CRC 分别记录；cleanroom 音频自动校验通过不代表已经人工验收音质。

## 7. 构建、下载与提交规则

- 按 `docs/td_cli_programming.md` 使用已有 CLI 脚本：显示板 cable0，媒体板 cable1，仅 SRAM。媒体板无必要改动时不重新综合。
- 构建使用本阶段冻结的源码/工程/配置，保留完整日志；若采用非默认综合参数，必须登记为可复现构建输入，不能只在临时控制台设置。
- 候选源码、bit、报告和测试证据必须配套。中断的构建或旧目录残留 bit 不能用于新版本验收。
- 临时构建/抓包放忽略目录；验证通过的正式 bit/报告随对应源码提交，不能只把唯一成功 bit 放在 captures 中。
- 每阶段只报告实际完成的检查。首轮未通过前不继续恢复叠加效果，不扩展高分辨率、SD 视频或窗口视频。
- 本次清理及约定文档不作为“视频已接入”的功能提交。当前 feature 可开发，main 不改、不合并、不推送。

## 8. 本轮移植与可复现入口

### 原功能交接

新增 `video_memory_lease`；`view_session_manager` 和 `media_audio_playback` 只增加可选的视频忙状态/暂停入口。已有图像事务不被视频抢断；WATCHDOG 仍只计算原图像事务，不把正常视频播放当作装图超时。

网络新增包边界输出及 VD/AD 分类。音频 PCM 不进入旧控制解析器。另启用 `ISOLATE_VIDEO_PEER=1`：只由普通控制 UDP 更新控制回复来源；VD/AD 和 ARP 不覆盖该来源，PC 的反馈 MAC 单独学习。对应回归在隔离关闭时重现 `VD packet replaced the control response peer`，开启后媒体控制、VD、AD 交错全部通过。

生产配置关闭详细验收计数回包，仍保留包 CRC、内存行校验、READY/CREDIT/NACK。CREDIT 第 7 字节原诊断位之外增加粘滞健康位：bit1 视频缺行、bit2 音频缺块；每次新会话清除。它们提供低成本异常提示，不能代替逐像素或耳听验收。原产品 S、ACK、D 格式不变。

### 仿真和 PC 回归

```sh
make -C boardtest video-integration-unit
make -C boardtest video-hybrid-integration video-hybrid-raster
make -C boardtest video-hybrid-integration-crc video-hybrid-integration-tag
make -C boardtest video-ready-delay hdmi-symbols display-udp-lite
python -m unittest discover -s scripts -p test_direct_video_sender.py -v
python -m unittest discover -s scripts/web_console -p 'test_*.py' -v
```

Verilator 使用 WSL；Windows 下 UDP 回环测试需使用正常用户进程，普通沙箱可能使回包不可达，不因此修改防火墙。原 `test_console_protocol.py`、`test_subtitle.py`、`test_media_snapshot.py`、`test_media_upload.py`、`test_view_status.py`、`test_stream.py` 还各有独立脚本入口，应另行执行，不能把 unittest discovery 当作这些脚本也已经运行。

### 构建配置

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

### 板级自动检查

```powershell
python scripts/direct_video_product_probe.py --input C:/path/video.mp4 --audio --frames 1800 --upload-still
```

该脚本使用普通图片事务建立测试图片，检查视频 READY、实际反馈推进、忙时 PREPARE 拒绝、停止释放及原布局/图片索引/尺寸恢复；输出证据在忽略目录。它不读取 HDMI 实际像素，也不证明耳听效果，报告明确保留人工观察项。`--upload-still` 会替换当前焦点窗口内容，需要保留现有图像时不要传该参数。产品运行不依赖 cleanroom 的目录；视频输入必须显式提供路径。

`--layout 0/1/2` 还可让 PC 按原媒体事务创建单图、双图或四宫格测试页，再检查视频播放及恢复；该选项会替换图片。双图和四宫格之间仍先经过单图，不绕过产品规则。播放期间测试脚本还会查询设置、改变并恢复音量，核查 ACK 没有被 VD/AD 路由抢走。

## 9. 接入候选构建现场（2026-10-27）

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

## 10. 网络回归现场与诊断候选（恢复上下文先读）

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

### 当前正在构建的完整功能诊断版

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

## 12. 首轮 capability 缩减和更新的诊断（2026-10-27）

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

## 13. 首行租约门控修复与实际 MP4 验收（2026-10-28）

### 根因和 RTL 修复

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

### 板级与数字验收

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

### PC 解码预取和回归

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

### 当前诊断码和交付状态

复核用 bit 保留 diagnostics。前缀 `2D` 后是 `P M XY`：P 继续表示 PLL/reset；M 现在是实时
`{SDRAM ready, video_request, memory_grant, session_active}`；XY 八个粘滞位依次为 MAC RX、
UDP payload、VD demux、首行 CRC commit、视频 READY 事件、MAC TX valid、MAC/IP 接收错误、
MAC TX 完成。用户读到 `2DC8BF` 时，XY 显示首行 commit/READY 和 TX 均发生且没有接收错误；
M 为 C8 是在有限时长探针停止后读取的空闲状态，不代表正在播放时 lease 未申请。

### 最终无诊断构建

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

### 早期历史诊断记录（后续根因与验收见第 13 节）

显示板上 `dual-V3-beta` 收到普通图片 READY 并提交了 320×180 渐变图，HDMI 确认有画面。
再烧入阶段诊断候选后，PC 普通 0x20 与视频 READY 都无回复。其 7 个阶段位读为 `3F`：
以太网 MAC 字节、UDP 字节、旧应用解析、READY 请求、控制发送 grant、MAC TX 客户端
valid 均到达；MAC 报告位也曾置位。CRC/IP 校验综合精简及完整连接理想时钟仿真通过，
仍未能由物理状态码确定板上没回复的具体位置。

为细分接收阶段，早期诊断版曾增加 IPv4/UDP 头校验错误粘滞标志。该阶段用户读数
`2DC83F` 来自更早的 7 阶段布局；其后曾读到 `2DC800` 和 `2DC8B7`，含义随诊断映射版本变化，
不能交叉套用。它们都属于诊断过程中的历史读数；首行同周期门控根因、修复版 READY 和最终
无诊断构建的验收，以第 13 节记录为准。
