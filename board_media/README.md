# 媒体板工程

媒体板固定为 192.168.137.3，独立负责 SD/SPI、FAT32、BMP/WAV 解析、播放列表、实体按键、自动轮播和 PC 控制。它不使用 SDRAM 缓存整帧；每张图从卡读取后补成 1280×720 RGB565 正式帧。

网络路由按包类别选择：

- PC Ethernet D 请求当前已提交图片的正式快照并回 PC .1:2；UART D 保留 type=0x0003 原始调试 tap。
- 正式图像/音频包，以及显示侧 SET、STATUS_REQ、字幕 BEGIN/DATA/END 发往显示板 .2:1。
- 显示板的结果/状态包返回媒体板 .3:1；媒体板再按 V1 格式向 PC 回 ACK。
- 目的地址和端口按 mux owner 与控制类型选定，并在包发送期间保持稳定。

TD 工程入口为 board_media/td_project/media_net.al。本目录自包含所用 Ethernet RTL、厂商 IP、SD 读卡 RTL 和约束，不引用显示板目录中的 Verilog。

综合和布局布线：

    cd board_media/td_project/media_net_Runs/syn_1
    run.bat
    cd ../phy_1
    run.bat

路由选择定向仿真见 board_media/sim/tb_media_udp_route.sv。媒体与控制协议字段见 ../docs/media_link_protocol.md、../docs/dual_board_media_plan.md 和 ../docs/dual_board_architecture.md。