# 资源优化实验与验收历史

本文合并 2026-10-21、10-24、10-30 最近邻阶段的完整实验记录，保留撤回原因、测试及资源证据。各节的“当前”只指记录当时，数字不能跨配置直接相减。最新资源和功能以 [板卡状态](board_status.md)、[统计开关与完整 CV](video_statistics_full_cv_20261030.md) 为准。

- [2026-10-21 资源平衡](#balance-20261021)
- [2026-10-24 双板优化](#optimization-20261024)
- [2026-10-30 最近邻缩小](#nearest-20261030)

<a id="balance-20261021"></a>

## 双板资源平衡记录（2026-10-21）

本记录以 `feature/dual-board-architecture` 合并后的双板工程为对象。媒体板和显示板分别综合、布局布线；所有新 bit 仅写 SRAM。

### 基线

以媒体板 50 MHz SD、HC-08 和音频回环修复版为基线：

| 板卡 | LUT | FF | BRAM9K | BRAM32K | DSP | Setup WNS | Hold WNS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 显示板 | 13,182 | 9,836 | 40 | 5 | 10 | −5.699 ns | −3.188 ns |
| 媒体板 | 14,367 | 9,625 | 23 | 2 | 2 | −4.351 ns | −2.850 ns |

显示板的 `transition_line_buf` 已使用 BRAM32K：每个 bank 为 1024×32 位，两 bank 合计占 2 个 BRAM32K。无需再次迁移。

### 媒体板 MAC 抓包器候选：撤回

媒体板层级报告中，`media_mac_capture` 约占 281 LUT 和 1 个 BRAM9K；关闭它还会移除 `eth_front` 中仅供探针 B 使用的异步 FIFO。候选把顶层 `MAC_CAPTURE` 从 1 改为 0，综合结果为 14,044 LUT、9,374 FF、20 BRAM9K、2 BRAM32K、2 DSP，资源收益为 323 LUT 和 3 个 BRAM9K。

候选布局布线的 setup/hold WNS 为 −3.765/−3.200 ns。Setup 改善 0.586 ns，但 hold 比基线恶化 0.350 ns，超过本轮 0.300 ns 上限 0.050 ns。按验收规则撤回该候选，没有下载它的 bit。媒体板继续保留 MAC 抓包器、D 快照和源数据探针。

### 显示板 FIFO 映射候选：保留

显示板 `eth_front.v` 中的 `tap_afifo` 只有四个实例，均为 512×32 位：两个 Ethernet 探针 FIFO，以及 `media_transaction_writer` 的图像、音频接收 FIFO。原来每个 FIFO 映射到两个 BRAM9K；将同一同步读写 RAM 声明改为 `ram_style="bram_32k"` 后，每个实例映射到一个 BRAM32K。读写指针、异步复位、同步读延迟和 FIFO 深度没有改动。

| 指标 | 基线 | 候选 | 变化 |
| --- | ---: | ---: | ---: |
| LUT | 13,182 | 13,161 | −21 |
| FF | 9,836 | 9,839 | +3 |
| BRAM9K | 40 | 36 | −4 |
| BRAM32K | 5 | 9 | +4 |
| DSP | 10 | 10 | 不变 |
| Setup WNS | −5.699 ns | −5.699 ns | 不变 |
| Hold WNS | −3.188 ns | −3.188 ns | 不变 |

四块 9K RAM 被换成四块目前余量充足的 32K RAM，资源没有形成新的短板；功能仿真和双板六图验收均通过，因此保留该候选。

验证命令：

```text
make -C boardtest media-writer media-display-path media-packet-drain
python scripts/media_sd_board_acceptance.py --images 6 --timeout 45 --settle-seconds 3
```

板级验收覆盖 IMG1→IMG2→IMG3→IMG4→IMG5→IMG0；每张 D 快照均为 460,800 字、序号缺口为 0，且逐字匹配对应 BMP。四个配对 WAV 均报告提交成功，IMG3/IMG4 静音提交成功。逐图结果保存在忽略目录 `boardtest/captures/20261021_173338_sd_board_acceptance.json`。

候选 bit SHA-256：`B5F237FEFDFC5EA36D172A30AE4F933D09B7EF419FEE593B4BE895FB78C034BE`。布局布线报告位于显示板 TD 工程 `phy_1` 目录。

该 bit 于 2026-10-21 下载到 cable0 的 SRAM。HDMI 视觉效果和喇叭输出仍由用户做最终主观确认；本轮 PC D 快照验证的是媒体板 SD 源图及以太网传输，不覆盖显示板 SDRAM 写入/扫描；显示端还需 HDMI 或专用诊断证据。

<a id="optimization-20261024"></a>

## 双板资源优化：2026-10-24

### 范围与复现基线

本轮继续在 `fix/multiview-resource-optimization` 工作，起点为用户已验收的 `4cbbe23`。视频、多窗口音频和转场讨论保存在 [后续方向](video_multiview_direction.md)，本轮不增加这些功能、不修改协议、布局和默认显示设置。

实验初期在 `boardtest/captures/resource_20261024/` 的独立工程内完成，每个候选冻结全部 `user_source`、主 `.al`、`syn_1/phy_1` 工程列表和设置，以及输入文件清单。显示候选由用户确认可验收后，其 bit/报告同步到正式 TD 输出并随本次提交保存；已撤回媒体候选仍只留在实验目录。

| 基线 | 显示板 | 媒体板 |
| --- | ---: | ---: |
| 门级 LUT | 14,393 | 14,679 |
| 布线后 LUT | 14,924 | 15,640 |
| 布线后 FF | 10,090 | 10,687 |
| 切片 / 9,800 | 8,613 | 8,746 |
| BRAM9K / BRAM32K | 35 / 11 | 20 / 2 |
| DSP / PLL | 18 / 4 | 5 / 3 |
| Setup / Hold WNS | −5.988 / −2.960 ns | −3.202 / −2.935 ns |

媒体基线在本轮独立工程重新执行综合及布局布线，门级、最终资源和全局时序与正式基线一致。以下区分门级和布线后数字，层次表的 `lut/ripple/le` 也不能直接当作最终 `#lut` 比较。

### 显示板：关闭默认启用的验收诊断硬件

当前正式顶层还直接例化两项调试逻辑：

- `display_frame_digest`：对真实 SDRAM 扫描做计数/摘要，按诊断请求回包。
- `display_test_cursor`：接收 `0x004B` 并覆盖窗口选择坐标，供无人值守焦点测试使用。

候选增加顶层参数 `DISPLAY_DIAGNOSTICS=0`，只在参数为 1 时综合这两项逻辑。参数为 0 时关闭诊断请求，并固定测试光标使能为 0，正式 GT911 光标和焦点照常工作。模块源码、历史诊断、仿真均保留。

这不涉及媒体板产品 D 源图快照、CV、字幕、OSD、频谱、音频、转场、多窗口或 GT911 滑动。正式控制报文不依赖这两项诊断。诊断默认关闭也允许综合器移除只服务诊断的选择逻辑。

| 指标 | 已验收基线 | 候选 | 变化 |
| --- | ---: | ---: | ---: |
| 门级 LUT | 14,393 | 13,872 | −521 |
| 门级 FF | 10,109 | 9,664 | −445 |
| 布线后 LUT | 14,924 | 14,402 | −522 |
| 布线后 FF | 10,090 | 9,659 | −431 |
| 切片 | 8,613 | 8,303 | −310 |
| BRAM9K / BRAM32K | 35 / 11 | 35 / 11 | 不变 |
| DSP / PLL | 18 / 4 | 18 / 4 | 不变 |
| Setup WNS | −5.988 ns | −5.699 ns | 改善 0.289 ns |
| Hold WNS | −2.960 ns | −3.054 ns | 恶化 0.094 ns |
| 视频域 Setup WNS | −4.260 ns | −4.074 ns | 改善 0.186 ns |

候选切片占用 84.72%，LUT 73.48%。总 setup/hold 仍有负裕量，不能把这项收益写成时序收敛。候选物理流程约 3 分 39 秒（布局约 1 分 20 秒、布线约 2 分 14 秒）；并行实验时的墙钟时间只记录，不作稳定性能保证。

已执行 `make -C boardtest view-control-path view-framepath display-mux-lifetime gt911-unit`：覆盖 PREPARE/状态、双/四窗独立 N/P、回环、busy 拒绝、触控/D 调度、真实异步 FIFO/黑窗扫描/排空、UDP 包归属，以及 GT911 I2C/手势/角色光标。定向仿真通过。

此外将冻结副本的 `DISPLAY_DIAGNOSTICS` 置 1 重新综合，确认两项诊断仍可展开：门级 14,404 LUT、10,109 FF。生成层次变化会使映射稍有波动，不能要求其网表与无 generate 的历史基线逐位相同。

候选的正式 bit、门级/布线报告和 `best_result` 已同步到显示板 TD 工程跟踪位置，与当前 RTL 成套保存。bit 下载至 cable0 SRAM 并完成 Web/PC 实测后，用户于 2026-10-24 确认总体功能可验收。自动验收收到 5 张图的完整 D 快照，逐像素与 BMP golden 一致；用户也确认双板产品实测可接受。

用户补充：多窗口偶尔切图会短暂出现黑屏，此时 D 读不出图；用户认为这是此前版本已有的现象，本轮暂不处理且不影响整体验收。该现象记录为已知行为，本提交不声称修复。

### 媒体板：WAV 解析器的两种候选

原 WAV 解析器把固定格式字段保存为 80-bit，然后与 PCM/24kHz/8-bit/mono 常量比较；同时用声明长度、DATA 已读长度和 SKIP 剩余长度三个 32-bit 寄存器。

#### 候选 A：格式逐字节检查 + 共享剩余计数器

以一个累计匹配位替代仅用于常量比较的格式寄存器；在互斥的头解析/DATA/SKIP 阶段复用长度寄存器，原始样本总数仍由 `o_data_bytes` 保存。端口、有效拍、错误与重启输出保持一致。

| 指标 | 基线 | 候选 A |
| --- | ---: | ---: |
| 门级 LUT / FF | 14,679 / 10,667 | 14,564 / 10,524 |
| 布线后 LUT / FF | 15,640 / 10,687 | 15,528 / 10,548 |
| 切片 | 8,746 | 8,671 |
| BRAM9K / BRAM32K / DSP | 20 / 2 / 5 | 20 / 2 / 5 |
| 全局 Setup / Hold WNS | −3.202 / −2.935 ns | −3.271 / −3.042 ns |
| 50MHz 域 Setup WNS | +1.269 ns | +0.514 ns |
| 100MHz SD 域 Setup WNS | −2.578 ns | −3.080 ns |
| 物理流程 | 约 5 分 02 秒 | 约 7 分 34 秒 |

候选虽然节省 112 个最终 LUT 和 139 FF，但 50MHz 域裕量减少 0.755 ns，SD 域恶化 0.502 ns；布线还在两个拥塞点上长时间迭代。这些是整机重新布局后的观察，不能仅据此断言 WAV 逻辑直接导致 SD 路径变化。**该候选撤回，不交付到正式媒体板。**

候选 A 的仿真通过：

- `wav-reader-unit`：保留 `boardtest/vsrc/wav_reader.v` 不变，生成改名参考模块；逐拍比较全部端口。4,124 个独立 golden 用例、391,019 拍一致，含每个 fmt 字节全部 256 个取值、零/扩展/短 fmt、重复 fmt、非法格式、未知块、样本边界、超大声明长度、间断有效、截断/重启和随机复位。
- `media-sd-image-source`：原生 SD 引脚模型读取实卡镜像，六张 BMP 完成；IMG0/1/2/5 四份 PCM 分别与 golden 的 480,000/720,000/720,000/720,000 字节一致，累计 29,447 次扇区读取。IMG3/4 无配对 WAV。该测试是仿真，不代表本轮实卡测量吞吐。

#### 候选 B：仅格式字段逐字节检查

保持原有三个长度计数器，只优化固定格式字段。相同逐拍测试通过；门级为 14,613 LUT、10,588 FF，相比基线减少 66 LUT、79 FF。完整 SD/FAT/六图/四 WAV 回归亦通过。

最终布线后为 15,638 LUT、10,609 FF、8,859 切片：仅减少 2 LUT，却增加 113 切片；setup/hold 为 −4.256/−3.188 ns，setup 比基线恶化 1.054 ns。物理流程约 4 分 13 秒。**该候选同样撤回。** 这两次实验说明门级数字不能代替整机布线结果。

本轮媒体板生产 WAV 已恢复为起点原文件，整个 `board_media` 正式源码/bit/报告保持基线。新增测试保留，供后续结构优化回归使用；两个实验的输入快照、日志和候选 bit 留在独立输出目录，未执行下载。

### 隔离实验入口

```powershell
python boardtest/diagnostics/prepare_resource_experiment.py --board media --name media_trial
python boardtest/diagnostics/prepare_resource_experiment.py --board display --name display_trial
# 仅在冻结副本中恢复扫描摘要/测试坐标；不改产品源文件：
python boardtest/diagnostics/prepare_resource_experiment.py --board display --name display_diag --display-diagnostics
```

默认输出在 `boardtest/captures/resource_experiments/<name>/`；可用 `--output-root` 指定 captures 下其他父目录。名字已存在则拒绝覆盖。每份 `manifest.json` 保存基线提交和实际冻结输入文件指纹，方便避免“测试 bit 找不到对应源码”。当前未验收中间实验留在忽略目录；一旦成为需复现的正式板测版本，按 [提交规则](repository_commit_policy.md) 成套归档。

在输出的 `<board>/td_project/<project>_Runs/syn_1` 工作目录执行：

```powershell
$taskCli = 'C:\Program Files\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin\td_commands_prompt.exe'
@('source {C:/Program Files/Anlogic/TD_6.2.1_Engineer_6.2.168.116/doc/scripts/DefaultFlow.tcl}', 'exit') | & $taskCli
```

确认本轮 `opt_gate` 完成且无 ERROR 后，在对应 `phy_1` 执行同一命令。不要只看退出码，不要把未重综合的旧网表当成新源码结果。字体 `font.mem` 路径继续由源码目录解析，冻结整个 `user_source` 能保留对应资源。CLI/SRAM 规则仍见 [TD 指南](td_cli_programming.md)。

### 下一步与更大候选

- 当前选中显示板关闭诊断的候选，媒体板保持原稳定版。下一步先验证图像、布局、CV、叠加、转场、音频和真实 GT911。用户负责上电，CLI SRAM 下载及自动检查由开发端执行；不烧录已撤回的 WAV 实验。
- 媒体板完整 Ethernet 约 5,382 LE，其内加密 UDP/IP 栈约 3,323 LE；FAT32 约 2,161 LE。大规模回收要从这些模块的存储/协议结构寻找，不能把本轮小候选说成已经完成激进优化。
- 当前 IP 顶层仅暴露 ARP 重试次数/间隔、地址与设备参数，没有现成可调的 ARP 缓存深度。重试参数不是缓存容量开关，不应为省资源改掉网络可靠性。
- 媒体网络双对端 UDP-lite 候选已在下文完成 RTL、仿真和隔离综合/布局布线；PC 动态 MAC、ARP、控制/字幕、D 快照与显示数据路由保留，按已授权的资源收益取舍删除 ping。当前尚未完成板级验收。
- FAT 文件元数据改成同步 BRAM 需核对查找延迟与配对行为；不能只加 RAM 属性，也不能因固定目录样例通过就缩短合法文件大小或删掉碎片簇链支持。

现有源码、测试和正式已验收产物在提交前仍应逐项核对；本记录不构成向 main 合并或推送的授权。

### 媒体板：双对端 UDP-lite 候选 A5

从已提交基线报告出发，将媒体板的通用 UDP/IP 栈替换为固定拓扑实现：PC 192.168.137.1、显示板 192.168.137.2、媒体板 192.168.137.3。正式板间路由、应用层数据格式、D 快照格式、媒体发送仲裁、TEMAC/RGMII、以太网异步 FIFO 和 MAC 抓包逻辑均沿用当前实现。PC MAC 从 ARP 或有效 IPv4 包学习；显示板 MAC 固定为 `01:23:45:67:89:ab`。模块只接受本地 UDP 1 端口、固定 IPv4 头和未分片包；TX 最大 1024 字节，覆盖现有最大 1022 字节应用包。IP 头校验继续检查，UDP 校验和沿用零值发送，以太网帧仍由现有 TEMAC/FIFO 处理。

为节省资源，候选移除了 ICMP echo（ping）。PC 的 UDP 控制、字幕、D 快照和媒体板到显示板的大包通道保留。删除 ping 是用户明确允许的资源取舍；板卡在线检查应使用现有 UDP 状态查询。

#### 综合与布局布线结果

| 指标 | 已提交媒体板基线 | UDP-lite A5 | 变化 |
| --- | ---: | ---: | ---: |
| 布局布线 LUT | 15,640 | 14,062 | −1,578 |
| FF | 10,687 | 8,878 | −1,809 |
| 切片 | 8,746 | 7,810 | −936 |
| BRAM9K / BRAM32K | 20 / 2 | 19 / 2 | −1 / 不变 |
| DSP / PLL | 5 / 3 | 5 / 3 | 不变 |
| Setup WNS | −3.202 ns | −3.552 ns | 恶化 0.350 ns |
| Hold WNS | −2.935 ns | −3.200 ns | 恶化 0.265 ns |

A5 的 setup WNS 比既定 0.3 ns 变化门槛多 0.050 ns，hold 仍在门槛内。板级数据通路已经通过下述实测，但时序余量变化应在后续媒体板布局或时钟改动前重新核查。A5 使用多周期累加器生成 IPv4 头校验和，以缩短 125 MHz 路径。产品 bit、`media_net_phy.area`、`route.qor` 和 `final_timing.rpt` 已归档在受跟踪的 `board_media/td_project/media_net_Runs/` 下；板测下载使用的 bit 与 `phy_1/media_net.bit`、`best_result/media_net.bit` 为同一文件。隔离目录 `boardtest/captures/resource_experiments/media_udp_lite_a5/` 仍被忽略，仅保留临时完整工程副本。

#### 仿真与实板验收

- `make -C boardtest media-net-lite`：PC 与显示板 ARP、双对端 UDP、1022 字节收发、IP 校验和、错误端口/未知来源拒绝及 TEMAC 反压通过。
- `make -C boardtest media-net-lite-app`：真实 `eth_front` 从 PC UDP 包解出 `N` 命令，并将真实应用响应封装回已学习的 PC MAC，通过。
- 媒体板 A5 bit 已通过 `scripts/program_sram.ps1 -Board media -CandidateBit <A5 bit>` 写入 cable1 SRAM；显示板稳定 bit 已通过 `scripts/program_sram.ps1 -Board display` 写入 cable0 SRAM。A5 bit 现已归档为媒体板正式工程 bit，后续从正式路径下载可使用 `scripts/program_sram.ps1 -Board media`。
- 网页状态查询成功；`N` 收到 ACK 并提交显示状态，单图索引从 1 更新为 3（状态序号由 3 到 7，布局 0、焦点 0、非忙）。
- 随后的 `D` 快照与 `IMG2.BMP` golden 逐字节一致：1280×720、460,800 个 32-bit 字、1,843,200 字节、序号缺口 0。

之前 A3 使用了错误的显示板 MAC，不能用于板级测试；A3/A4 bit 均为过期候选，不得下载。A5 的 MAC 已修正并通过实际双板路由和 PC 快照验证。Windows 普通沙箱进程曾因 USB device open error 失败；在相同主机、线缆和 SRAM 下载模式下，由已授权的非沙箱命令运行下载脚本后成功。详细 CLI 下载方式以 `docs/td_cli_programming.md` 为准。

<a id="nearest-20261030"></a>

## 显示板资源优化：最近邻缩小（2026-10-30 已验收）

### 基线与范围

基线为 `feature/direct-video-playback@d281ca0`。频谱下放与 CV 实验保存在 stash，未带入本候选；媒体板不修改。当前产品仍关闭 Sobel/锐化，其他开关保持 d281ca0，不能把本轮数字表述为六种 CV 全开的资源。

用户允许牺牲画质及未来可拓展性来节省资源。本候选将图片多窗口缩小从双线性改为中心对齐最近邻。图片比例并非都为整数：例如 640×480 在四宫格内是 480×360，571×720 是 285×360。因此保留任意合法尺寸的等比例适配，不把实现限制为隔一取一。

### 实现与画质取舍

`view_nearest_shrink` 对每个目标像素采样：

```
sx = floor((2*dx+1)*source_width /(2*dest_width))
sy = floor((2*dy+1)*source_height/(2*dest_height))
```

硬件通过两个 12-bit 整数相位累加器在原始 bottom-up 输入中选点，不逐像素相除。删除生产缩小路径的两行 RGB565 缓存、插值乘法器及插值中间寄存器，不增加输出行缓存。缩小目标尺寸、居中黑边、不放大、RGB565 打包、音频旁路和板间协议保持现有规则。奇数像素的输出尾字高半字补零；提前结束输入时剩余输入像素按零处理。

画质代价是细线、纹理可能出现锯齿和摩尔纹；不进行低通抗混叠。历史双线性模块和仿真保留，旧 pipeline 仿真改用 `boardtest/diagnostics/bilinear_reference/view_image_pipeline.v`，防止历史 golden 被悄悄改成最近邻。

`view_scale_geometry` 新增编译期 `COORDINATES_ENABLED`；生产最近邻只使用尺寸，不生成 Q16 插值坐标。默认值仍服务既有双线性历史测试，生产常量关闭后综合剪除对应逻辑。

### 资源与时序

同一 d281ca0 工程设置，在独立冻结目录完成整机综合和布局布线：

| 指标 | d281ca0 | 最近邻候选 | 变化 |
| --- | ---: | ---: | ---: |
| 综合 LUT（含 ripple） | 16,544 | 16,014 | −530 |
| 综合 FF | 12,341 | 12,033 | −308 |
| 布线后 LUT | 17,501 | 16,947 | −554 |
| 布线后 FF | 12,329 | 12,017 | −312 |
| slices / 9,800 | 9,304 | 9,045 | −259 |
| BRAM9K | 49 | 49 | 0 |
| BRAM32K | 10 | 8 | −2 |
| DSP | 18 | 16 | −2 |
| Setup WNS | −5.699 ns | −6.268 ns | 恶化 0.569 ns |
| Hold WNS | −3.068 ns | −3.042 ns | 改善 0.026 ns |

布局布线与 bitgen 完成不等于时序收敛。当前 setup 仍为负且恶化 0.569 ns，不能声称静态时序通过。候选已完成下述自动板测，用户随后反馈“测试没问题”并授权提交。综合约 2m18s，物理流程约 4m12s。

冻结目录（忽略的实验输出，不是提交中的正式产物）：

`boardtest/captures/resource_experiments/nearest_20261030/`

其中 `manifest.json` 记录输入源码和配置；`board_display/user_source/` 是生成候选的实际源码；配套 bit 是：

`board_display/td_project/lab_ex5_i2s_v1.0_Runs/phy_1/lab_ex5_i2s_v1.0.bit`

该 bit 路径相对于上述冻结目录。用户验收后，已将同一个 bit、综合/布线报告、运行日志及实际使用的 `.prj/settings.cfg` 同步至正式 `board_display/td_project/*_Runs`；`best_result` 的 bit/布线摘要同步更新。正式 `video_build_manifest.json` 已按冻结输入重新发布，核对所有冻结源码及工程配置与提交文件逐字节一致。因此回溯本次提交无需依赖忽略的 captures 目录。媒体板继续使用提交中 d281ca0 配套的正式 bit 和报告。

### 已执行仿真

WSL Verilator 执行：

```
make -C boardtest view-nearest view-nearest-pipeline view-geometry
make -C boardtest view-bilinear view-image-pipeline view-control-path view-framepath
```

全部通过。新缩小器和实际补黑 pipeline 各有 14 组逐像素 golden：单图原尺寸、双图、四图、非整数比例、奇数宽高、单像素、零输入和提前截断，连续帧无中间复位，源/目的有背压。几何测试 73 组；历史双线性及补黑回归、窗口控制和真实异步 FIFO/排空屏障仿真亦通过。上述证据不代替 HDMI 画质、触摸或视频实板验收。

### 自动板测（2026-10-30）

用户给两板上电后，核对冻结目录全部 manifest 输入及工作区源码，核对媒体板正式 bit 与其 manifest 一致。通过现有 `scripts/program_sram.ps1` 普通用户 CLI 将最近邻候选下载至 cable0，将 d281ca0 媒体板正式 bit 下载至 cable1，均为 SRAM。下载日志：

- `boardtest/captures/sram_download/program_display_20261030_152319.log`
- `boardtest/captures/sram_download/program_media_20261030_152353.log`

PC 原有两个旧 App 实例已关闭，本轮只留一个当前工作区 App。用户接回 USB 网卡后，从真实 Flask API 执行以下测试，产品 RTL 和 App 源码未在板测中再修改：

- 遍历实卡六张 BMP 的切图事务；目录索引为 1/3/5/6/7/9，包含 WAV 条目的列表索引不能直接当作 `IMG编号`。
- 三种转场设置后切图，双图和四宫格进入/退出、焦点窗 N/P、非目标窗图片索引保持；完成时布局有效掩码分别为 1/3/15。
- 当前启用的原图、灰度、二值化、雪花、频谱及灵敏度、OSD、音量、亮度/对比度命令 ACK，字幕 `NEAREST TEST` 收到最终校验/提交确认。这里 ACK 不等于肉眼确认相应效果。
- D 收到 460,800 字、缺口为零，与 `diag_audio/IMG0.BMP` 原始像素逐字一致。D 是媒体板源图快照，不是显示板最近邻/SDRAM 扫描读回；缩小结果的逐像素证据来自前述仿真，HDMI 仍需人工看。
- 实际 App 图片上传：单图 127×95、1×1、320×180，双图 1280×720，四图 571×720，全部收到 `result=2`；每次上传后 SD 下一张均正常完成。
- 实际 App 上传本机 `diag_audio/vedio.mp4` 并启用音频，分别从三种布局启动视频。每轮自动检查时分别已发送 606/607/608 帧，READY 正常，`skipped_rows=0`，接收反馈的 `video_missing/audio_missing` 均为 false。测试包含丢包重传，不能写成网络完全无丢包。
- 视频期间 N 被忙状态拒绝，音量与 S 保持可用。停止后通过网页实际使用的 `/api/eth/video/status` 确认释放，原布局、代次、图片索引和有效掩码一致，随后 SD N 继续有效。通用 `/api/status` 本身不触发视频释放查询，临时测试脚本已按真实前端流程修正。

测试原始记录在忽略目录：`nearest_live_result_20261030.json`、`nearest_live_tail_result_20261030.json`、`nearest_video_api_result_20261030.json`（均位于 `boardtest/captures/`）。第一份含初始回归结果及测试脚本错误映射目录索引导致的 golden 文件查找异常；第二份完成正确 golden 比对及图传，第三份完成三布局视频回归。不能把测试脚本问题描述为已修复的产品 bug。

自动测试后视频已停止并恢复单图。用户随后自行测试，确认“测试没问题”，并授权将本版源码、测试、bit/报告及文档提交至当前 feature 分支。该验收不包含恢复 Sobel/锐化，它们仍按 d281ca0 的能力配置关闭。产品频谱 DFT 仍在显示板，本轮未应用 stash 中的频谱下放实验。

### 后续架构审查边界

- 当前 `DISPLAY_DIAGNOSTICS=0`、`VIDEO_LINK_DIAGNOSTICS=0`、`DIRECT_VIDEO_STATUS=0`。未例化的 probe 定义及 generate 中关闭的诊断并不消耗产品 LUT；删除源码有助于整理，但不能报为资源收益。
- 综合层次报告中网络子系统约 2,500 LUT/ripple，视频 pipeline 约 2,315，图音协议接收器约 1,068。层次数字包含子项，不能与子模块再次相加，也不是布线后 LUT。
- 下一批应检查当前产品实际使用的数据格式是否仍承担多种格式的硬件成本，以及互斥的图片/视频缓冲和数据搬运是否可以复用。每项仍须以整机资源和行为测试证明收益。
- READY/credit/NACK、图音提交、SDRAM 在途读排空、错误重试与跨时钟握手承担现有功能。不能把它们因历史调试来源直接归为死代码；删除会改变当前正确性契约，需先形成替代方案。
- 本次未恢复被关闭的 Sobel/锐化，也未将频谱下放；后续恢复时必须重新测量，不能沿用本表声称完整功能低于 17K LUT。
