# 验证计划

目标：**90% 的 bug 死在 Verilator 里**；板时间只花在物理层（真卡、250Mbps IO、
显示器锁定）。

## 1. 总体结构

```
vsrc (DUT) ──┬── csrc/sd_card_model    (SPI 引脚级, 供卡镜像)
             ├── tb/sdram_model.v      (时序审计 BFM)
             ├── csrc/tmds_sink        (解码 checker: 帧→PPM/SDL, 音频→WAV)
             └── csrc/golden           (独立软件实现, 期望帧/音频序列)
                     └── difftest 比对（帧像素 diff, 音频样本 diff, ±1 帧容差）
```

## 2. TB 三件套规格

### 2.1 sd_card_model（C++，引脚级）

- 直接驱动 cs/sclk/mosi/miso 四根线（每 eval 采样），逼真到协议层
- 从 img/card.img 按扇区应答；支持 CMD0/8/9/16/17/18、ACMD41、CMD58
- 模型 Ncr/Nec 等待周期；可选注入：坏 CRC、扇区读抖动、中途失联（测 R06）
- 卡镜像由 scripts/gen_card.sh 生成（mkfs.vfat 真实格式化 + mtools 拷入）

### 2.2 sdram_model（tb/sdram_model.v，BFM）

- 功能应答 + 时序审计：tRC/tRAS/tRCD/tRP 违例与刷新间隔超标即 $fatal
- 时序参数化，与 sdram_ctrl 的参数包同源

### 2.3 tmds_sink（C++，引脚级）

- 双沿采样 4 通道 → 反串化 10bit → 8b/10b 解码（控制字符/数据岛/视频期）
- 视频帧重建 → out/frame_NNNN.ppm（可直接肉眼看）+ 可选 SDL 窗口
- 音频包提取 → out/audio.wav（可听）
- DDC/HPD 不建模：固定 640×480@60 输出无需读 EDID

## 3. golden difftest

- **独立实现**：C++ 另写一套 FAT32/BMP/WAV 解析（与 RTL 及 sd_card_model 无
  共享代码——共享代码的比对没有意义，这正是 difftest 的本义）
- 输入：同一 card.img + UI 激励时间轴（脚本化的按键/拨码事件）
- 输出：期望帧序列 + 期望音频样本流
- 比对：帧间允许 ±1 帧时间偏移（装载完成时刻的实现抖动），逐像素 diff
  并上报首个失配坐标

## 4. 断言清单（checker 实现，违例即 fail）

- [ ] 每视频帧音频样本数 = 800 ± 1（48k/60）
- [ ] ACR 的 N/CTS 与实际音频 ce 率一致（48.0077kHz 换算）
- [ ] 音频/ACR 包只出现在合法辅助窗口（HSYNC 期间数据岛）
- [ ] TMDS 全符号解码合法（无非法 10b 码）
- [ ] DISP 行预取在行起始前完成（行缓冲满标志）
- [ ] SDRAM 无时序违例（模型审计）
- [ ] 播放列表文件数与 golden 一致
- [ ] 任意激励下仿真时间内无死锁（看门狗计数器）

## 5. 回归矩阵（make regress）

| 用例 | 卡内容 | 检查点 |
|---|---|---|
| R00 冒烟 | — | 心跳/骨架（当前已实现） |
| R01 正常轮播 | 4×640×480 + 2 WAV | golden 帧比对；S2–S5 逐张提交+像素比对 |
| R02 碎片化文件 | 簇链跨 3 段 | 同 R01（专测 FAT 跳簇） |
| R03 坏 BMP 头 | 1 坏 + 2 好 | 跳过坏图、错误码 E4、蜂鸣 |
| R04 非 24bit | 8bit 调色板图 | 拒绝、E4 |
| R05 空/无图卡 | 0 张 BMP | E3、不挂死（S1/S1b/S7/S8 仍过） |
| R06 卡失联 | 模型中途停响应 | 超时重试 → E5 可恢复 |
| R07 轮播间隔 | 拨码 2/5/10s | 计时准确 |
| R08 扩展项 | 有效图 + 激励 | 转场 α 混合/OSD/缩放 golden 比对 |
| R09 音频联动（3a 已验） | 同名 BMP↔WAV 配对 + 无配对图 | S2/S3：配对索引正确、配对 WAV 从头**逐样本**比对、播放期无下溢；S4/S5：无配对静音；S7 存储层诊断；S8 死卡 → o_sd_err |
| R10 压力 | 全列表 × 30 轮 | 无累积错误/无死锁（板上另做 2h 烤机） |

运行时间预估：整图装载 ~10M 周期/张，Verilator 分钟级/用例，全回归 ~十几分钟。

## 5b. 仿真覆盖边界（哪些仿、哪些不仿、为什么）

**原则：把"不可仿真的边界"画出来，边界以内我们自己的层照仿，边界用 TB/stub 扮演。**

| 子系统 | 覆盖情况 | 说明 |
|---|---|---|
| SD/FAT/BMP/WAV + 读通路 | ✅ 主仿真 + 自检 | `vsrc/board_top.v`（裁剪顶层）+ `sd_card_model`（TB 扮演 SD 卡）|
| 串口 + 控制核心 | ✅ `make uart` | `tb_uart` 扮演串口对端 |
| 视频读通道 | ✅ `make vdelay` | 独立自检（不在主仿真内）|
| **以太网应用层 `eth_front`** | ✅ `make ethfront` | `tb_ethfront` 扮演 **UDP 栈的应用侧接口**；**11 项**：RX 解命令/握手/不成对拒收/pending 丢弃/连续命令不串/TX 整帧头+载荷/帧长/字节序/**应用头不参与解析**/**跨包不误配命令对**/**栈未就绪时等住不丢帧** |
| 以太网命令仲裁 `cmd_arb` | ✅ `make cmdarb` | 已从顶层抽成模块（放在 `ctrl_core.v` 里，不新增文件→不碰 `.al`）；`tb_cmd_arb` 6 项：取走拍命令字节当拍正确/**连续两条不串（晚一拍回归）**/串口汇出/同拍冲突 eth 优先/pending 高电平只 take 一次/ack 翻转计数 |
| 以太网"下面三层" | ❌ **不可仿** | 加密 UDP 栈（`.enc.v`）+ TEMAC 门级网表 + 厂商原语（`EG_PHY_PLL`/`EG_LOGIC_BUFG`/IDDR/ODDR），Verilator 无模型 |
| HDMI/TMDS | ❌ 不可仿 | 厂商加密/原语 IP；用板上验证 |
| 引脚约束 / 物理层（RGMII 延迟、OUTDEL）| ❌ 不可仿 | 只有 TD 综合 + 上板能验 |

**教训（2026-10-02）**：以太网两个 bug（命令晚一拍、漏发应用头）都落在
`eth_front` + 顶层仲裁——**我们自己的层**，却因为"整个模块以为不可仿"而完全
没有护栏，只能上板才发现。补 `tb_ethfront` 时做了**变异验证**（把应用头改回
旧写法 → T6/T8 立即 FAIL），确认测试有效而非空过。

补充（同日）：给 `ctrl_core` 加自动轮播状态遥测时，`tb_uart` 新增的 **T12**
立刻抓出一个潜伏 bug——ACK 拼接里 `{3'b0, bri_level}` 只有 7 位，整条拼接只有
63 位，赋给 64 位 `tx_pkt` 会**高位补零、所有字段错位半字节**（原本 `pkt[7]` 恒 0
所以从未暴露）。**教训：拼接包时每个字段都要凑满整字节，判据是总位宽正好 64。**

同日又补了 `tb_cmd_arb`（把顶层那段仲裁胶水抽成 `cmd_arb` 模块后单独测），
并做**变异验证**：把"命令字节过寄存器打拍"的旧写法塞回去 → T1/T2/T4 立即 FAIL，
且 `taken[0]=4e taken[1]=41`（正是当时"ACK 错位一拍"的症状）——证明它能拦住
那个让我们折腾半天的 bug。

## 6. CI（本地 pre-commit hook 或脚本）

- `make lint`：verilator --lint-only -Wall
- `make synth-check`：yosys 综合预检（RTL 就绪后启用，抓不可综合写法）
- `make regress`：全用例 + 退出码聚合

## 7. 板上调试三件套（对应仿真覆盖不了的部分；实际操作在 TD 工程仓库）

1. **数码管 FSM 状态码**：每个模块 4bit 状态汇成总线，SW3 切显——
   "卡死在 0x23"一眼可见
2. **UART hexdump**：MBR/BPB/目录项/簇链按需打印（板上 USB 转 UART 现成）
3. **TD 在线逻辑分析仪**：抓跨域握手与 SPI 波形

上板顺序：例程 → SD init 打印 CSD → 扇区 0 dump → 列目录 → 静态图
（借例程显示通路）→ 换自己通路 → 轮播 → 音频
