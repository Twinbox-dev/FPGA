# 媒体板工程

本目录用于第二块 HX4S20C 的自包含 TD 工程。目标职责是 TF/SD、FAT32、
BMP/WAV 解析、播放列表、PC 控制和板间媒体发送；显示板工程在
[`../board_display/`](../board_display/) 中。

当前仅建立目录与 [双板实施边界](../docs/dual_board_architecture.md)，尚无
可综合的媒体板 RTL 或 bit。后续工程会自带所需厂商 IP 与以太网源码，不依赖
显示板目录中的 Verilog 文件。
