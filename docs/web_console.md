# Web 控制台（第一步：串口双控，以太网占位）

浏览器 → Flask（笔记本）→ 串口 → 板卡。以太网控制入口已在前端预留
（双控开关），FPGA 侧落地后切换即用。

## 用法

```bash
pip install flask pyserial
python scripts/web_console/app.py        # 启动后浏览器打开 http://127.0.0.1:5000
WEB_LOOPBACK=1 ...                       # 无板卡开发档（命令回环成假 ACK）
WEB_NOAUTO=1 ...                         # 关掉「唯一串口自动连接」
WEB_BAUD=1000000 ...                     # 默认波特率（也可页面改）
```

串口自动枚举（`serial.tools`）：启动/刷新时列出可用串口（USB-UART 优先排序），
唯一串口时**自动选中并自动连接**（可关）；多个时自动选中第一个，其余下拉切换。

- **双控开关**（页首）：串口控制（现）/ 以太网控制（占位，后端 eth 路由
  返回 501）。切换只改前端请求的 mode 与显示的面板。
- **控制面板**：按键按语义分组（播放/音量/轮播周期/亮度），由后端
  `/api/keys` 下发渲染（单一事实来源，避免两处硬编码漂移）；单键即发 +
  键盘直发 + 按下 hit 动画；页面内嵌可折叠的命令表与 underrun 粘滞位解读。
- **实时指标瓦片**：音量/周期/亮度/img 从 ACK 与状态包文本实时解析刷新
  （带闪烁动画）。
- **板卡回包**：SSE 推流实时滚动——ACK 行（音量/周期/亮度当前值）与
  A5 状态行（系统全景）。协议解码内置在 `app.py`（原 `uart_console.py`
  已并入并删除，本控制台是唯一的 PC 端工具）。
- **自动轮询**（可选开关）：连接后每 1s 自动发 `S`，指标瓦片变成实时仪表。

## 架构（与 FPGA 侧 ctrl_core 分层呼应）

```
浏览器 ──POST /api/cmd{mode,key}──► Flask ── Transport ──► 板卡
        ◄──SSE /api/stream(回包推流)──┤  serial: pyserial（已实现）
                                      └─ eth:   占位（FPGA eth 前端落地后接）
```

- **传输抽象**：`SerialLink`（现）/ `LoopbackLink`（开发档，WEB_LOOPBACK=1）；
  以太网落地时新增 `EthTransport` 并在 `/api/cmd` 的 eth 路由接上——前端与
  `ctrl_core` 均不用改。
- **协议解码内置**：CMDS/HELP/decode_pkt/decode_ack 在 `app.py` 内；
  `/api/keys` 把命令表（含分组）下发给前端渲染。
- **接口约定**：
  - `POST /api/cmd` `{mode:"serial"|"eth", key:"n"}` → `{ok}` / 501(eth)
  - `GET /api/ports` 枚举串口 + 自动选中项；`POST /api/serial/connect`
    （不传 port 则自动选）`|disconnect`
  - `GET /api/keys` 命令表（keys + 分组）
  - `GET /api/stream` SSE：`{type:"pkt",kind:"ack"|"status",text,ts}`
    与 `{type:"link",serial,port}`

## 注意

- **串口独占**：Web 控制台与其他占用串口的程序不能同时打开同一串口。
- 键盘快捷键与页面按钮等价；快速连键时部分 ACK 会丢（板端发送中丢弃请求，
  人手速度不会）。
- 以太网落地顺序建议：FPGA eth 前端（接 ctrl_core）→ 后端 EthTransport →
  本页切模式即用；数据面（图/音上传）走 `frame_fifo_write`，与本控制面互不影响。
