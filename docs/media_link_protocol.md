# 双板媒体链路协议

本文是媒体板与显示板之间正式媒体/控制包的字段约定。正常播放由媒体板读卡并发送；Ethernet 控制页另提供 PC 直接上传静态图片的旁路入口，使用同一图像/音频事务格式。

## 地址与包头

| 设备 | IPv4 | UDP 端口 |
| --- | --- | --- |
| PC | 192.168.137.1 | 媒体命令发送 1、常规回包监听 2；直接上传使用临时回包端口 |
| 显示板 | 192.168.137.2 | 媒体与控制接收 1 |
| 媒体板 | 192.168.137.3 | PC 命令和显示反馈接收 1 |

正式媒体包头为 `AA BB CC DD TYPE_LO TYPE_HI LEN_LO LEN_HI`，TYPE、LEN 和媒体载荷里的多字节数均小端。V1 PC 控制/显示控制包头为 `AA BB CC DD TYPE_HI TYPE_LO LEN_HI LEN_LO`，TYPE/LEN 大端；命令载荷字段按下文逐字节顺序。两种字节序属于不同报文通道。

媒体板按整包选择目标并在发送期间保持：正式媒体包及显示 SET/状态请求/字幕包发显示板 .2:1；V1 命令 ACK/A5 状态与 D 调试读回发 PC .1:2。正常显示板媒体结果和设置/状态响应发回媒体板 .3:1。PC 直接上传时，由显示板回到该上传 socket 的源地址/端口；当前事务的结果路由在成功 PREPARE 后锁定。

PC 图片上传是正式媒体链路之外的 Ethernet 入口：PC `.1` 直接向显示板 `.2:1` 发送 `0x0020–0x0033`，不经过媒体板。媒体板的 SD 播放和固定 `.3↔.2` 路由不变。该入口面向静态图像事务，不代表已实现 PC 视频流。

## 正式图像流（0x20–0x24）

媒体板发送 BMP 原始宽高的 RGB565 像素，不再传输居中黑边。每个字放两个连续像素，先出现的像素位于低 16 位；保留 BMP 自底向上行序，不做垂直翻转。奇数宽度的行与下一行连续打包；仅当整图像素数为奇数时，末字高 16 位补零。单图在非活动 1280×720 图像区居中填黑；多窗口先等比例缩小至窗口框并补黑，再写入目标槽。显示写入时翻转行序。

| 类型 | 载荷 | 长度/行为 |
| --- | --- | --- |
| 0x0020 READY | 查询载荷为空；显示板应答 1 字节 01 | 媒体板等待显示板 ready 后才读卡发送 |
| 0x0021 BEGIN | frame_id:u16, image_index:u8, flags:u8, total_words:u32, width:u16, height:u16, layout:u8, window:u8, generation:u16 | 16 字节；total_words=ceil(width×height/2)，宽 1–1280、高 1–720；单图 layout/window 为 0，generation 使用 PREPARE 协商值；PC D 快照三者均为 0；PC 直接上传使用 image_index=31、layout/window=0 和 PREPARE generation；flags bit0=上一张方向，bit2:1=特效，bit3=有配对 WAV，bit4=自动轮播状态快照 |
| 0x0022 DATA | frame_id:u16, sequence:u16, N×u32 words | N 从 LEN 计算，1–253；序号从 0 连续递增 |
| 0x0023 END | frame_id:u16, checksum:u32, reserved:u16=0 | 8 字节；前一数据包后等待 1 ms 再发 |
| 0x0024 RESULT | frame_id:u16, result:u8 | 0 单图图像验收并开始音频；1 整图重传；2 图音/布局实际提交完成；3 多窗口一窗已暂存、继续后续窗。显示板对最终 `result=2` 连发三次，间隔 1 ms；媒体板按 frame_id 接收，后续重复包会被忽略 |

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
| 6 / 7 / 8 | 0x36 / 0x37 / 0x38 | 单图 / 左右双图 / 四宫格；多窗口间不能直接互切 |
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

PC 以太网 D 命令请求“当前已提交图像”的正式快照：媒体板从 SD 重读该 BMP，将不含黑边的 `0x0021–0x0023` 原尺寸事务发给 PC `.1:2`。PC 校验后返回图像 RESULT；媒体板再发零样本静音事务 `0x0030/0x0032`，PC 返回音频 RESULT 和最终 RESULT=2。画布按 BEGIN 宽高显示，忽略奇数末字的零填充半像素。快照不写显示板 SDRAM，也不改变显示板当前提交图像。窗口调度锁定焦点源图后才允许快照读取；忙时新的图像/D/布局请求被拒绝，不为它们建立无界队列。

PC 上传图片与 D 快照方向相反：浏览器先解码常见图片格式，服务端将 RGB888 打包为底部向上排列的 RGB565 字，再以同一 `0x0021–0x0024` 格式直接发往显示板。勾选音频时附带 24 kHz/8-bit/mono WAV PCM；未勾选则发送零样本静音事务。Ethernet 上传的节奏和事务限制见 [PC 直接上传说明](pc_direct_image_upload.md)。D 仍读取媒体板 SD 源图，不是 PC 上传图的显示端读回。

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

## 多窗口事务扩展（0x48–0x4A）

窗口 PREPARE/REPLY、VIEW_STATUS 的字段、action/result、代次、黑窗排空、整页 RESULT=3 和最终 RESULT=2 约束统一见 [可变尺寸与多窗口实现](native_frame_multiview_handoff.md#协议与状态)。控制包头 TYPE/LEN 大端，状态体中的 generation/宽高小端。媒体板以 PC V1 type=0x0003（16 字节体）或 USB 0xA7 转发状态；长度区分它与原始像素探针。测试光标 0x004B 属诊断接口，不是产品用户控制命令。


## PC 直接图像上传后的视图同步

PC 上传遵循显示板当前 VIEW_STATUS：PREPARE 沿用当前布局、请求 `window=0xFE` 锁定 HDMI 光标所在窗口，并从 PREPARE 响应取回窗口、布局、代次和 SD 基准索引。BEGIN 复用这个 SD 索引，PC 图像不写入 SD 播放列表；媒体板随后 N/P 从原 SD 项继续。

显示板发 VIEW_STATUS 时保留对发起请求方的回包，并附送一份至媒体板固定地址 `.3:1`。媒体板调度器据此同步布局、代次、有效窗口和 busy，并沿既有状态通路转发到 PC。图像/音频 RESULT 继续使用当前事务所有者路由。这样 PC 直传、媒体板 SD 切图和网页状态显示共享显示板的权威视图状态，不增加新的 BEGIN/DATA 格式。


## PC 上传结果码与多窗口音频

单图写入继续等待图像 `RESULT=0` 后发送音频事务，最后等待 `RESULT=2`。多窗口单窗写入由显示板在目标窗提交（含转场完成）后直接返回 `RESULT=2`，PC 端应把该码作为多窗口上传完成，不能等待不存在的中间 `RESULT=0`。

音频事务仅允许单图布局。PC 界面依据 VIEW_STATUS 禁用多窗口音频；后端在 PREPARE 前复核显示板布局，多窗口带 PCM 时拒绝上传。多窗口无音频包。


## Subtitle Ethernet pacing and ACK diagnostics（字幕以太网转发间隔与 ACK 诊断）

媒体板将字幕 BEGIN、逐字符 DATA、END 包转发到显示板时，当前包间隔恢复为原来的 1 ms（`SUBTITLE_GAP_CYCLES=CLK_HZ/1000`）。显示板要求收到完整、连续的 DATA 序号后才接受 END。2026-10-26 实板复测表明临时改成 4 ms 后 `FPGA_ERR=2` 仍然复现，因此已撤回该节流猜测；4 ms 版本不作为修复或验收版本。

网页字幕 ACK 中，`FPGA_ERR=2` 表示媒体板收到显示板拒绝或提交长度不匹配，并完成三次尝试；`FPGA_ERR=3` 表示等待显示板 ACK 超时。`WIRE` 仍是 PC 声明的 XOR 校验。错误码为 2 时，原 `CALC` 字节改为 `DISPLAY_REJECT` / `DISPLAY_VALUE`：最高位为 1 表示显示板拒绝 END，低 7 位给出首个失败条件；最高位为 0 表示显示板返回成功状态但 ACK 长度不匹配，低 7 位是其返回值。`RX_COUNT` 统计媒体板收到的协议字节，包含长度字节、文本字符及两个校验半字节，不等于文本长度。

显示板 END 拒绝值：`1` BEGIN 未活动、`2` END 长度错误、`3` 序号不匹配、`4` 声明长度不匹配、`5` END 校验字段不匹配、`6` DATA 字符未收全、`7` 显示端 XOR 校验不符、`8` 此前收到非法 DATA、`15` 未分类拒绝。例如 `DISPLAY_REJECT=0x85` 表示显示板 END 的校验字段与 BEGIN 中的声明不符；`0x86` 表示 DATA 数量未达到声明长度。该诊断复用现有 ACK 的 value 字节，不增加网络包。


## 2026-10-25 subtitle retry pacing follow-up

The reported ACK `FPGA_TAG=5 FPGA_ERR=2 SUB_LEN=11 RX_COUNT=14 WIRE=78 CALC=78 COMMIT=NO` means the PC-to-media parser received the declared 11 characters and verified the PC checksum, then exhausted display-side retries. The 14 received protocol bytes are one length byte, 11 text bytes and two checksum nibbles. A 4 ms packet gap was tried and did not change the board failure; it has been reverted. The RTL roundtrip regression now checks successful 13-character commit, a corrupted display END, propagation of the display reject reason to the existing PC ACK, 1 ms spacing and local PC checksum rejection.

After restoring the 1 ms gap and rebuilding both boards with the reason byte, a backend API test sent the same 11-character class of subtitle (`HELLO WORLD`) and received HTTP 200 with `acknowledged=true`; the error did not reproduce. The 4 ms gap candidate had failed the same board test, so the active implementation keeps the original 1 ms interval. The reject-reason path remains available if the failure recurs.
