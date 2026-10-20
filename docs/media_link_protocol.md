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

所有 BMP 先由媒体板生成完整的 1280×720 RGB565 帧，含居中黑边，总计 460800 个 32-bit 字。每个字放两个像素，先出现的像素位于低 16 位；媒体板保留 BMP 自底向上行序，不做垂直翻转。

| 类型 | 载荷 | 长度/行为 |
| --- | --- | --- |
| 0x0020 READY | 查询载荷为空；显示板应答 1 字节 01 | 媒体板等待显示板 ready 后才读卡发送 |
| 0x0021 BEGIN | frame_id:u16, image_index:u8, flags:u8, total_words:u32 | 8 字节；total_words=460800；flags bit0=上一张方向，bit2:1=特效，bit3=有同名 WAV 候选; bit4=自动轮播状态快照 |
| 0x0022 DATA | frame_id:u16, sequence:u16, N×u32 words | N 从 LEN 计算，1–253；序号从 0 连续递增 |
| 0x0023 END | frame_id:u16, checksum:u32, reserved:u16=0 | 8 字节；前一数据包后等待 1 ms 再发 |
| 0x0024 RESULT | frame_id:u16, result:u8 | 0 图像验收并开始音频；1 整图重传；2 图音提交完成 |

DATA 校验为全部有效像素字按流序相加，32-bit 无符号溢出回绕；不含包头、BEGIN 元数据或序号。正常满片 253 字，总 UDP 载荷 1024 字节；最后一片按剩余字数发送。完整帧共有 1822 个 DATA 包。接收端发现序号缺口、字数不等或累计和失配时不提交非活动缓冲，回 RESULT 1；发送端最多完整读取并发送三次。

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

## 调试探针与发送完成

D 的 type 0x0003 原始 BMP 调试流独立于正式媒体类型；显示侧 type 0x0004 读回也不作为正式帧。媒体 UDP mux 按整包仲裁。

eth_front 的 tx_done_tog 在控制包全部通过 UDP mux 且 mux 再次 ready 后才翻转；mux 空闲时等旧 stack_ack 拉低。核心收到该完成沿后才启动同一事务的下一包。此握手使 A5/5A 和字幕多包事务都可靠串行。
## PC 媒体模拟器对接显示板

`scripts/pc_display_media_probe.py` 可临时替代媒体板，向显示板发送正式 `0x20–0x33` 图像/PCM 包，并在 PC 侧检查 RESULT、控制回包与 SDRAM D 探针采样。测试 bit 的显示板参数为 `MEDIA_PEER_IP=192.168.137.1`、`MEDIA_PEER_PORT=2`、`PC_RETURN_PORT=3`；PC 接收 formal replies 于 `.1:2`、D 读回于 `.1:3`。发送 IMG1/WAV、无 WAV 的 IMG3 的示例：

```powershell
python scripts/pc_display_media_probe.py --bmp img/golden/IMG1.BMP --wav img/wav/IMG001.WAV
python scripts/pc_display_media_probe.py --bmp img/golden/IMG3.BMP --wav img/wav/no-paired-file.wav --frame-id 0x2402 --capture-prefix boardtest/captures/display_pc_probe_nowav
```

PC 单板验证完成后，显示板正式双板参数须恢复为 `MEDIA_PEER_IP=192.168.137.3`、`MEDIA_PEER_PORT=1`、`PC_RETURN_PORT=2`。正式网络地址与端口见本文前表。
## PC 模拟显示端测试媒体板

`scripts/pc_media_display_stub.py` 在单板验收时模拟显示端，接收媒体板发送到 PC UDP 端口。测试媒体 bit 将 `DISPLAY_IP` 临时设为 `.1`、`DISPLAY_UDP_PORT` 设为 `2`；PC stub 在 `.1:2` 监听，响应 READY，并在图像/PCM 完成后回复 RESULT。

```powershell
python scripts/pc_media_display_stub.py --card-image img/card_user_real.img --frames 1
```

`--card-image` 从 raw MBR/FAT32 卡镜像读取 WAV 并比较 PCM 字节。IMG1 实测发送 460,800 个图像字及 720,000 个 PCM 样本，与 IMG1.BMP 和卡镜像中的 IMG1.WAV 完全一致，事务以 RESULT=2 提交。测试后必须将媒体板正式目标恢复为显示板 `.2:1`。

D 命令继续使用 V1 原始 BMP 调试流 `type=0x0003`，可单独抓取并对比：

```powershell
python scripts/pc_media_d_probe.py --board-ip 192.168.137.3 --pc-ip 192.168.137.1
```

实测收到 1,822 个包、460,800 个字、序号缺口 0，重组像素与 IMG1 原始 RGB565 完全一致。D 是媒体侧诊断通路，不替代显示板 HDMI 上的图像提交。