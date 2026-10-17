# 以太网通道（TEMAC + UDP 栈，移植自官方 demo）

板载 RTL8211 PHY（RGMII 接口）→ 官方 TEMAC_CORE（MAC）→ 官方
`udp_ip_protocol_stack`（ARP/IP/UDP）→ **eth_front**（应用层，我们写的）→
`ctrl_core`。

移植自两个官方例程：`32_Ethernet_test`（APUG013 UDP 参考设计，**百兆**版，
RTL/时钟骨架的来源）与 `33_HX4S20_Etherent_test_01_02_final_1000`
（**本板 HX4S20 的千兆版**——引脚 `OUTDEL`、RGMII 90° 时钟、`rx_pll` 都按它，
见下文「上板实测踩坑」）。

## 网络配置

| 项 | 值 |
|----|----|
| 板卡 IP | 192.168.137.2（静态，MAC 01:23:45:67:89:ab） |
| PC IP | 192.168.137.1（笔记本已有地址，子网掩码 255.255.255.0） |
| 板 → PC 回包 | 目的 192.168.137.1 : 2 |
| PC → 板 命令 | 发往 192.168.137.2 : 1 |
| 速率 | **千兆**（`GIGABIT=1` → TRI_SPEED=2'b10，udp_clk=125M）。**综合时序有违例，属已知风险**，见下节 |

**接线**：网线直连笔记本（或同交换机），笔记本网卡配静态 IP 后即可通信。

## 应用层帧格式（UDP payload = 8 字节应用头 + 数据，APUG013）

```
[header0=0xAABB][header1=0xCCDD][type][length] + 数据
```

| 方向 | type | 数据 |
|------|------|------|
| PC→板 命令帧 | 0x0001 | `[CMD,~CMD]` 两字节（与串口同款命令表） |
| 板→PC 应答帧 | 0x0002 | 8 字节：`5A|cmd回显|vol|period|img|wav|bri|flags` 或 A5 状态包 |

**flags 字节**（ACK 的第 8 字节，2026-10-02 起启用）：`bit0 = 自动轮播开关当前状态`
（板端 `sd_card_bmp.auto_play_out` → `ctrl_core.auto_on` 打进包；原来是保留的 `00`），
`bit[4:1] = 对比度档位`（0..6，2=原始 k=1.0）。
状态包里的 `flagB` 字节空出的 **bit4** 承载轮播状态、**`flagA` 字节空出的高 4 位**
承载对比度档位。PC 侧
`decode_ack`/`decode_pkt` 解析后显示"自动轮播=开/关"（前端瓦片 + A 按钮高亮）。
⚠ 包长/帧长**都没有变**（用的都是保留位）；但**新 PC 端配旧 bit 会一直显示"关"**
（该字节恒 0），故前端与 bit 要一起更新。

## 文件（board_display/user_source/hdl_source/ETH/）

| 文件 | 来源 | 说明 |
|------|------|------|
| TEMAC_CORE.ipc / _gate.v | 官方 al_ip | MAC IP。**不需要在 TD 里重新生成**：`_gate.v` 是编译好的网表，直接参与综合即可（用户实测确认）；`.ipc` 留作以后想重新生成时的配置 |
| udp_ip_protocol_stack_merge.enc.v | 官方 | UDP/IP/ARP 协议栈（加密 IP） |
| eth_subsys.v | **我们写的** | 子系统打包：时钟/复位/UDP 栈/TEMAC/fifo/eth_front |
| eth_front.v | **我们写的** | 应用层：RX 跳过 8 字节头解析命令；TX 组头+应答包 |
| temac_block/rgmii_interface/IDDR/ODDR/BUFGMUX/RAMB16/tx/rx_client_fifo/clk_gen_rst_gen/pll_gen/div_clk_gen/tx_clk_en_gen/temac_clk_gen | 官方 demo 原样 | MAC 适配与 FIFO |

接收时钟再生的 `rx_pll` **内联在 `eth_subsys.v` 里**（`EG_PHY_PLL` 原语，参数照抄
厂商千兆例程的 `al_ip/rx_pll.v`）。不单独建文件是因为 **TD 保存工程时会用内存
清单覆盖 `.al`**，手工新增的源文件条目会被抹掉、报 `xxx is a black box`；
生成出来的 IP 本就是原语包装，内联完全等价。

时钟：`sys_pll`、`video_pll`、eth 的 `pll_gen`（50M→125M×2/12.5M/25M，其中
**C4 = 125MHz @90°** 专供千兆 RGMII 发送）。**百兆**（当前）`udp_clk` = 12.5M，
只用 3 个 PLL；**千兆**时再多用 `eth_subsys` 内联的 `rx_pll`（PHY 的 RXC 125M →
再生接收时钟），4 个 PLL 用满。

## 跨时钟域（udp_clk 12.5M/125M ↔ sd_card_clk 100M）

- **命令**（eth→ctrl_core）：`cmd_pending` 电平 + `cmd` 稳定 → 顶层 2FF 同步
  取上升沿采样 → 翻转 `cmd_ack_t` 回传清除 pending。pending 未清期间新命令丢弃。
- **应答**（ctrl_core→eth）：顶层每条应答翻转 `eth_tx_tog`（toggle），
  eth_front 2FF 同步检测变化后锁存 `tx_pkt`（此时已稳定）发起发送。
- **亮度档位**（ctrl_core→video_clk）：已有格雷码机制，与本通道无关。

## 实测步骤（网线到位后）

1. 笔记本网卡配静态 `192.168.137.1 / 255.255.255.0`，速度**按板卡速率设**：
   - 板卡**千兆**（当前）：网卡**自动协商**（协商到 1G 即匹配）
   - 板卡百兆：网卡要**强制 100 Mbps 全双工**（留自动的话 PHY 会跟千兆网卡
     协商到 1G，与 100M 的 MAC 不匹配，链路显示已连接但数据不通）
2. 网线直连板卡与笔记本（无需交叉线，PHY 自适应）
3. `ping 192.168.137.2` 通 → 二层/PHY 正常（**ping 不通就不再往下走**）
4. 启动 Web 控制台 → 切「以太网控制」→ 点「连接」（首次放行防火墙 UDP）
5. 发 `S` 看是否回 A5 状态包；发 `N`/`P`/音量/亮度看 ACK 与画面响应
6. 排障：ping 不通 → 查网线/链路速率协商/`TRI_SPEED` 与 PC 网卡速率的匹配；
   ping 通但无回包 → 查 TX 路径（eth_front 的 TX_WAIT→SEND 状态机、
   udp_data_length=16）

## 千兆 vs 百兆：时序是已知风险（2026-10-02 决定：跑千兆）

**决定**：跑千兆。理由（用户判断）：**功能能跑通才有意义**（ping + 全部命令实测通过）；最坏情况只是以太网模块本身不稳，不影响显示/串口/按键主线，这个代价可以接受。
**风险记录**（哪天要换百兆，照下面切换即可）：

| 时钟 | 用途 | 需求 | 实测 Fmax | setup 违例 |
|---|---|---|---|---|
| clk0 | 125M eth（udp_clk + gtx_clk）| 125M | **44MHz** | **-5.319ns**（281 个违例端点）|
| clk3 | 125M `ext_mem_clk`（SDRAM）| 125M | 46.7MHz | -6.699ns |
| clk4 | 125M `rx_pll` 输出 | 125M | 179MHz | -2.936ns |

最差路径在**官方加密 UDP 栈内部**（`arp_layer/ip_mac_addr_pairs_cache_module`），
数据路径 13ns 里 **86% 是线延迟**（布线拥塞）。百兆时 udp_clk=12.5M，这些路径全部
有余量（此前百兆版综合为 **setup 全局 0 违例**）。板子虽能跑，但负余量换块板/换温度就可能不稳。

**切换方法**（两处，都已留好）：
1. `eth_subsys.v` 的 `parameter GIGABIT`（1=千兆：启用内联 `rx_pll`、
   `gtx_clk/gtx_clk_90` 用 `clk_125_out/temac_clk90`；0=百兆：rx_pll 不例化、时钟直通）
2. `pin.adc` 里 RGMII 发送组（千兆那份带 `SLEWRATE=FAST`，`txc` 另加 `OUTDEL=3`）

**百兆时可用的富余**：udp_clk=12.5M，上述路径全部有余量（百兆版此前综合为
setup 全局 0 违例）；带宽 ~11MB/s，720p BMP（2.7MB）约 0.3s，也够用。

## 上板实测踩坑（2026-10-02）

- **★运行中复位会让以太网永久失效——按复位键后 ping 再也不通**：
  现象：烧录后一切正常（ping + 命令），按一次复位键后以太网再也回不来，而
  **显示/串口一切正常**、**PC 网卡仍显示"已连接 1Gbps"**（PHY 链路是 PHY 自己
  协商的，与 FPGA 无关）、**拔插网线也救不回来**（排除 PC 侧 ARP/邻居项）。
  判断：把**我们自己写的每一处状态**都排查过（`soft_cnt`/`local_cfg_valid`/
  `rx_pll`/栈/FIFO/TEMAC/`eth_front` 的状态机与同步器全接在 `reset` 上，
  释放条件与上电一致；顶层胶水的 `pend_sync`/`eth_tx_tog` 是自校正的），
  **IP 对外暴露的复位一个没漏** → 卡住的不可能是我们的胶水。
  而 TEMAC 是**门级网表**、UDP 栈是**加密 IP**，这类 IP 的内部初始化
  （配置寄存器/内部 RAM）常常**只在配置时刻生效，运行中复位回不到初始态**
  —— 这正是厂商例程把 eth 的 reset **全接 `1'b0`（从不复位）**的原因。
  做法：`eth_subsys` 只**上电复位一次**（`eth_rst_latch` 跟随 rst_all 到首次
  释放，之后永久释放），按键复位不再打断以太网。
  **若以太网真卡死：断电重上电恢复**（复位键不行）。

- **★★顶层命令仲裁把命令打了一拍——"按 N 回来的却是上一条 A 的 ACK"**：
  顶层原写法
  ```verilog
  reg [7:0] eth_cmd_c;
  always @(posedge sd_card_clk) if (eth_take) eth_cmd_c <= eth_cmd;
  assign cmd_byte = eth_take ? eth_cmd_c : uart_cmd;   // ✗
  ```
  `eth_cmd_c` 是寄存器，**在 `eth_take` 那一拍它还是上一条命令的值**（非阻塞赋值
  要下一个时钟沿才生效），于是 ctrl_core 收到的是**上一条**命令；同时 ack 已翻转
  让 eth_front 清掉 pending，**本拍真正的命令被丢掉**。表现：**每条命令都推迟到
  下一次按键才生效**——ACK 错位一拍（按 N 回 A 的 ACK）、画面"感觉慢好几秒"
  （因为上一次按键的效果要等下一次按键才出现）。
  ✅ 正确写法：`assign cmd_byte = eth_take ? eth_cmd : uart_cmd;`——`eth_cmd` 在
  pending 置位到被 ack 清除之间**本来就稳定**（eth_front 保证），组合取用即可。
  **教训**：跨域握手信号本身可以做同步/打拍，但**携带的数据**在 valid 期间稳定时
  应当组合取用；给数据再打一拍就会引入"晚一拍"。
- **★eth_front 发送漏发应用头**：`tx_buf` 曾只有 64 位（只锁 `tx_pkt`）却按 16
  字节索引（`tx_i` 到 15），导致**字节 8..15 读越界位（=0）、8 字节应用头根本没发**；
  PC 侧还能解出 ACK 只是因为解析器有"没有头就按 `data[:8]` 解"的兜底分支。
  已改为 128 位整帧 `{tx_pkt, TX_HDR}`（`TX_HDR` 用 `HDR0/HDR1/TYPE_ACK` 拼装）。
- **★★★RGMII 时钟接法照抄了百兆 demo——千兆下收/发全采不准（最根本的坑）**：
  32 号（百兆）demo 的接法是 `.gtx_clk(temac_clk), .gtx_clk_90(temac_clk)`、
  `.rgmii_rxc(phy1_rgmii_rx_clk)`——**两个时钟都接 0° 时钟、接收直接接原时钟**。
  百兆 25MHz（40ns）时序宽松所以能跑。**千兆 125MHz（8ns）必须移相 90°(≈2ns)**，
  厂商 **HX4S20 千兆例程**（`DEMO/33_HX4S20_Etherent_test_01_02_final_1000`）的做法：
  ```
  rx_pll u_rx_pll(.refclk(phy1_rgmii_rx_clk), .clk0_out(rx_clk_0), .clk1_out(rx_clk_90));
  temac_block(
      .gtx_clk    (clk_125_out),            // 125M
      .gtx_clk_90 (temac_clk90),            // ★90° 相移（pll_gen 的 C4）
      .rgmii_rxc  (rx_clk_90)               // ★PHY RXC 经 rx_pll 再生
  );
  ```
  症状：**接收方向字节数在动但全是垃圾（栈解析不出 ARP）、发送方向板子计到
  在发但 PC 一个字节都收不到**（收发全废，链路却正常）。已按千兆例程改
  `eth_subsys.v`（`rx_pll` 内联其中，见上文「文件」节）。
  （当前千兆=启用；`GIGABIT=0` 时 rx_pll 不例化、时钟直通。）
  ⚠ `rx_pll.FIN=125MHz`，只千兆锁得住，改回百兆要旁路它。
- **★★千兆 RGMII 发送引脚必须加 `OUTDEL`——"收得到、发出去全坏"的根因**：
  引脚约束原是从**百兆** demo（32）抄的（`DRIVESTRENGTH=8`，无 `OUTDEL`/`SLEWRATE`）。
  厂商给**本板（HX4S20）的千兆例程**（`DEMO/33_HX4S20_Etherent_test_01_02_final_1000`）
  里 RGMII 发送组是：
  `tx_clk {DRIVESTRENGTH=16; SLEWRATE=FAST; OUTDEL=3;}`、`tx_ctl/txd[3:0]
  {DRIVESTRENGTH=16; SLEWRATE=FAST;}`。**TXC 在千兆是 125MHz，时钟必须比数据晚
  ~2ns（OUTDEL=3）PHY 才采得准**；百兆 25MHz 时序宽松所以 demo 没给。
  症状极隐蔽：**链路正常协商、接收侧一切正常（PHY 内部 strap 了 RXDLY，原理图
  网表有 `NLLED20RXDLY`）、板子也确实在发包（数码管 TX 计数会动），但 PC 一个
  字节都收不到**。已按千兆例程改 pin.adc（当前千兆=用这份）。
- **★复位极性接反——ping 完全不通的根因**：`clk_gen_rst_gen` 的 `reset` 是
  **高有效**（直连 `EG_PHY_PLL.reset`）。demo 写 `.reset(~key1)` 是因为 key1
  按键平时为高、按下为低，所以"不按"时 `~key1 = 0` = 不复位。我们的
  `rst_all` 平时**已经是 0**（复位期才是 1），却照抄写成了 `~rst_all`→
  **平时恒 1 = 整个以太网子系统（PLL/UDP 栈/TEMAC/eth_front）被永久钉在
  复位**。现象极具迷惑性：**PHY 链路照常与 PC 协商成功（网卡显示 100M/1G），
  但 FPGA 侧一字不发，ARP 不响应、ping 报"无法访问目标主机"**。
  正确写法：`eth_rst_in = rst_all`（同极性直连）。
- **`input_local_ip_address_valid` 必须是"复位期间 0 → 释放后 1"**：官方栈在
  valid 的**上升沿**装载 `input_local_ip_address`，demo（`udp_transmit_test.v`）
  写的正是 `if(reset) valid<=0; else valid<=1;`。
  ⚠ 两个坑都要避开：①接**恒 0** → 永不装载；②接**恒 1**（上电即 1，复位释放
  时没有边沿）→ 同样可能不装载。两者症状一样：**收得到包但从不回包**。
  正确写法见 eth_subsys.v：`local_cfg_valid <= ~reset;`（udp_clk 域）。
  端口 `input_local_udp_port_num_valid` 同理，共用这一个信号。
- **官方 demo 的 IP 不是 240.1 而是 240.0**：demo 用 `cnt0` 每 600s（10 分钟）
  把 IP 末位 +1，上电后前十分钟板卡 IP = `192.168.240.0`（`cnt1` 从 0 起）。
  用 demo 验证链路时**要 ping 192.168.240.0**，否则会误判成"demo 也不通"。

## 调试过程记录（2026-10-02，已拆除）

上板定位期间曾把 `eth_subsys` 的 24 位诊断字送上 6 位数码管（1 秒窗口计数 +
事件粘滞位：进栈/fifo→栈 字节、TX 字节、`arp_no_reply` 次数、复位/PLL 状态），
**定位完成后已拆除**，数码管恢复固定占位 '8'（`top_tf_hdmi_audio.v`）。
记录在此备查，下次再出类似问题可照此复用：

- **编号约定**（吃过亏，别再搞反）：数码管 **最右边那位 = dig0**，往左依次
  dig1…dig5。物理接线 `seg_data_0`=最左、`seg_data_5`=最右。
- **最有价值的三个观测量**：
  1. **TX 字节数**（栈→MAC）——它动不动，直接回答"板子在不在发包"；
  2. **fifo→栈 字节数 vs TX 字节数**——同步变化说明数据确实进了栈（FIFO 读侧正常）；
  3. **`arp_no_reply`**（官方栈自带输出）——"解析出 ARP 请求但本机 IP 对不上"
     才会拉高，是判断"地址没装载成功"的直接证据。
- **关键教训**：诊断位必须做**时间窗口**（如 1 秒清零刷新），否则上电噪声/历史
  累计会把粘滞位一次性钉住，读数完全没有信息量。
- **实测读数（供对照）**：复位后 `00001E`（dig0=状态位恒 E，dig1 的"发出过"
  置位）；插网线后收字节数持续变化；**ping 时 TX 计数会动但 PC 收不到** ——
  正是这个组合把方向锁定到"发出去的帧是坏的"，进而查出 RGMII 90° 时钟问题。


## 已知限制

- 回包目的端口/IP 固定（192.168.137.1:2），不支持动态学习（demo 亦如此）
- 速率由 `TRI_SPEED` 一处切换（千兆 2'b10 / 百兆 2'b01）；PC 侧网卡建议
  保持**自动协商**（千兆时自协商即 1G，与板卡匹配）
- 未做数据面（图/音上传）——规划走 frame_fifo_write 写口 + 大包分片，另行设计
