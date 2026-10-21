# 媒体板 SD、HC-08 与双板后续计划

日期：2026-10-21  
计划基线：`optimization/dual-board-architecture`，`56ac9ed`   
本文件记录下一阶段顺序、边界和验收条件。实现按任务点分别提交；不提交到 `main`，不推送远程。网页前端安排最后单独提交。

## 执行准备和安全边界

- 用户已清除媒体板 Flash 并重新插拔 SD 卡。后续只把 bit 下载到 SRAM；不执行 `program_spi`、Program Flash 或其他会写入 Flash 的操作。板卡 Flash 保持擦除状态。
- JTAG cable 0 是显示板，cable 1 是媒体板。所有媒体板下载命令显式指定 cable 1；显示板使用 cable 0。
- 当前卡已经断电复位，按用户报告处于 SD 原生模式。新控制器始终释放 DAT3，初始化和复位均使用原生 SD 命令，不实现进入 SPI 的路径。
- 两板保持上电期间可以重复下载 SRAM bit 和按 FPGA 复位键。若 SD 卡被重新置入 SPI 模式，或板卡/卡失去电源，记录现场状态，继续不依赖该卡的工作；不下载旧 SPI bit，也不依赖用户回来恢复卡状态。
- 现有的所有仿真代码、模型、桩、测试目标和历史回归均保留。新 SD 仿真另加原生 SD 引脚级卡模型；板级调试输出放在被忽略的测试目录，不将临时诊断 RTL 留在最终产品工程。
- 按现有 `docs/td_cli_programming.md` 使用 TD CLI 综合、布局布线、bitgen 和 SRAM JTAG 下载。每阶段保存 bit SHA、资源和时序报告，确认下载目标及 bit 对应后再做板级测试。

## 媒体板：SPI 替换为只读 SD 原生控制器

### 现状和接口边界

迁移前媒体板有效数据路径是 `media_image_source → sd_adapter → sd_card_top → SPI 驱动`。FAT32 通过 LBA 请求一个 512 字节扇区，适配器把卡的数据有效和扇区结束信号送回 FAT32。图像、BMP/WAV 解码、补黑边、PCM 生成和正式 UDP 包不依赖 SPI 波形，应保持扇区接口行为。

产品实例将 `sd_sec_write` 固定为 0，所以运行中没有写卡功能；旧底层 SPI 驱动仍包含未使用的 CMD24 写扇区状态机。新 SD 控制器只实现读卡，删除媒体板生产 RTL 中的 SPI 主机、SPI 命令/扇区状态机及其参数。`boardtest` 中已有 SPI 模型和测试用于复盘，必须保留。

FPGA 侧引脚绑定如下。这里的方向以 FPGA 为准：

| FPGA 信号 | 引脚 | 用途 |
| --- | --- | --- |
| `sd_clk` | A14 | 卡时钟输出 |
| `sd_cmd` | A13 | 命令输出、响应输入 |
| `sd_dat[0]` | B14 | 4-bit 数据线 DAT0 |
| `sd_dat[1]` | B15 | 4-bit 数据线 DAT1 |
| `sd_dat[2]` | A11 | 4-bit 数据线 DAT2 |
| `sd_dat[3]` | A12 | 4-bit 数据线 DAT3 |

图纸显示卡座供电为 3.3 V，并画有 CMD/DAT 上拉网络。实现应使用 CMD 和 DAT 线的高阻释放状态；DAT 是只读主机时的输入，不能把 DAT3 当作 SPI CS 拉低。

### 原生模式和时钟

- 初始化按 SD 原生模式完成，当前识别阶段以 200 kHz SDCLK 通信，再进入 4-bit 总线，检查卡对 High Speed 的支持并完成功能切换，最终将 SDCLK 提升到 50 MHz。200 kHz 低于规范给出的 400 kHz 上限；它用于排查板上首个 CMD55 响应超时，不改变已仿真的协议序列。
- 卡若不支持 50 MHz High Speed，记录 CID/CSD/SCR、OCR、CMD6 查询结果和失败原因，以 25 MHz 原生模式完成诊断；不得把该结果记录成 High Speed 验收通过。
- 控制器位于独立 100 MHz 时钟域，按初始化、25 MHz 和 50 MHz 的分频关系产生 SDCLK。通过扇区缓冲和 CDC 握手回到既有 50 MHz 文件处理域；不把 100 MHz 控制器时钟直接当成卡时钟。
- 实现按卡类型处理地址单位：标准容量卡使用字节地址，高容量卡使用块地址。文件系统仍按 FAT32 处理；不增加 exFAT、写卡或 UHS/1.8 V 电压切换功能。
- 命令帧、响应长度、R1/R1b/R2/R3/R6/R7 解析、CRC7、SCR/CSD/CID 读取、CMD17 数据块和逐 DAT 线 CRC16，均按 SD Association Physical Layer Simplified Specification 核实并在代码注释中标明关键格式和位序。
- 单块数据先写入 512 字节缓冲。CMD 响应有效、数据 token 正确且 CRC16 全部通过后才向 `sd_adapter` 输出该扇区。启动/命令/数据超时和校验错误进行有界重试，最多 3 次；仍失败则通过现有 `i_err`/FAT32 错误路径报告，禁止不受校验的数据进入 BMP/WAV 解析。
- FPGA 复位重新初始化 SD 和媒体读取状态。当前 `boot_rst` 是为以太网保留的一次性上电复位，SD/文件读取复位要单独设计，不能让 FPGA 按键复位反复重置以太网协议栈。

### 仿真和实板验收

- 保留 `boardtest` 当前高层模型和所有现有回归。新增一个真正模拟 CMD/DAT 引脚、卡响应、CRC 和时钟边沿的 SD 原生模式仿真模型；模型从镜像按 LBA 返回字节，覆盖当前镜像和诊断镜像。
- 原生 SD 单元测试覆盖上电初始化、R1/R1b 与 R2 响应、SDSC/SDHC 地址换算、4-bit DAT 位序、SCR/CSD 能力读取、High Speed 检查与切换、CMD17、CRC7/CRC16、坏 CRC、缺响应、延迟响应、超时、有界重试及事务中复位。
- 在 `boardtest` 接上现有媒体读取栈，逐扇区验证 LBA0/分区/BPB、目录、所有 BMP/WAV 文件内容；运行原有七卡和图像/音频回归，并确认原 SPI 仿真目标仍可运行。
- 用户报告 `img/card_user_real.img` 接近当前卡的真实内容，但不作为绝对真值。先比对实际卡的卡标识、容量、分区和文件目录；镜像差异时以实卡读回为准，基于实卡内容重新生成 PC 侧 golden。
- 上板先验证原始扇区和 CRC，再让媒体板完成全目录扫描、每张图片加载、所有实际配对 WAV、无 WAV 静音事务、PC D 快照和网络提交 ACK。至少完整轮播两轮；不做无目标的长时间压力测试。
- 记录 25 MHz 与 High Speed 50 MHz 下的原始扇区吞吐、整张图片读卡时间和媒体到显示的提交时间。媒体发送器现有每个图像 DATA 包间隔为 100 μs（按 125 MHz、每包等待 `CLK_HZ/10000` 个周期，整帧约 182 ms），单独列出这部分耗时。
- CMD18 多块预取只在 CMD17 实测后评估：当命令及卡等待时间超过原始读取时间一半时，尝试最多 4 个连续扇区的预取并分别校验 CRC。只有实测扇区吞吐提升至少 20%、文件/网络回归全部通过且无新的资源/时序瓶颈才保留；否则最终交付已经验证的 CMD17 High Speed 版本。上层接口继续保持逐 LBA 扇区请求。

## 媒体板：HC-08 蓝牙串口入口

- 使用媒体板 `M15` 作为 FPGA UART RX、`L16` 作为 FPGA UART TX，连接 HC-08 的 TX/RX 对应信号。UART 为 9600 baud、8N1。
- 新建第二个 UART RX/TX 实例，复用现有 `[CMD, ~CMD]` 字节帧和 `media_control_core` 命令解包；支持现有命令和字幕上传，不定义新的蓝牙命令格式。
- Ethernet、原有 1 Mbps 板载 UART 和蓝牙作为不同命令来源进入同一个控制核心。命令串行执行，保存请求来源；ACK/状态回到发起请求的 UART。字幕事务从 T 开始至校验/提交结束锁定来源，避免 USB UART 与蓝牙数据混入同一字幕。
- 两个 UART 的收发和命令仲裁在 FPGA 模块级仿真。测试 9600 波特率的真实起始位/数据位/停止位、校验错误/坏帧恢复、所有现有控制命令、字幕长度 0/160、清除字幕、各来源并发排队、ACK 回到正确来源。
- 蓝牙无线链路按用户要求不作为自动验收条件；手机连接和实际控制留给用户醒来后确认。无需安装新的 PC 蓝牙软件或更改系统环境变量。

## 双板资源优化与多窗口可行性

- 在 SD 和蓝牙阶段完成功能并保存基线后，再按“每次一个候选”检查两板资源、层级报告和关键时钟 WNS。每个有效阶段单独提交。
- 媒体板先检查 `MAC_CAPTURE`：当前综合报告显示 MAC 抓包路径约 230 LUT/carry、含 BRAM 与关联 FIFO；正式配置尝试关闭抓包硬件，源码和既有调试仿真保留。保留 Ethernet D 正式快照和 UART 原始数据探针。
- 显示板先验证转场行缓存 `2048 × 32` 从 8 块 BRAM9K 映射为 2 块 BRAM32K，再逐项评估三组帧读写 FIFO、两组媒体接收 FIFO和协议包暂存 RAM。只改变存储映射，不缩短 FIFO 深度；每项分别跑跨时钟/数据顺序测试和 TD 综合，检查 BRAM9K/BRAM32K 实际映射。
- 其他候选限定为明确未使用的逻辑、位宽收敛和不改变时序语义的重构。除非测到足够收益，不替换 HDMI、Ethernet、SDRAM IP，也不删减频谱、GT911、转场或探针功能。
- 资源优化保留条件：相关功能仿真和板级回归全过，至少减少 64 LUT 或回收 2 块 BRAM9K，且相关 setup/hold WNS 相比该阶段基线恶化不超过 0.3 ns。优化没有达标或出现功能回归就撤回该候选。
- 多窗口只做可行性评估并记录报告，不加入产品 RTL 或变更 UDP 公开协议。比较双窗口和四宫格的缩放方式、SDRAM读带宽、现有双图像/双音频四缓冲区占用、转场和音频冲突，并给出显示端实时合成与媒体端预合成各自所需的接口及资源。

## 网页前端（最后单独提交）

- 保留现有 Flask API、Ethernet 固定目标、D 正式快照、BMP 对比、字幕、OSD 三模式和所有现有功能；移除页面全局 `keydown` 命令监听，让文字输入不触发板卡命令。
- 采用紧凑深色控制台：突出当前连接/媒体状态、图片预览和常用切图/播放操作；串口连接、字幕、OSD/频谱和日志分组整理，次要信息可折叠。移动端宽度下按钮可操作，长字幕和日志不会横向溢出。
- 按真实 ACK/状态回包更新控件，发送成功只代表 PC 已发送，不提前显示 FPGA 已生效。Eth/serial连接和断开、N/P/A、音量/亮度/对比度、特效、OSD、频谱、字幕和 D 全部回归。
- 自动验证桌面及窄屏布局、按钮/API行为、D 图像渲染与 BMP 对比、无全局键盘命令监听；保存改版截图。前端相关源码、测试和文档作为最后一次独立提交，方便整体回退。

## 分阶段提交和汇报

1. 只在当前分支开发，不创建其他分支，不提交 `main`，不推送远程。每完成 SD、蓝牙、资源优化、多窗口评估、前端一个任务点并达到各自验收条件，做一笔有单一主题的本地提交。
2. 用户离开期间持续报告每阶段改动、对应 bit/sha、功能证据、资源及下一步。SRAM bit 下载命令显式指定 cable；bit 文件与源版本 hash/报告绑定。
3. 前端最后提交。任务结束报告分支与提交列表、SD 实测 High Speed/吞吐、Bluetooth 仿真结果、两板资源变化、多窗口评估结论和前端截图；明确标出需用户醒来后进行的 HC-08 手机实测以及不可由脚本代替的 HDMI/音频体验确认。

## 依据

- [SD Association Physical Layer Simplified Specifications](https://www.sdcard.org/downloads/pls/)。实现前以当前公开版本复核命令、响应、SCR/CSD、CRC 和时序；3.3 V 4-bit 默认最高 25 MHz，High Speed 最高 50 MHz。
- [HC-08 V3.1 用户手册](https://www.hc01.com/downloads/HC-08V3.1.pdf)。实际硬件模块的 UART 波特率/工作模式以板上模块设置为准。
- 现有工程与镜像：`board_media/user_source/hdl_source/SD/`、`board_media/user_source/hdl_source/media_image_source.v`、`boardtest/`、`img/card_user_real.img`。

## 实际实施记录（2026-10-21）

### 媒体板 SD 与 HC-08

- 生产路径已从 SPI RTL 替换为原生只读 SD host：`sd_native_cmd.v`、`sd_native_host.v`、`sd_native_adapter.v` 和 100 MHz PLL。FAT32 仍使用原来的 LBA/512 字节接口；旧 SPI 仿真、桩和历史回归仍留在 `boardtest`。
- 控制器以 200 kHz 初始化，读取 CMD8/OCR，依 OCR 选择块/字节地址，获取 RCA 后通过 CMD6 检查/切换 High Speed，并使用 ACMD6 设置 4-bit。High Speed 成功时目标为 50 MHz；未支持时走原生 25 MHz 路径。卡数据先进入扇区 RAM，CRC16 通过后再交给 FAT32；读命令/数据最多重试三次。
- 引脚为 CLK=A14、CMD=A13、DAT0=B14、DAT1=B15、DAT2=A11、DAT3=A12。CMD 使用开漏输出/三态，DAT 保持输入。
- `boardtest/vsrc/sd_native_card_model.sv` 是引脚级卡模型，读取 `img/card_user_real.img` 的 LBA0，其他 LBA 使用确定性数据。`make sd-native` 五种配置通过：SDHC+High Speed、25 MHz fallback、SDSC 字节地址、SD v1/1-bit fallback，以及刻意丢弃 CMD55 响应的错误诊断。覆盖随机 LBA、延迟/丢响应、CRC 错误、三次重试上限、数据未校验不进入上层和事务中复位。
- 实板根因已定位并修复：收到卡响应后，host 没有留出规定的命令间隔就开始下一条命令；模型原先立即释放 CMD，未暴露该时序缺陷。板上 CMD55 采样诊断曾显示 FPGA 输入读回与发送位不匹配，末端始终为高。命令控制器现在在普通命令/响应之间留 8 个完整 SD 时钟；CMD6 状态数据和 CMD17 读数据保持立即接收，避免错过紧随 R1 的数据令牌。卡模型也检查该间隔，移除间隔会使仿真失败。最新 SRAM bit 查询结果：`initialized=1`、`SDHC=1`、`High Speed supported=1`、`active=1`；扇区接口开始工作，当前最近事务约 347.34 μs。下一步是遍历实卡全部图片并验证 D 快照像素与配对 PCM。
- HC-08 RTL 使用 9600 baud、8N1，媒体板 RX=M15、TX=L16。USB UART、HC-08 和以太网控制共享串行命令核心；有界 FIFO 按来源仲裁，字幕上传锁定发起来源，ACK/状态回到来源接口。`make bt-uart-unit` 通过真实 UART 波形、全部显示设置、状态、最大 160 字符与清空字幕、错误帧恢复、并发排队和来源路由；按本计划，手机无线链路留给用户实测。

### 资源候选

- Media resource baseline keeps the default MAC capture FIFO enabled (MAC_CAPTURE=1). Evaluate disabling it as a separate candidate only after SD and HC-08 board validation; preserve capture RTL and simulations.
- 显示板 `transition_line_buf` 映射候选已完成 P&R：13,175 LUT、40 BRAM9K、5 BRAM32K、10 DSP、4 PLL。相较候选前 13,178 LUT、48 BRAM9K、3 BRAM32K，回收 8 个 BRAM9K、增加 2 个 BRAM32K，WNS 维持 −5.699 ns，hold WNS 从 −3.056 ns 到 −3.054 ns。转场行缓存、跨时钟预取及媒体/显示切图相关仿真均通过。

### 前端

- Flask API 和现有传输保持不变；连接控制里不显示 IP 地址。前端改为控制/状态与图像预览双栏，串口设置和回包日志可折叠，D 快照按钮位于预览区，BMP 对比仍支持写入流和读回快照。
- 移除了 document 级键盘命令监听，文本框输入命令字符不再发送板卡命令。I 按钮查询原生 SD 状态；A6 回包会在串口和以太网日志中显示 High Speed、初始化错误、读卡时间以及超时命令/采样信息。
- `node scripts/web_console/test_frame_view.js`、`python -m unittest test_console_protocol.py -v` 与 `node scripts/web_console/render_ui_screenshots.cjs` 通过。截图保存于 `scripts/web_console/screenshots/console-desktop.png` 和 `console-mobile.png`；CDP 检查桌面 1600px 与移动 390px 页面均无横向溢出，按钮发送、160 字符字幕和键盘输入行为通过。

## Current debugging state — 2026-10-21

The PC display stub accepted all six card images with exact BMP golden matches. It received four exact paired PCM streams (IMG0=480,000 bytes; IMG1/2/5=720,000 bytes) and two silent transactions, then returned successful commit results. Real-display D snapshots for IMG2, IMG3, IMG4 and IMG5 were also complete and byte-exact; IMG2 and IMG5 committed with paired audio.

After wrapping from IMG5 to IMG0, the display rejected the audio END after retries. The media sender now distinguishes this from a missing result. The display RTL and simulation now propagate audio END reasons 0x11–0x17; the boardtest reproduces a PCM checksum reject (0x15) over the receive/write/result path, and the media sender status parser preserves the reason. The IMG0 physical reason is not yet known because the reason-code display bit could not be downloaded.

The current reason-code display bit and media bit completed P&R, but TD cannot open either JTAG cable (PRG-9505 USB device open error) while both board IPs continue to ping. The JTAGServer service is running; restarting it failed with Windows “Access is denied.” No Flash write or PC network-setting change was performed. Reattempt SRAM download when JTAG cable access is available, then use the status reason to identify the IMG0 rejection. Do not claim IMG0 audio is fixed until the physical transaction commits.

Detailed evidence and current bit hashes are in [media SD audio rejection investigation](media_sd_audio_reject_debug.md).
