# Web 控制台（串口 / 以太网双控）

浏览器 → Flask（笔记本）→ 串口或以太网 → 板卡。页首双控开关切换传输，
两条链路**各自独立连接**，切换只改请求路径与显示的面板。

## 用法

```bash
pip install flask pyserial
python scripts/web_console/app.py        # 启动后浏览器打开 http://127.0.0.1:5000
WEB_LOOPBACK=1 ...                       # 无板卡开发档（命令回环成假 ACK）
WEB_NOAUTO=1 ...                         # 关掉「唯一串口自动连接」
WEB_BAUD=1000000 ...                     # 默认波特率（也可页面改）
WEB_ETH_BOARD=192.168.137.2 ...          # 以太网模式默认板卡 IP（页面也可改）
WEB_ETH_LOCAL_PORT=2 ...                 # 本机收板卡回包的 UDP 端口
```

**以太网模式**：本机网卡需有 `192.168.137.1/24`（子网掩码 255.255.255.0），
网线直连板卡后点「连接」。板卡固定回包到 `192.168.137.1:2`，本机 bind :2
收包；首次连接 Windows 防火墙会询问放行 python 监听 UDP，需选「允许」。
板卡侧 UDP 无连接握手，收不到 ACK 先查网线、IP 网段与防火墙。

串口自动枚举（`serial.tools`）：启动/刷新时列出可用串口（USB-UART 优先排序），
唯一串口时**自动选中并自动连接**（可关）；多个时自动选中第一个，其余下拉切换。

- **双控开关**（页首）：串口控制 / 以太网控制。两通道各自连接（`connState`
  分别记录），切换时连接态与面板同步切换，互不干扰。
- **控制面板**：按键按语义分组（播放/音量/轮播周期/亮度·对比度），由后端
  `/api/keys` 下发渲染（单一事实来源，避免两处硬编码漂移）；单键即发 +
  键盘直发 + 按下 hit 动画；页面内嵌可折叠的命令表与 underrun 粘滞位解读。
- **实时指标瓦片**：音量/周期/**亮度·对比度(合成一格)**/img/**自动轮播(开/关)** 从 ACK 与状态包文本
  实时解析刷新（带闪烁动画）。自动轮播状态取自板端遥测（ACK 的 flags 字节 bit0 /
  状态包 flagB bit4，见 docs/ethernet.md），同时会给控制面板里的 **A 按钮加高亮**
  （`.on` 类），一眼看出轮播是否开着。**新前端配旧 bit 会恒显示"关"**，需一起更新。
- **板卡回包**：SSE 推流实时滚动——ACK 行（音量/周期/亮度当前值）与
  A5 状态行（系统全景）。协议解码内置在 `app.py`（原 `uart_console.py`
  已并入并删除，本控制台是唯一的 PC 端工具）。
- **自动轮询**（可选开关）：连接后每 1s 自动发 `S`，指标瓦片变成实时仪表。

## 架构（与 FPGA 侧 ctrl_core 分层呼应）

```
浏览器 ──POST /api/cmd{mode,key}──► Flask ── Transport ──► 板卡
        ◄──SSE /api/stream(回包推流)──┤  serial: pyserial
                                      ├─ eth:    UDP socket（直连板卡）
                                      └─ loopback: 开发回环（WEB_LOOPBACK=1）
```

- **传输抽象**：三个传输实现同一套接口（`open/close/is_open/send_key/
  subscribe/link_msg`）。`SUBS` 是**两条链路共享的订阅表**，任一链路广播都
  推给所有 SSE 订阅者——前端不必知道后端有几个传输。
  - `SerialLink`：pyserial 独占 + 读线程按 A5/5A 成帧解码；
  - `EthTransport`：UDP socket，bind 本机 `:2` 收包、发往板卡 `:1`；
    收 UDP 报文后剥 8 字节应用头（`AA BB CC DD`）再解码；
  - `LoopbackLink`：无板卡开发档，命令回环成假 ACK。
- **协议解码内置**：CMDS/HELP/decode_pkt/decode_ack 在 `app.py` 内；
  `/api/keys` 把命令表（含分组）下发给前端渲染。
- **接口约定**：
  - `POST /api/cmd` `{mode:"serial"|"eth", key:"n"}` → `{ok}` / 400(未连接)
  - `GET /api/ports` 枚举串口 + 自动选中项；`POST /api/serial/connect`
    （不传 port 则自动选）`|disconnect`
  - `POST /api/eth/connect` `{board}` `| /api/eth/disconnect`
  - `GET /api/keys` 命令表（keys + 分组）
  - `GET /api/stream` SSE：`{type:"pkt",kind:"ack"|"status",text,ts}`
    与 `{type:"link",mode:"serial"|"eth",connected,serial(兼容),port}`；
    开流时两条链路的状态各推一条

## 注意

- **串口独占**：Web 控制台与其他占用串口的程序不能同时打开同一串口。
- 键盘快捷键与页面按钮等价；快速连键时部分 ACK 会丢（板端发送中丢弃请求，
  人手速度不会）。
- 数据面（图/音上传）走 `frame_fifo_write`，与本控制面互不影响。
- **调试工具** `scripts/eth_probe.py`：**绕过 ARP** 的连通性探针——用广播帧
  把命令直接发到板卡 UDP 端口 1（广播不需要 ARP 解析，能排除 PC 侧 ARP 环节），
  同时监听 :2 收回包。以太网"ping 不通/收不到回包"时先跑它，一眼区分是
  "帧没到板子"还是"板子不回"。用法 `python scripts/eth_probe.py 100`
  （跑之前先关掉 Web 控制台，它占着 UDP :2）。
