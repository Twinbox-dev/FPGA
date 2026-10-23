# 双板链路板级调试记录（2026-10-20）

本文记录本轮“黑边图切换、启动误步进、最终提交回复超时”的定位和修复。资源数均引用最终布局布线报告 `*_phy.area`，不是门级综合报告。

## 结论

- 显示板曾在 `RESULT=0` 和音频 `RESULT=0` 后完成 SDRAM 帧切换，但媒体板偶发等不到最终 `RESULT=2`，状态落在 `WAIT_COMMIT` 并报超时。显示板读回 IMG4 完整匹配，说明该次帧已提交；重发下一张后又成功。
- 显示板现在对最终 `0x0024 RESULT=2` 连发三次，间隔 1 ms。媒体板按 frame_id 处理首个有效回复，重复回复在事务结束后忽略。仿真覆盖了三份重复提交回复和后续校验失败帧。
- 媒体板在非末尾 IMAGE_DATA 包之间等待 100 µs；原 16 µs 版本的 padded frame 曾收到 `word-count` 拒绝。100 µs 版本的 IMG3/IMG4/IMG5 均完成提交，D 快照逐字匹配 BMP。
- 媒体板顶层曾把 N/P 同时接入原始命令口和 `media_control_core` 的脉冲口。现在 Ethernet/UART N/P 只从控制核脉冲输入切图器；原始命令口只保留内部 M 命令。
- 实体按键去抖器上电时先等待按键稳定释放 50 ms，再进入工作状态。复位期间保持低电平不会形成点击；释放后正常按键仍产生单脉冲。干净启动后 IMG1 状态下发一个 N，最终只到 IMG2/index 3。

## 100 µs 包间隔

显示接收器先把每个 UDP DATA 包写入单块 253×32-bit 包缓存，再把字写进 512×32-bit 异步接收 FIFO，SDRAM 写控制器在另一时钟域消费 FIFO。连续包太快时，接收端可能在前一包仍排空/写入时遇到下一包，导致 DATA 被丢弃、总字数不足。发送端现在在每个非末尾图像 DATA 包后等待：

```verilog
IMAGE_PACKET_GAP_CYCLES = CLK_HZ / 10000
```

媒体板千兆应用时钟为 125 MHz，对应 12,500 拍、100 µs。到最后一包后，仍按既有规则等待 1 ms 再发 END。100 µs 下产生的额外帧发送时间约 0.18 秒（1,821 个间隔），相对 SD 读图时间较小。

## 最终提交回复重发

IMG4 曾在显示板读回探针中逐样本匹配，但媒体板停在 `WAIT_COMMIT`。重复发送同一 N 后提交完成。由于 RESULT 是独立 UDP 小包，最终 RESULT=2 丢失时两边状态会分叉。显示板对 result=2 发送三次；不改变帧数据，不重复 SDRAM 写入。两次之后的重复包带同一 frame_id，媒体发送器已回到 IDLE 时会忽略它们。

在临时诊断构建中，显示板正式结果包被路由到 PC `.1:3`。捕获的 IMG2 事务结果依次为：图像 RESULT=0、音频 RESULT=0、最终图像 RESULT=2。PC 把相同 UDP 负载转发给媒体板 `.3:1` 后，媒体状态完成提交。诊断结束后，显示板目标恢复为正式 `.3:1`；最终板级序列在正式直连路由下通过。

## N/P 单步和启动按键

PC/UART 指令由 `media_control_core` 生成 `image_next_pulse` / `image_prev_pulse`。切图器不再同时消费 Ethernet 原始 N/P，从而避免同一命令被不同入口各处理一次。实体按键输入仍保留，并经过同步与 50 ms 去抖；启动时先要求稳定释放，避免重配置期间的低电平触发一步。

验证序列中，干净启动加载 IMG1/index 1；一次 N 到 IMG2/index 3。之后单步 N/P 可按 BMP 环形列表移动：IMG3/index 5、IMG4/index 6、IMG5/index 7、IMG0/index 9。媒体 S 状态中的 error 均为 0。

## PC 快照和显示读回

- Ethernet D 从 SD 重读媒体板当前已提交 BMP，走 formal snapshot 帧槽；全帧为 460,800 字，序号缺口 0。
- 显示板 SDRAM 1/3 读回探针走独立 `rb` 帧槽，和 D 的 `snapshot` 槽分离，不互相覆盖。
- 一次 IMG3 的稀疏探针 UDP 会话只有 153,347/153,600 字、缺 1 个序号；同一次图像的 D formal snapshot 仍是 460,800/460,800 且逐字匹配。验收时丢弃有 gaps 或字数不足的稀疏探针帧，不把它误判成 SDRAM 图像错误。

## 最终板级校验

生产路由为媒体板 `.3:1` 与显示板 `.2:1`。当前已验证的各 padded frame：

| 图片 | 媒体已提交索引 | 媒体错误 | D 字数 / 缺口 | 与 BMP 逐字差异 |
| --- | ---: | ---: | --- | ---: |
| IMG2.BMP | 3 | 0 | 460,800 / 0 | 0 |
| IMG3.BMP | 5 | 0 | 460,800 / 0 | 0 |
| IMG4.BMP | 6 | 0 | 460,800 / 0 | 0 |
| IMG5.BMP | 7 | 0 | 460,800 / 0 | 0 |

显示板 1/3 探针的 IMG2、IMG4、IMG5 样本与 golden 相同；IMG3 的一份探针会话曾丢 1 序号，完整 D 仍完全匹配。

## 仿真命令

以下定向 Verilator 测试均通过：

```text
make media-packet-drain
make media-tx-gap
make media-single-step
make media-button
make media-display-path media-protocol media-image-tx media-tx
```

## 当前最终 P&R 资源

| 板卡 | LUT | FF | BRAM9K / BRAM32K | DSP | Setup WNS / Hold WNS |
| --- | ---: | ---: | ---: | ---: | ---: |
| 媒体板 | 12,411 | 8,500 | 22 / 2 | 2 | −3.560 ns / −3.056 ns |
| 显示板 | 14,310 | 10,370 | 55 / 2 | 10 | −5.699 ns / −2.935 ns |

来源分别为 `board_media/td_project/media_net_Runs/phy_1/media_net_phy.area`、`final_timing.rpt`，以及 `board_display/td_project/lab_ex5_i2s_v1.0_Runs/phy_1/lab_ex5_i2s_v1.0_phy.area`、`final_timing.rpt`。资源表中的 LUT 为布局布线后数据。
## 网卡恢复后的复核

2026-10-20 19:27（本机时间）重新确认 PC 网卡恢复后，媒体板 `192.168.137.3` ping 2/2 成功。通过网页 `D` 对当前已提交的 IMG4 重新取完整快照：frame_id `0x0013`，460,800 个 32-bit 像素字，序号缺口 0。与 `img/golden/IMG4.BMP`（571×720、24-bit）按 BMP 原始行序转换后的期望数据逐字比较，差异 0；接收数据与期望数据 SHA-256 均为 `d8610077ad27555fa977a9021ccbf80c3d9eeb98751d24ffc253a230d448cd06`。

同轮重跑的定向 Verilator 用例通过：协议接收、事务写入、显示发送、填充格式、IMG0/3/4/5 BMP 解析、显示提交路径、媒体快照入口、图像包间隔、包排空、单步切图、实体按键上电防误触、控制命令及回复解析。网页快照接收/ACK 单测、Python 编译检查和前端底到顶 D 图像渲染测试也通过。
## GT911 切图与 D 预览复核

显示板原先将 GT911 手势封装成私有 UDP TYPE `0x0005`，但媒体板生产命令入口 `eth_front` 只解析 V1 TYPE `0x0001` 的 `[CMD, ~CMD]`。所以 RGMII 有发送活动，媒体板却没有产生切图命令。现在触控下一张/上一张改为 V1 大端 TYPE/LEN，包体仍是 `N/~N` 或 `P/~P`。

新增 `make -C boardtest touch-command-path`：用生产 `media_display_tx` 发包，再把字节直接送入媒体板生产 `eth_front`；N 和 P 都被解析为对应命令。`media-tx` 回归也通过。

PC D 快照此前已经下载到 `frameCvRb`，但预览父卡 `frameCard` 初始为隐藏；只有写侧帧事件会显示父卡。现在任何成功渲染的帧都会显示父卡。`node scripts/web_console/test_frame_view.js` 从 D-only、父卡初始隐藏的条件验证了这一点。Python 快照/ACK 测试和语法检查通过。

显示板新 bit 已用 TD CLI 下载到 SRAM cable 0；SHA-256 为 `D18320D95667E626A5822A2F8A1AE9D51D510C3556B54DFD8EAA1410961EB8F6`。最终 P&R 为 14,255 LUT、10,364 FF、BRAM9K/32K 为 55/2、DSP 10，Setup/Hold WNS 为 −5.699/−2.924 ns。下载后显示板 `.2` 和媒体板 `.3` 均 ping 2/2 成功。

网页服务重新启动并连接媒体板后，D 收到 460,800 字、缺口 0；该快照逐字匹配 IMG5 的 720 行显示顺序反转数据，前端按 BMP bottom-up 映射后显示正确。用户刷新页面并按 D 后确认能看到图像。

用户在新显示板 bit 上向左划一次，HDMI 成功切到下一张。随后通过 V1 `S` 回读确认媒体状态为 `img=9+wav`、`media-TX=idle error=0`。GT911 触发、媒体板切图和网页 D 预览均完成板级验收。

## 早期双板控制字节序与资源快照（由旧实施计划合并）

以下是 2026-10-20—21 的历史验收与产物身份，不是当前资源或当前固定帧格式。当前媒体板已改为原生 SD、可变尺寸帧；现行行为见 [双板架构](dual_board_architecture.md) 和 [多窗口说明](native_frame_multiview_handoff.md)。

### 先前 PC 行为级互操作测试

- **媒体发送、PC 模拟显示端**：PC stub 收 READY/RESULT。IMG1 的 460800 字图像和 24000 个 WAV 样本提交成功；无配对 WAV 的图片走零样本静音事务。显示板参数临时改为 PC `.1:2`，供媒体板数据流经 PC 校验后回 RESULT。
- **显示端接收、PC 模拟媒体板**：PC stub 向显示板发送 READY、IMG1 图像和 WAV；460800 字图像与 golden 相同，720000 个 WAV 字节与卡镜像中的配对文件相同，图音提交 RESULT=2。
- **正式 PC D 快照**：媒体板从已提交 SD 索引重读图片并回传 460800 字，PC 校验通过后收到图音最终提交 RESULT=2；此路径不写显示板 SDRAM。
- 上述模拟测试及既有 Verilator 回归覆盖图像/音频协议解析、SDRAM 写入、图音提交、控制、状态、字幕、以太网发送仲裁与 UART 控制。

### 本轮控制通道根因与修复

媒体板通过旧版 eth_front 发出的 V1 控制头采用大端 TYPE/LEN，例如 0x0042、长度 1 的线路字节为 00 42 00 01。显示板 media_display_control_rx 原先按小端解析，因此忽略 SET、STATUS_REQ 和字幕包；显示板返回的 0x0041/0x0043 也曾按另一种字节序发送，媒体板等待约 2 秒后超时。修复后 0x0040–0x0046 控制包的双向 TYPE/LEN 都按 V1 大端收发；正式图像与 PCM 流 0x0020–0x0033 仍按小端收发。

之前的字幕 round-trip 仿真自行拼了小端请求头，没有复现 eth_front 的 V1 大端头，因此仿真通过而上板控制超时。本轮仿真改为实际 V1 字节顺序，并增加显示侧 ACK/STATUS 头的字节检查。


### 本轮 bit、资源与时序

| 板卡 | bit 文件 | SHA-256 | LUT / FF | BRAM9K / BRAM32K | DSP / PLL | Setup WNS / Hold WNS |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| 显示板 | board_display/td_project/lab_ex5_i2s_v1.0_Runs/phy_1/lab_ex5_i2s_v1.0.bit | 813606D23222F03A415DFCB3F6B45FC5E90AD22B46B2D4010F1CF10A6968D9B7 | 13,178 / 9,825 | 48 / 3 | 10 / 4 | −5.699 ns / −3.200 ns |
| 媒体板 | board_media/td_project/media_net_Runs/phy_1/media_net.bit | 0DE75D333FE0D0FE85A0C375B7502B75DAB86782B7247BB43689CA36568B72AB | 12,411 / 8,500 | 22 / 2 | 2 / 2 | −3.560 ns / −3.056 ns |

当前优化分支相较 dual-V1 显示板少 1,077 LUT、539 FF 和 7 块 BRAM9K，新增使用 1 块 BRAM32K。该版移除了显示板不再使用的旧 UART 控制通路、旧 PC 直连控制入口，以及显示板本地 SDRAM 诊断读回探针；PC 网页 D 正式快照仍由媒体板处理，OSD“关闭/调节后 3 秒/始终显示”也继续保留。OSD 与字幕字体改为共用一块双读口 BRAM32K。用户已在新 bit 上确认功能正常。

板间控制可用 `python scripts/dual_board_cmd_probe.py --count 1` 快速检查：脚本通过媒体板查询当前音量，发送一次音量变化并恢复原值，验证显示板 ACK 经媒体板返回。先关闭占用 PC UDP `:2` 的 Web 控制台。

2026-10-20 的黑边图、单步命令、按键启动和最终 RESULT 重试修复及逐图验收见 [双板实时联调记录](dual_board_live_debug_20261020.md)。

两边 TD P&R 均生成 bit；资源与最终报告位于各自 phy_1/*_phy.area、route.qor、final_timing.rpt。两份报告仍显示既有的 setup/hold 时序违例，实际网络与协议回归已通过；HDMI 目视和音频听感由用户返回后确认。
