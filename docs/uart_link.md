# UART 交互通道（uart_link.v）

PC ↔ FPGA 的串口交互通道 v1。板上 Type-C 旁的 CH340G 即 USB-UART 桥，
PC 端出现为虚拟串口（Windows COMx / Linux ttyUSBx）。

## 分层（2026-09-29 拆分）

```
UART 前端(uart_link.v) ──cmd/cmd_val──► ctrl_core.v ──vk_*_n──► sd_card_bmp 按键线
   8N1 + [CMD,~CMD] 成帧             命令语义/音量参数/状态包内容
                                      └──stat_req/status_pkt(8B)──► 前端组帧发送
```

命令**语义**在 `ctrl_core.v`，与传输无关——将来加以太网只需再写一个前端，
把报文翻译成同样的「命令字节 + valid」，`ctrl_core` 与 UART 前端都不用改。
控制参数（音量 `vol_gain` 0..8、轮播周期 `auto_period_s` 1..10s）也由
ctrl_core 持有：音量在 top 送 HDMI 核前做 `×gain>>3`（gain=8 恒等，字节级
音频比对不受影响）；轮播周期接 sd_card_bmp 的 `auto_period_s`（默认 1s，
与旧行为一致）。**参数命令同表：`+`/`-` 音量、`>`/`<` 周期。**

## 硬件配置

| 项 | 值 |
|---|---|
| 引脚 | `uart_rx`=F12（PULLUP）、`uart_tx`=D12（DRIVESTRENGTH 8） |
| 格式 | 8N1 |
| 波特率 | 默认 1 Mbaud（`uart_link` 参数化：BAUD/CLK_FREQ_HZ；CH340G 支持到 2M，1M 有 2 倍裕量） |
| 时钟域 | sd_card_clk（100 MHz）。1 Mbaud = 整 100 拍/位，无小数分频误差 |

选 sd_card_clk 域的原因：命令消费方（sd_card_bmp 按键去抖）就在该域，
**免 CDC**；100 拍/位的整除关系也让位采样无累积相位误差。

## 协议

### PC → FPGA（命令帧，2 字节）

```
[CMD, ~CMD]     # 异或配对校验，两字节必须相邻
```

| CMD | 键 | 功能 |
|-----|----|------|
| 0x4E | `N` | 下一张 |
| 0x41 | `A` | 自动轮播开关 |
| 0x50 | `P` | 上一张 |
| 0x30 | `0` | 直接切（上电默认）|
| 0x31 | `1` | 新旧图交叉溶解 |
| 0x32 | `2` | 32 像素柔边滑动替换；下一张/自动从右向左，上一张从左向右 |
| 0x2B | `+` | 音量 +1 |
| 0x2D | `-` | 音量 -1 |
| 0x3E | `>` | 轮播周期 +1s |
| 0x3C | `<` | 轮播周期 -1s |
| 0x5D | `]` | 亮度 +1（9 档，4=原始）|
| 0x5B | `[` | 亮度 -1 |
| 0x2E | `.` | 对比度 +1（7 档，2=原始 k=1.0）|
| 0x2C | `,` | 对比度 -1 |
| 0x51 | `Q` | 音频脉动条开关（默认关）|
| 0x27 | `'` | 脉动灵敏度 +1（4 档 0..3，上电 1）|
| 0x3B | `;` | 脉动灵敏度 -1 |
| 0x53 | `S` | 回读一包状态 |
| 0x4C | `L` | 播放列表转储（调试，见下"转储包"）|
| 0x44 | `D` | SDRAM 显示帧原始读回；特效完成前仍为旧图 |

- 未知字节、不成对字节**静默丢弃**。
- `N`/`A`/`P` 以 **100 ms 低脉冲**注入按键线，与物理按键线相与后走
  sd_card_bmp 现有去抖——零侵入复用，脉冲期间新命令被忽略。

### FPGA → PC（两类包，各 8 字节）

**状态包（A5 开头）**——按 `S` 回一包，系统全景：

```
A5 | state | fat_state | flagA | flagB | underrun | img_idx | wav_flag
```

| 字节 | 含义 |
|------|------|
| state | 主状态机 state_code（4 位） |
| fat_state | FAT32 状态机（8 位） |
| flagA | {video_pll_lock, sys_pll_lock, sdr_init_done, display_valid} |
| flagB | bit[6:5]=切换效果模式；bit4=自动轮播；低 4 位为 {hdmi_locked, fat_err, disp_buf[1:0]} |
| underrun | {vid_stick, aud_stick, 2'b00}，1=曾发生欠载（粘滞，复位清） |
| img_idx | 当前图索引（5bit，最近尝试项：提交/失败都更新） |
| wav_flag | 该图是否配同名 WAV |

**ACK 应答包（5A 开头）**——**每条被接受的命令**（除 `S`）在参数生效后自动回一包，
即"命令回执"：

```
5A | cmd回显 | vol_gain | period_s | img_idx | wav_flag | bri_level | flags
```

| 字节 | 含义 |
|------|------|
| cmd回显 | 本次命令字节（如按 `-` 回 0x2D） |
| vol_gain | 当前音量档（0..8，8=原始） |
| period_s | 当前轮播周期（1..10 秒） |
| bri_level | 低 4 位为亮度档（0..8，4=原始）；bit[5:4]=切换效果模式 |
| flags | bit0=自动轮播开关；bit[3:1]=对比度档位（0..6，2=原始）；<br>bit4=**音频脉动条开关**；bit[6:5]=**脉动灵敏度**（0..3，上电 1）；bit7 保留 |

控制参数的实时值看 ACK 包；系统全景看状态包。与原七段调试面板**同源**
（面板已退休，UART 是该组遥测的唯一出口）。flagA/flagB 为准静态电平直取；
underrun 来自 74.25M 域的粘滞寄存器，模块内 2FF 同步。发送中的新请求丢弃
（快速连键时部分 ACK 会丢，人手速度不会）。

效果模式命令是显式设值，重复发送不会重复切换。模式在装载新图开始时锁定；
已装载的切换过程不受后续模式命令影响。交叉溶解和柔边滑动都在新图写完后
运行约 1 秒，结束时才提交新图及配对 WAV。网页和 UART 共用同一命令字节。

**转储包（'L' 调试命令，2026-10-04 加）**——回 N+1 个 8 字节包：每个播放列表
条目一包，末尾收口包一包。**高 2 位作标签分帧**（01=条目 / 10=收口，ASCII
<0x80 永不冲突），条目包按索引 0,1,2… 顺序发出，包间隔 400µs：

当前板侧定义了 `FPGA_LEAN_LIST_DIAG`，因此 `L` 不发播放列表数据包；
注释顶层宏并重新综合后才恢复下述转储格式。

```
条目包  01 | idx[4:0] | is_bmp | pair_valid | pair_wav[5:0] | nxt[5:0] | prv[5:0] | 37'b0
收口包  10 | file_cnt | bmp_cnt | wav_cnt | first_bmp | img_idx[4:0] | first_idx_r[4:0] | load_busy | scan_active | ld_state[2:0] | 23'b0
```

| 字段 | 含义 |
|------|------|
| is_bmp | 该条目是 BMP（用跳表重建：`i==first_bmp` 或 `nxt_map[prv_map[i]]==i`；**不占用** fat32_ro 与音频扫描共享的查找口）|
| pair_valid / pair_wav | 该 BMP 有合法同名 WAV / 其 WAV 的播放列表索引 |
| nxt / prv | 循环跳表：下一张/上一张按下后将要装载的条目（仅 BMP 项有效）|
| first_bmp / first_idx_r | 扫描建表的首 BMP / 首图候选（坏图推进）|
| img_idx / load_busy / scan_active / ld_state | 发收口包瞬间的光标与装载/扫描状态快照 |

**用途**：环缺图/单向切图/切图失效类板级问题的第一手数据——跳表对不对
（nxt/prv 链）、配对表建没建、光标卡在哪个条目，一条 `L` 全看到。PC 端解码：
`python scripts/pl_dump.py COM7 1000000`（或以太网模式 `--udp`）。仿真侧
board_sim S11 用例对同一通路做 golden 比对。

**亮度实现**：档位经**格雷码**跨时钟域（sd_card_clk → video_clk，每次步进
只变 1 位，同步后恒为合法旧值/新值），video 域每通道加偏移 `(档-4)×16` 并
钳位 [0,255]，档 4 = 原始画面。

## PC 端使用

```bash
pip install flask pyserial
python scripts/web_console/app.py          # 浏览器打开 http://127.0.0.1:5000
```

Web 控制台（原 `uart_console.py` 命令行已并入并删除）：页面上选串口/波特率
连接，按键面板单键即发（`n` 下一张 / `p` 上一张 / `a` 自动轮播 / `+`/`-` 音量 /
`>`/`<` 周期 / `]`/`[` 亮度 / `s` 状态回读），两类包实时滚动解码，例：

```
[12:01:02] ACK 音量- | 音量=3/8 周期=1s 亮度=4/8 img=2+wav
[12:01:05] state=0x1 fat=0x08 buf=1 img=2+wav | OK: vidPLL sysPLL SDR disp hdmi | 异常: 无
```

详见 `docs/web_console.md`（串口/以太网双控开关，两者均已落地）。

## 验证

`make -C boardtest uart`（Verilator，tb_uart.v：uart_link 前端 + ctrl_core
双模块）覆盖 12 项：

1. N 对→虚拟按键脉冲宽度；2. 不成对拒收；3. 未知命令拒收；4. A 对→脉冲；
5. S 对→状态包内容；6. 1/4 位毛刺拒收；7. 全真实参数（VK_PULSE_CYC=10M）
脉宽 >5M 去抖窗（专测计数器位宽截断，第二实例）；8. P 对→脉冲；
9. 音量档位/上下界钳位；10. 周期档位/钳位；11. 亮度档位/钳位 + ACK 包
端到端内容（5A|回显|vol|per|img|wav|bri|00）。
（TB 用缩短参数 VK_PULSE_CYC=5000 拍加速，波特率与协议语义不变；
宽度类问题由 T7 的真实参数实例覆盖。）

## 调试记录（防复发）

- `pkt_idx` 与 `pkt_len` 曾被两个 always 块同时驱动（多驱动，综合必炸）。
- 判发条件不能用 `pkt_idx < pkt_len`：idx 递增、len 递减，二者之和恒为 8，
  该条件只能发出前 5 字节。判发用 `pkt_len != 0`。
- `tx_load` 必须屏蔽 `tx_done_byte` 拍：done 拍 st 已回 IDLE 但 len 的递减
  下一拍才生效，旧 len 会多装一个字节并使 4 位 len 下溢回卷（0xFFFF… 失控连发）。
- TB 侧：命令在第二字节停止位**中心**即解码发包，收包须与发包并发（fork），
  否则错过首字节起始位。
- 虚拟按键脉冲宽度必须**明显大于**消费方 `key_press_debounce` 的去抖窗
  （DEBOUNCE_MS=50，即连续 5,000,000 个低采样沿才认按下）：脉冲实际只有
  VK_PULSE_CYC−1 拍，最初设 50ms 与去抖窗等长，差 1 拍 → 上板按 N/A
  毫无反应。已放宽到 100ms；tb_uart 脉宽断言锁死为精确值防复发。
- **改 100ms 后第二次翻车：vk_cnt 位宽截断**。vk_cnt 原为 23 位（上限
  8,388,607），装载 9,999,999 被截成 1,609,599 ≈ 16ms，板上依然过不了
  去抖（且比 50ms 版更短）。TB 的缩短参数（5000 拍）落在 23 位以内，
  **两种宽度 bug 仿真都测不出来**——已扩到 32 位，并新增 T7：第二实例
  用全部真实默认参数（VK_PULSE_CYC=10M）实测脉宽，断言 >5M 去抖窗；
  已验证对 23 位 bug 版判 FAIL。教训：**计数器位宽必须按最大参数值
  验算；缩短参数的回归测不出宽度类问题，须补一条真实参数用例。**
  另：dut_full 共享 rx，T1 的命令会触发它的真实脉冲，T7 前须等其结束
  （脉冲期间新命令被忽略，否则命令被吞、TB 挂起）。
