# 媒体板工程

媒体板固定为 192.168.137.3、JTAG cable1，负责原生 4-bit 50 MHz SD 只读、FAT32、BMP/WAV 配对、播放列表、实体按键、轮播、USB UART、HC-08 和 PC 以太网控制。

不使用 SDRAM 缓存整帧；传输 BMP 原始宽高的 RGB565，居中补黑和多窗口双线性缩小由显示板完成。图像/PCM、绝对设置、字幕和窗口准备请求发送到显示板 .2:1；V1 ACK/状态与按需 D 源图快照发往 PC .1:2。目的地址在整包发送期间保持。

TD 入口是 `td_project/media_net.al`，Ethernet、厂商 IP、SD 和约束在本目录自包含。综合/布局/下载命令见 [TD CLI 指南](../docs/td_cli_programming.md)。正式下载顺序为显示板 cable0 后媒体板 cable1；只重烧显示板后媒体端可能仍保留旧提交状态。

[系统架构](../docs/dual_board_architecture.md) · [板间协议](../docs/media_link_protocol.md) · [SD 与 HC-08](../docs/native_sd_hc08.md) · [多窗口](../docs/native_frame_multiview_handoff.md) · [验证](../docs/verification.md)
