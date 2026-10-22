# 双板媒体链路协议

本文是媒体板与显示板之间正式媒体/控制包的字段约定。PC 只在测试时代接显示侧应用逻辑；正常双板运行不要求 PC 转发媒体数据。

## 地址与包头

| 设备 | IPv4 | UDP 端口 |
| --- | --- | --- |
| PC | 192.168.137.1 | 命令发送 1；回包监听 2 |
| 显示板 | 192.168.137.2 | 媒体与控制接收 1 |
| 媒体板 | 192.168.137.3 | PC 命令和显示反馈接收 1 |

正式媒体包头为 `AA BB CC DD TYPE_LO TYPE_HI LEN_LO LEN_HI`，TYPE、LEN 和媒体载荷里的多字节数均小端。V1 PC 控制/显示控制包头为 `AA BB CC DD TYPE_HI TYPE_LO LEN_HI LEN_LO`，TYPE/LEN 大端；命令载荷字段按下文逐字节顺序。两种字节序属于不同报文通道。

媒体板按整包选择目标并在发送期间保持：正式媒体包及显示 SET/状态请求/字幕包发显示板 .2:1；V1 命令 ACK/A5 状态与 D 调试读回发 PC .1:2。显示板的媒体结果和设置/状态响应发回媒体板 .3:1。

## 正式图像流（0x20–0x24）

媒体板发送 BMP 原始宽高的 RGB565 像素，不再传输居中黑边。每个字放两个连续像素，先出现的像素位于低 16 位；保留 BMP 自底向上行序，不做垂直翻转。奇数宽度的行与下一行连续打包；仅当整图像素数为奇数时，末字高 16 位补零。显示板在非活动 1280×720 图像区居中填黑，写入时翻转行序。

| 类型 | 载荷 | 长度/行为 |
| --- | --- | --- |
| 0x0020 READY | 查询载荷为空；显示板应答 1 字节 01 | 媒体板等待显示板 ready 后才读卡发送 |
| 0x0021 BEGIN | frame_id:u16, image_index:u8, flags:u8, total_words:u32, width:u16, height:u16, layout:u8, window:u8, generation:u16 | 16 字节；total_words=ceil(width×height/2)，宽 1–1280、高 1–720；当前单图 layout/window/generation 均为 0；flags bit0=上一张方向，bit2:1=特效，bit3=有同名 WAV 候选，bit4=自动轮播状态快照 |
| 0x0022 DATA | frame_id:u16, sequence:u16, N×u32 words | N 从 LEN 计算，1–253；序号从 0 连续递增 |
| 0x0023 END | frame_id:u16, checksum:u32, reserved:u16=0 | 8 字节；前一数据包后等待 1 ms 再发 |
| 0x0024 RESULT | frame_id:u16, result:u8 | 0 图像验收并开始音频；1 整图重传；2 图音提交完成。显示板对最终 `result=2` 连发三次，间隔 1 ms；媒体板按 frame_id 接收，后续重复包会被忽略 |

DATA 校验为全部实际传输字相加（包括奇数末字的零高半字），32-bit 无符号溢出回绕；不含包头、BEGIN 元数据或序号。正常满片 253 字，总 UDP 载荷 1024 字节；最后一片按剩余字数发送。1280×720 共有 1822 个 DATA 包，较小源图按实际字数减少。接收端发现序号缺口、字数不等或累计和失配时不提交非活动缓冲，回 RESULT 1；发送端最多完整读取并发送三次。

媒体板普通非末尾 IMAGE_DATA 包后至少等待 100 µs（125 MHz 下 12,500 拍）；显示侧生成上下/侧边黑像素时，发送端还按源宽高留出填黑排空时间，具体见 `media_image_tx` 的分阶段间隔计算。最后 DATA 后至少等待 1 ms 再发 END。显示接收器使用 253 字包缓存和 512 字异步 FIFO；本地补黑也必须遵守写 FIFO 的 reset-release 与 ready，不能因黑字不来自网络而绕过反压。包间隔用于接收排空，不代表千兆物理带宽不足。

显示端 IMAGE_DATA/END 检查原因随 RESULT 低四位返回：`0x11` 帧号/状态、`0x12` END 长度或 reserved、`0x13` 字数、`0x14` 校验和、`0x15` 本帧先前包无效、`0x16` 接收器仍在排空前一包。媒体板最多重试整图三次；最终 S 状态中的 error=9–14 对应上述六种原因。

## 配对 PCM（0x30–0x33）

媒体板按 FAT 目录中 8.3 basename 匹配 BMP/WAV。合法 WAV 是 24 kHz、8-bit unsigned、单声道 PCM；网络发送 WAV data 块原始样本，不带文件头、不扩展为 24-bit。显示板在缓冲后按 V1 节拍上采样/输出。

| 类型 | 载荷 | 长度/行为 |
| --- | --- | --- |
| 0x0030 AUDIO_BEGIN | frame_id:u16, sample_count:u32, reserved:u16=0 | 8 字节，sample_count 为有效样本字节数 |
| 0x0031 AUDIO_DATA | frame_id:u16, sequence:u16, samples[] | 1–1012 个 PCM 字节，尾片不补有效样本 |
| 0x0032 AUDIO_END | frame_id:u16, checksum:u32, reserved:u16=0 | 8 字节；最后 DATA 后等待 1 ms |
| 0x0033 AUDIO_RESULT | frame_id:u16, result:u8 | 0 成功；1 仅重读并重发音频 |

音频校验为有效 PCM 字节之和，32-bit 无符号回绕；不含头、帧号、序号和对齐填充。没有同名或格式不支持的 WAV 时发送零样本事务：BEGIN、END、RESULT，不发送 DATA，checksum 为 0。图像已验收后出现音频错误，只重传音频。

## PC V1 命令与媒体侧回包

PC 发给媒体板的 V1 type 0x0001 载荷为 [CMD, CMD XOR 0xFF]。网页小写字母由 app.py 映射到表中的大写 ASCII 命令字节。

| 按键 | CMD | 行为 |
| --- | ---: | --- |
| n / p | 0x4E / 0x50 | 下一张 / 上一张 |
| a | 0x41 | 自动轮播开关 |
| s | 0x53 | 请求显示板状态；媒体板合并状态后回 PC |
| + / - | 0x2B / 0x2D | 音量加 / 减 |
| ] / [ | 0x5D / 0x5B | 亮度加 / 减 |
| . / , | 0x2E / 0x2C | 对比度加 / 减 |
| > / < | 0x3E / 0x3C | 轮播周期加 / 减 |
| 0 / 1 / 2 | 0x30 / 0x31 / 0x32 | 直接切 / 交叉溶解 / 柔边滑动 |
| 3 / 4 / 5 | 0x33 / 0x34 / 0x35 | OSD 关闭 / 调节后 3 秒 / 常显 |
| q | 0x51 | 频谱开关 |
| ' / ; | 0x27 / 0x3B | 频谱灵敏度加 / 减 |
| d | 0x44 | 媒体侧原始 BMP 调试读回 |
| l | 0x4C | 保留 UI 按键；按约定 FPGA 不返回有效响应 |

媒体板顶层把 Ethernet/UART 的 `n` / `p` 交给 `media_control_core`，由其产生单周期切图脉冲；不要再把同一份原始 N/P 命令并行送给 `media_image_tx`，否则会把一次按键排成多次切图。实体按键另走同步去抖路径；去抖器在启动后须先确认稳定释放，再允许按下事件。

媒体板 V1 type 0x0002 回包载荷为 8 字节：5A, cmd, volume, period_s, image_index, wav_flag, levels, flags。S 还会先返回 A5 状态，载荷为 A5, media_state, fat_state, flagA, flagB, underrun, image_index, wav_flag，再返回 5A 命令 ACK。

## 显示设置、状态与字幕（0x40–0x46）

控制 TYPE/LEN 大端，载荷按下表顺序编码：

| 类型 | 载荷 | 含义 |
| --- | --- | --- |
| 0x0040 SET | sequence:u8, op:u8, value:u8, reserved:u8=0 | 显示设置，value 为绝对值 |
| 0x0041 ACK | sequence:u8, op:u8, status:u8, applied_value:u8 | status 0 成功，1 拒绝 |
| 0x0042 STATUS_REQ | sequence:u8 | 查询显示侧状态 |
| 0x0043 STATUS | sequence, volume, brightness, contrast, effect, osd, spectrum, sensitivity | 8 字节状态 |
| 0x0044 SUBTITLE_BEGIN | sequence, length, checksum | length 0–160 |
| 0x0045 SUBTITLE_DATA | sequence, offset, ascii_byte | 每包一个字符 |
| 0x0046 SUBTITLE_END | sequence, length, checksum | 显示侧验收后以 0x0041、op=8 回 ACK |

0x0040 的操作码：1 音量 0–8，2 亮度 0–8，3 对比度 0–6，4 特效 0–2，5 OSD 0–2，6 频谱 0/1，7 频谱灵敏度 0–3。

PC 到媒体板的 V1 字幕仍用 T 字节流：0x54、length XOR 0x80、各 ASCII 字节 bit7 置位、校验和高/低半字节分别 bit7 置位；每字节与其反码成对发送。媒体板校验后再生成 BEGIN/DATA/END。校验为 length 与各文本字节的 XOR。只在显示侧成功 ACK 后，媒体板向 PC 回 T 的 V1 ACK。

本组控制包的 TYPE/LEN 字节序始终是 V1 大端：例如 `0x0042`、长度 1 在线路上为 `00 42 00 01`。媒体板的 `eth_front` 使用该格式；显示板控制接收器以及 `0x0041` ACK、`0x0043` STATUS 发送器也必须按同一格式解析和生成。不要把正式媒体流 `0x0020–0x0033` 的小端包头规则套用到这里。该区分已加入控制收发仿真。

## 调试探针与发送完成

PC 以太网 D 命令请求“当前已提交图像”的正式快照：媒体板从 SD 重读该 BMP，将不含黑边的 `0x0021–0x0023` 原尺寸事务发给 PC `.1:2`。PC 校验后返回图像 RESULT；媒体板再发零样本静音事务 `0x0030/0x0032`，PC 返回音频 RESULT 和最终 RESULT=2。画布按 BEGIN 宽高显示，忽略奇数末字的零填充半像素。快照不写显示板 SDRAM，也不改变显示板当前提交图像。普通下一张/上一张/自动切换优先，PC 快照在媒体链路空闲后处理。

媒体板 UART D 保留原始 BMP 调试 tap `type=0x0003`，不参与正式图像提交。网页 D 正式快照仍走媒体板 SD 重读路径。显示板曾有独立 SDRAM 读回 `type=0x0004` 诊断探针；它与正式 PC 快照用途重复，已在双板资源优化中移除。移除该硬件探针不影响网页 D 按钮。

eth_front 的发送完成 toggle 在 UDP mux 返回 ready 后回传；mux 仲裁时先等 `stack_ack` 再发送。包的 owner、目的 IP/端口和长度必须保持到下一个真实 grant，不能在应用层最后一个字节时改成下一个请求的字段：UDP/MAC 此时可能仍在排空。控制回复长度由 eth_front 在 ACK 时发布，因此在首个有效数据拍锁存；媒体长度在 grant 时已稳定。PC D 发送期间，即使后台排队 SET/状态请求，也不能改变当前 DATA 的目的地址。这两条约束分别由 `display-mux-lifetime` 和 `media-route` 仿真覆盖。

## PC 媒体模拟器对接显示板

`scripts/pc_display_media_probe.py` 临时扮演媒体板，向显示板发送正式 `0x20–0x33` 图像/PCM 事务，在 PC 侧检查事务 RESULT、控制回包、状态和字幕。测试显示板时只需将 `MEDIA_PEER_IP=192.168.137.1`、`MEDIA_PEER_PORT=2`；PC 在 `.1:2` 接收正式回包。该模拟脚本不读取显示板 SDRAM；正式 PC D 快照仍由媒体板提供，像素画面由 HDMI 板级确认。网页的 D 命令及 OSD 三种模式属于产品控制功能，均保留在正式媒体链路中。

```powershell
python scripts/pc_display_media_probe.py --bmp img/golden/IMG1.BMP --wav img/wav/IMG001.WAV
python scripts/pc_display_media_probe.py --bmp img/golden/IMG3.BMP --wav img/wav/no-paired-file.wav --frame-id 0x2402
```

PC 显示板模拟通过后，正式双板参数应恢复为 `MEDIA_PEER_IP=192.168.137.3`、`MEDIA_PEER_PORT=1`。

## PC 模拟显示端测试媒体板

`scripts/pc_media_display_stub.py` 临时扮演显示端，并可在媒体板首次提交后自动发 V1 D，检查正式 PC 快照是否走完第二个事务。测试媒体 bit 将 `DISPLAY_IP` 临时设为 `.1`、`DISPLAY_UDP_PORT` 设为 `2`；PC stub 绑定 `.1:2`，接收 READY/图像/PCM 并返回结果。

```powershell
python scripts/pc_media_display_stub.py --card-image img/card_user_real.img --frames 1
python scripts/pc_media_display_stub.py --card-image img/card_user_real.img --frames 2 --request-snapshot
```

`--card-image` 从 raw MBR/FAT32 卡镜像读取 WAV 并逐字节比较。IMG1 的 460,800 个图像字和 720,000 个 PCM 样本已与 BMP/WAV golden 完全匹配；第二条命令再验证正式 D 快照。测试后恢复媒体板目标 `.2:1` 并重新综合 bit。

## Runtime CV image effects

The display-board `0x0040 SET` operation 9 selects an HDMI-only image effect. Values are absolute and the display applies the value at the next input frame boundary.

| Value | Effect | Legacy PC/UART key |
| ---: | --- | --- |
| 0 | Original RGB pass-through (default) | R |
| 1 | Grayscale | G |
| 2 | Binary threshold | B |
| 3 | Sobel gradient | E |
| 4 | Sharpen | H |
| 5 | Moving snow | W |

The existing 8-byte V1 ACK and A5 status layouts are unchanged. In non-subtitle ACKs and normal A5 status packets, the upper three bits of `image_index` carry the current CV mode and the lower five bits retain the image index. For display `0x0043 STATUS`, the upper three bits of the `volume` byte (`[6:4]`) carry CV mode while `[3:0]` remain volume. Bit 7 remains zero. Subtitle ACK `image_index` remains the subtitle RX count.
