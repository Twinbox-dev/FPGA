# Web 控制台

浏览器通过 Flask 控制媒体板，并显示板卡状态和图像预览。顶栏切换串口或以太网通道。

## 启动

```bash
pip install flask pyserial
python scripts/web_console/app.py
```

默认地址为 `http://127.0.0.1:5000`。以太网目标固定为媒体板 `192.168.137.3:1`，PC 在本机 UDP `:2` 接收回包；界面不提供 IP 输入框，也不要求手动连接。程序启动时自动创建以太网传输。

串口默认 1 Mbps、8N1。唯一可用串口会自动选择并连接；有多个串口时可在折叠的“串口配置与命令说明”中选择。串口由其他程序占用时，需先关闭占用程序。

无硬件开发档：

```bash
WEB_LOOPBACK=1 python scripts/web_console/app.py
```

## 页面布局

- 左侧控制区包含播放、自动轮播、状态查询、转场、OSD、音量、轮播周期、亮度、对比度、频谱和字幕。命令按后端 `/api/keys` 分组生成。
- 串口配置、命令范围说明和板卡回包日志可折叠。
- 右侧显示板卡状态和图像预览。预览区的 **D 获取显示快照**按钮请求当前已提交图像；标签可切换显示板读回快照与媒体板写入流。选择 BMP 后可比较覆盖率、像素差异和黑边差异。
- 滚动字幕支持最多 160 个可打印 ASCII 字符。留空并发送可清除字幕；字幕和三种 OSD 模式都由板卡 ACK 确认。
- 页面没有全局键盘命令监听。键盘输入框和字幕框时不会向板卡发送快捷命令；板卡操作通过界面按钮触发。
- 桌面采用控制与预览双栏；窄屏改为单栏，图像画布按宽度缩放，不产生横向溢出。

## 状态与图像回读

- `0x5A` ACK 更新音量、周期、亮度、对比度、转场和字幕状态。
- `0xA5` 状态显示当前图片、SD/HDMI 锁定、音频欠载、自动轮播等信息。
- `0xA6` SD 诊断显示卡初始化、卡类型、High Speed 状态、整图读卡耗时和最近扇区耗时；错误时显示初始化或读卡原因。
- D 快照和 BMP 对比用显示板 SDRAM 的实际读回数据。写入流预览与读回快照分别保留，便于定位媒体传输和显示存储路径。

## API

- `GET /api/status`：连接、状态与当前帧信息。
- `GET /api/ports`：串口枚举和自动选择结果。
- `GET /api/keys`：命令键和分组。
- `POST /api/cmd`：发送一个命令。
- `POST /api/subtitle`：上传或清除字幕。
- `GET /api/stream`：SSE 推送连接状态、ACK、诊断和帧事件。
- `GET /api/frame`：读取最近的图像帧数据。
- `POST /api/serial/connect`、`POST /api/serial/disconnect`：串口连接控制。
- `POST /api/eth/connect`、`POST /api/eth/disconnect`：以太网传输生命周期接口；目标地址由后端固定。

## 回归

在 `scripts/web_console` 目录运行：

```bash
node test_frame_view.js
python -m unittest test_console_protocol.py -v
node render_ui_screenshots.cjs
```

截图生成器使用本机无头 Chrome，通过本机回环 DevTools 端口验证 1600px 桌面和 390px 窄屏布局、D 按钮、字幕上传及输入文本不发板卡命令。截图保存在 `scripts/web_console/screenshots/console-desktop.png` 和 `console-mobile.png`。
