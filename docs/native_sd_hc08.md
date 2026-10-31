# 原生 SD 读卡与 HC-08 控制

本文整理已经落地的 SD/蓝牙实现，替代 2026-10-21 的执行计划；更早的故障和性能测量见 [历史记录](history.md)。

## 媒体板读卡边界

生产路径为 `media_image_source` → `sd_native_adapter` → `sd_native_host`/`sd_native_cmd`。FAT32 仍使用 LBA 请求和 512 字节扇区接口，上层 BMP/WAV 不解析 SD 引脚波形。只读，未实现写卡、热拔插恢复、exFAT 或 UHS/1.8 V。

| 信号 | FPGA 引脚 | 方向 |
| --- | --- | --- |
| SD CLK | A14 | 输出 |
| CMD | A13 | 命令发送/响应接收，按阶段控制三态 |
| DAT0 | B14 | 输入 |
| DAT1 | B15 | 输入 |
| DAT2 | A11 | 输入 |
| DAT3 | A12 | 输入；不作为 SPI CS 拉低 |

当前使用 3.3 V、4-bit、50 MHz High Speed。100 MHz 控制域产生 SDCLK，扇区缓冲/握手连接既有 50 MHz 文件处理域。初始化约 200 kHz；识别卡类型、地址单位及 High Speed 能力后才切换速度。不支持 High Speed 时保留原生 25 MHz 路径，不将其称为 High Speed 验收通过。

初始化及读取采用 CMD0/CMD8、CMD55/ACMD41、CID/RCA/选卡、CMD6 查询/切换、ACMD6 4-bit、CMD17 单扇区读取。SDSC 使用字节地址，SDHC/SDXC 使用块地址。命令/响应按各响应类型处理 CRC7，4 根 DAT 分别校验 CRC16；数据进入 512 字节 RAM，整块通过后才交付 FAT32。超时/坏 CRC 有有界重试及错误报告，禁止半坏扇区进入解码器。

本轮保留 CMD17 方案，未加入 CMD18 连续预取。媒体板已删除生产 SPI 驱动与未启用的写卡状态机；历史 SPI 模型、桩和全部回归仍在 `boardtest`，供复盘和回归使用。

规范入口：[SD Association Physical Layer Simplified Specifications](https://www.sdcard.org/downloads/pls/)。源码中的响应位序/CRC 和时序注释是实现参考，不应根据旧 SPI 模型推断原生 SD 行为。

## 已解决的读卡/传输问题

- 相邻普通命令/响应间需留出 8 个完整 SD 时钟。原卡模型立即释放 CMD，曾漏掉该约束；现在卡模型检查该间隔。
- CMD6 状态块、CMD17 数据紧随 R1，接收器不能为等命令间隔而错过数据起始。
- IMG5→IMG0 回卷的实际故障是音频 DATA 无包间排空窗口。图像已正确收到但 PCM 字节不足，最终图音不提交。媒体发送器对图像及音频非末包都保留 100 µs 排空时间，END 前保留 1 ms。
- 25 MHz 诊断构建没有修复回卷；正式实卡验证仍运行 50 MHz High Speed。

SD 按键复位与以太网一次性上电复位分开，避免反复复位已知敏感的网络 IP。卡应在上电前插入。向已处于原生模式的板卡重下载时只使用原生 SD 固件；旧 SPI bit 会改变卡模式，不能混作 A/B 候选。

## SD 验证和诊断

```sh
make -C boardtest sd-native
python scripts/media_sd_diag_probe.py
python scripts/media_sd_board_acceptance.py --images 6 --timeout 45 --settle-seconds 3
```

独立 UDP 工具占用 PC :2，运行前关闭 Web 控制台；保持原有网络配置。`I` 查询的 A6 包报告初始化、SDHC、High Speed 支持/启用、读图和最近扇区耗时，失败时报告状态/原因。实卡内容与镜像不一致时以实卡为准。

原生引脚模型覆盖 SDHC、SDSC、High Speed、25 MHz fallback、1-bit fallback、延迟/丢响应、CRC 错误、重试上限和事务中复位。现有模型从镜像读取 LBA0，其余 LBA 用确定性数据；完整 FAT/BMP/WAV 内容由其他媒体源/历史镜像测试覆盖，不能把 `sd-native` 单项说成全部镜像逐扇区验证。

2026-10-21 的 50 MHz 实板两轮六图验收通过，含四个配对 WAV 提交及两张静音图。PC stub 曾独立逐字节核对 PCM golden；产品 Web D 只重读源图并用零样本音频完成握手，不读取实际播放 PCM。当前变尺寸 D 验收见 [多窗口说明](native_frame_multiview_handoff.md)。

## HC-08

| FPGA 端 | 引脚 | 连接 |
| --- | --- | --- |
| RX | M15 | HC-08 TX |
| TX | L16 | HC-08 RX |

9600 baud、8N1，无 RTS/CTS。USB UART 为独立的 1 Mbps 入口；蓝牙、USB 和 Ethernet 共用控制核，ACK/状态按来源返回，字幕从开头到结束锁定来源。有界命令 FIFO 不接受无限积压。

发送二进制 `[CMD, CMD XOR 0xFF]`，例如 `4E B1` 为下一张、`41 BE` 为轮播开关。手机 TEXT 模式仅发送字符 N（单字节 4E）不构成完整命令。完整表和字幕编码见 [HC-08 / UART 命令](hc08_control_commands.md)。

```sh
make -C boardtest bt-uart-unit
```

测试使用真实 RX 串行波形并解码 TX，覆盖设置、状态、160 字符/清空字幕、坏帧恢复、并发入口和来源路由。蓝牙无线连接与手机软件发送模式由实测确认；独立接收测试工程不属于本仓库产品构建。
