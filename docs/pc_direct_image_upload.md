# PC 直接上传图片到显示板

Ethernet 控制页现在可以把本地图片直接发送给显示板 `.2:1`。媒体板 `.3` 不参与这笔图像事务；常规 SD 播放、控制和 D 快照仍按原媒体链路工作。

## 数据处理

浏览器使用 `createImageBitmap` 解码常见图片格式，再用 Canvas 转成 RGB888。透明像素先合成到黑底；大于 1280×720 的图片按比例缩小到显示上限，小图不放大。浏览器通过 `POST /api/eth/upload-image` 发送 RGB 数据和宽高。

后端将 RGB888 打包成现有图像协议使用的 RGB565：按 BMP 自底向上的行序传输，每个 32-bit 字包含两个像素，先出现的像素在低 16 位；奇数像素的最后一个字高 16 位补零。校验和为所有传输字的 32-bit 无符号累加。

显示板用现有 `media_protocol_rx`、窗口准备仲裁和 SDRAM 写入路径接收该帧。单图上传通过 PREPARE 进入布局 0；当前在多窗口时会按既有规则返回单图。媒体板仍用固定对端 `.3:1`；显示板对 PC 直接事务学习当前请求的源地址，单图 PREPARE 成功后锁定该事务的返回端点，直到图像/音频提交结果返回。忙时收到的其他 PREPARE 仍回复给它各自的请求端。

上传使用独立的 PC UDP 临时端口，避免占用控制和媒体回包使用的本机 `:2`。显示板仍在 `.2:1` 接收数据，所有数据包头、字段和 RESULT 与媒体板正式链路一致。

## 音频选项

当前 Ethernet 页仅在单图模式允许勾选音频，支持既有 24 kHz、8-bit unsigned、单声道 WAV，或由本机 FFmpeg 从 MP4 等文件提取音轨；PC 限制最多 60 秒。后端只发送 PCM 样本。未勾选时发送零样本事务。后续段落保留首版逐步演进的记录，音轨细节见“MP4 音轨输入”。

首版曾使用伪索引 31，现已改为保留 PREPARE 返回的 SD 索引，具体见“多窗口更新与状态同步”；图片仍为临时显示内容，不进入 SD 列表。校验成功后按布局返回相应 RESULT，最终 RESULT=2 才表示提交。D 仍从媒体板 SD 重读源图，不代表 PC 上传图片。

## 发送节奏与事务超时

板级测试发现 DATA 包间隔 0.5–3.5 ms 时会出现显示板收到的字数不完整。4 ms 间隔下，完整帧能通过；1280×720 约发送 1,822 个 DATA 包，需要约 8.3 秒。显示板窗口事务原有 8 秒看门狗会在传输结束前触发，因此将其延长到 16 秒。PC 上传节奏默认为 4 ms，每帧仍使用现有最大 253 个 32-bit 字的数据包。

这个传输方式用于静态图片，不是视频流。未来 PC 直传视频可以复用显示板的 PC 对端回包路由，但需要单独设计持续帧的接收/显示节奏；不能直接沿用本次为可靠图片提交设置的 4 ms 间隔。

## 验证记录（首版历史）

- Python 验证 RGB565 打包方向、校验和、奇数像素补零、WAV 格式检查、Flask multipart 接口和协议往返；`test_media_upload.py`、`test_view_status.py`、`test_frame_view.js` 均通过。
- Verilator：`display-udp-lite`、`media-tx`、`media-display-path`、`view-control-path`、`media-display-full-frame` 均通过。UDP 仿真覆盖 PC ARP 应答、PC 源 MAC/IP/端口学习及动态目的 MAC 回包。
- 显示板新 bit 下载至 cable 0 SRAM。PC 直接上传 IMG5（640×480）静音事务成功；IMG1（1280×720）静音事务和 24 kHz/8-bit/mono 配对 WAV 事务都收到最终 RESULT=2。Flask 上传路由也实际发送 IMG5 并收到 RESULT=2。
- 同一 TD 设置下，本轮显示板 route 报告为 15,160 LUT、8,639 slices、35 BRAM9K、11 BRAM32K、18 DSP；保存的上传前报告为 14,810 LUT、8,450 slices。差值约 +350 LUT、+189 slices。最终 setup WNS 从 −5.858 ns 到 −6.294 ns，hold WNS 均为 −3.188 ns；本轮没有引入新的时序修复。
- HDMI 画面和扬声器声音尚未由人眼/听感确认；板级事务回执证明数据与提交链路完成，不能替代显示效果确认。


## 多窗口更新与状态同步

PC 上传先读取显示板 VIEW_STATUS，再用当前布局发送 PREPARE，窗口字段设为 `0xFE`，由显示板按 HDMI 光标位置锁定目标窗口。PREPARE 成功返回目标窗口、布局、代次和该窗原有 SD 图片索引；图像 BEGIN 使用这些返回值。单图模式更新整屏，多窗口模式只更新锁定窗口，保持现有布局和窗口切换行为。

PC 图片是临时显示内容，不属于 SD 播放列表。BEGIN 保留 PREPARE 返回的 SD 索引，不再写入伪索引 `31`。媒体板之后按上一张/下一张时，从上传前该窗口对应的 SD 项继续计算。

显示板对 VIEW_STATUS 保留请求来源回包，同时额外发送一份到媒体板固定地址 `.3:1`。媒体板的 `media_view_scheduler` 用该状态同步布局、代次、窗口索引和 busy；它再通过现有状态转发路径向 PC 发布。图像与音频事务 RESULT 仍按成功 PREPARE 锁定的来源路由，因此 PC 上传的完成回执仍返回 PC。

上传期间 PC 前端禁用图像/布局控制；显示板 PREPARE 仍是最终 busy 仲裁，若媒体板正在进行切图，PC 请求会收到拒绝并结束本次上传，不会并行写 SDRAM。

## MP4 音轨输入

以太网上传页接受 WAV 或含音轨的媒体文件。WAV 继续校验既有格式；其他音轨由本机 FFmpeg 解码第一条音轨，输出为 24 kHz、8-bit unsigned、mono PCM WAV。命令使用 `-map 0:a:0 -vn -t 60 -ac 1 -ar 24000 -c:a pcm_u8`，只保留前 60 秒；WAV 输入也由 PC 限制到前 60 秒。板间音频包格式和 FPGA 音频接收 RTL不变。PCM 上限为 1,440,000 个样本。

FFmpeg 查找顺序为 `FFMPEG` 环境变量、系统 PATH、当前开发机的 `D:\SDK\ffmpeg\ffmpeg.exe`。进程参数以数组传递，不经 shell；临时文件自动清理。压缩输入最大 512 MB，WAV 输入最大 32 MB。

## 本轮验证

- PC 上传协议单测验证：多窗口 PREPARE 保持布局并锁定窗口、BEGIN 沿用 SD 索引、奇数像素补零和 60 秒 PCM 截断。
- Verilator `media-tx`、`view-control-path`、`media-display-path` 通过；新增检查确认 VIEW_STATUS 同时回到请求方并发往媒体板固定 peer。
- 用本机 FFmpeg 生成 61 秒 MP4（含 AAC 音轨），转换结果正好为 1,440,000 个 PCM 样本。
- 新增 RTL 的 TD CLI 综合、布局布线和 bitgen 完成。当前显示板报告：15,254 LUT / 19,600、10,173 寄存器、35 BRAM9K、11 BRAM32K、18 DSP；最终 WNS setup -5.884 ns、hold -2.923 ns。相对本工作区上一份直接上传报告（15,160 LUT，setup -6.294 ns、hold -3.188 ns），本次 +94 LUT，setup/hold 均略有改善；BRAM/DSP 不变。
- cable 0 显示板 SRAM 下载通过：`scripts/program_sram.ps1 -Board display`，日志 `boardtest/captures/sram_download/program_display_20261025_224522.log`。普通沙箱先报 USB device open error；按仓库记录在非沙箱普通用户进程重试后，出现 `Chip validation success`、`program -cable 0 -mode svf -spd 8 -p` 完成及下载验证成功。未使用 UAC，写入 SRAM。
- 下载后尝试只读 READY/VIEW_STATUS 网络探测，显示板 `.2:1` 未回包，媒体板状态也未收到；因此本轮尚未完成板级图像事务、HDMI 和音频确认。Python/Verilator 与 FFmpeg 转码测试通过。


## 多窗口回执与音频限制修正

多窗口单窗更新以最终窗口提交 `RESULT=2` 作为成功回执，不等待单图模式才有的中间 `RESULT=0`。因此网页可以在多窗口转场提交后正常结束上传，不会把已显示的图片报成 `0x0024` 超时。单图仍按 `RESULT=0`、音频事务、最终 `RESULT=2` 的顺序完成。

音频选项只在以太网、连接有效且 VIEW_STATUS 确认为单图时可用。进入双图/四宫格后，前端取消已选音频并禁用选项；后端在发送 PREPARE 前检查布局，发现多窗口带 PCM 就拒绝，避免发送任何音频包。上传成功或失败后，后端都会查询一次权威 VIEW_STATUS，使网页 busy 状态和字幕控件及时恢复。

定向回归覆盖多窗口只收最终 RESULT=2、单图仍发送音频事务、多窗口音频拒绝以及完成后刷新 VIEW_STATUS。

## 2026-10-26 live board regression

The web backend connected to media `192.168.137.3:1` and sent images directly to display `192.168.137.2:1`. The display bit on cable0 was the previously validated current worktree build; the media bit on cable1 was rebuilt after adding a bounded image-source stall recovery path. SRAM download used the repository script; the successful media run is recorded in `boardtest/captures/sram_download/program_media_20261026_015312.log`.

The live API checks passed:

- A 160x90 temporary PC RGB image committed in single-image mode without changing the SD image index. N then P selected the next SD image and restored the prior SD image.
- In double view, PC upload targeted the HDMI cursor's second window. The SD indices and layout stayed intact; N/P changed and restored only that window.
- The same check passed in four view, targeting window four. The other window indices stayed intact and N/P restored the target window.
- Direct, fade and slide transitions each received their expected board ACK. Single, double and four-view N/P transactions all returned idle with the expected valid-window mask.
- A 2,400-sample silent PCM WAV committed with a PC image. Subsequent SD N/P worked.
- D returned 181,440 words for the active 504x720 IMG3 image with zero gaps; the complete byte stream matched `img/golden/IMG3.BMP` exactly.

After the regression, the S status packet reported media TX idle and no latched board error or video-underrun flag. This packet is not a pixel capture and cannot detect a one-frame HDMI color flash. The transition line reader, window-page commit and SDRAM drain paths were also covered by `transition-unit`, `view-session`, `view-framepath`, `view-scan-address`, `view-write-address` and `transitionpair` simulations; all passed.
