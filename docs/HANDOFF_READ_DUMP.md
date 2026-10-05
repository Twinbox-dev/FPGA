# 交接文档：读侧 dump 调试（2026-10-05 深夜，模型换手专用）

> **历史快照。** 本文保留当时的证据和待办，不能作为最终故障结论或当前提交计划。
> 2026-10-06 的上板结果、最终限速修复及“先 diff 稳定提交”的调试准则见
> [`multires_fix_postmortem.md`](multires_fix_postmortem.md)。

> 本文档是自包含的上下文转移。读这一份即可接手，不必翻旧对话。
> 配套背景还可见 `docs/TODO.md` 第十六~二十二轮（历史流水）与
> memory（anlogic-3a-sim-state.md）。

> **2026-10-05 更新：本交接的 H1/H2 推断已被源码复盘推翻。**
> 读回流每包序号误写写侧 `seq`，PC 因而反复清空会话；修复、抽样位置映射、
> 抓取有效脉冲对齐及验证记录见 `docs/TODO.md` 第二十三轮。下一步是重新综合
> 上板看读回帧，而非先按下文的旧计划抓包或加计数器。

---

## 0. 项目与环境（30 秒版）

嵌赛'2026 安路选题一，板卡 EG4S20（HX4S20C）。功能：TF 卡多分辨率 BMP+同名
WAV → SDRAM 四缓冲 → HDMI 1280×720@60 音画同步轮播，RGB565 双像素/字。
单仓 `C:\Users\23506\Desktop\anlogic`：

- **TD 工程直开 `board/`**（TD 退出会用内存清单覆盖 .al，手工登记新源文件须在
  TD 关闭后写；本次没有新增文件，无此问题）。
- **仿真在 WSL 跑 `boardtest/`**：`make -C boardtest regress`（7 卡并行 ~13min）、
  `make ethfront / readeng / uart / cmdarb`（单 TB）。Verilator 5.032。
- **PC 控制台**：`python scripts/web_console/app.py`（Windows python，装了
  flask/pyserial；WSL 里没有 flask 别乱装）→ http://127.0.0.1:5000。
  以太网模式：板 192.168.137.2（固定），PC 网卡 192.168.137.1/24，UDP
  板:1 ↔ PC:2。改了 HTML 必须重启 app.py（Flask 非调试模式缓存模板）+
  浏览器 Ctrl+F5。
- **串口**：CH340G 1M-8N1，与以太网命令同协议（[CMD,~CMD] 帧）。

### 铁律（违反会被用户骂）

1. **dd 只读**：TF 卡经 usbipd 挂给 WSL 是 /dev/sde，只允许读，最多读 ~1G，
   绝不能写、绝不能开错盘。
2. **git 署名**：Boxchan <twinbox6@gmail.com>，禁止 Co-Authored-By。
3. **提交纪律**：上板验证通过才提交；用户本轮明确批评过堆 WIP 提交。
   当前工作区改动全部未提交，就是等验证。
4. **不要猜**：有不确定直接问用户；诚实报告，没问题不要乱改。
5. 工具缺失先问（两个环境，WSL 没的不一定 Windows 没有；git-bash 无 python3
   但有 python）。

---

## 1. 主线状态：撕裂定位（三分法）

**症状**：HDMI 显示撕裂/错位，且每次装载错位位置不同（动态性）。

三分法三个观察点：

| 观察点 | 状态 | 结论 |
|---|---|---|
| ① 原图 BMP | PC 手里有 | — |
| ② 写侧发射流（tap：SD→打包器→SDRAM 写入的三通） | **已上板实证**：整帧 460800/460801 字到 PC，画面干净，seq 缺口 0 | **解码→打包→SDRAM 写通路逐字节正确** |
| ③ 读侧读回（本交接主角，进行中） | RTL 链路算术已验证，PC 只收到尾包（见 §2） | 待定 |
| ④ HDMI 屏显 | 肉眼：撕裂、动态 | 终判在 ③ 之后 |

已排除：underrun 位干净（S 状态包「异常: 无」）、各 PLL/SDR init 标志全 OK。
头号嫌疑（若 ③ 读回也干净）：video_delay/HDMI 读通路；若 ③ 读回花：SDRAM
读/控制器（官方 IP 自带 −6.7ns 违例是历史嫌疑，但 −6.7ns 时代 720p 曾正常）。

写侧流帧现在完全可用，可兼作板卡装图预览。

---

## 2. 读侧 dump：架构与已验证结论

### 2.1 架构（第二十一轮定稿）

- 触发：`'D'` 命令（ctrl_core CMD_RDUMP=0x44 → rdump_start）或装载提交自动
  （sd_card_bmp 两个提交点都置 dmp_auto_r）→ `dmp_trig` 脉冲。
- top（video_clk 域）一帧捕获窗：dmp_trig（**display_valid 门控**，防启动期
  垃圾捕获）→ toggle 跨到 video_clk → vsync 开窗 `cap_win`，下一 vsync 关窗
  并发 tap2_end。窗内 `tap2_val = cap_win && video_read_en`，
  `tap2_word = video_read_data`——**就是显示读数据出口的三通，纯旁路**，
  不占读引擎会话、不碰音频通道（曾试过借音频读通道，被回归否决：单会话
  读引擎互踩 + 播放被打劫，已回退）。
- eth_front：**双流 FIFO**。写侧 FIFO A（type 0x0003，tap_clk=sd_card_clk）
  与读回 FIFO B（type 0x0004，tap2_clk=video_clk）各自独立 Gray 异步 FIFO
  （512×32）、独立 seq（各会话收口归零）、共用一条 TX FSM（ACK 包优先）。
- **3:1 抽字**：FIFO B 写入口每 3 个 tap2_val 取 1（thin_cnt）。原因：显示
  读满帧 27.6M 字/s = 94MB/s 网络突发，而 **Windows UDP 内核接收缓冲 64KB
  硬上限**（SO_RCVBUF 实测被钳制），必丢。抽后 31MB/s。位置确定：
  **收到的第 j 字 = 显存第 3j 字**（PC 端按此渲染/diff，覆盖 ~33%）。
- PC（web_console）：SSE 只推「有新帧」通知；`/api/frame?slot=wr|rb` 拉原始
  字流（每字 4 字节小端）；wr 画布 vflip 补偿渲染，rb 画布正立直渲染；
  选 BMP 后双帧各自 diff（差异标红 + 覆盖率显示）。
- 验证：tb_ethfront 17/17（T16/T17 覆盖双源+抽字）；七卡回归 433/433
  （捕获窗在 video 域，与视频通路同属 boardtest 仿真盲区）。

### 2.2 开放问题（唯一卡点）

**现象**：按 'D'，读回会话在 PC 只剩一个 **29 字** 的小包（上一代 bit 未抽字
时是 105 字）。

**关键证据（不要重新推导）**：
- 29 = 153600 − 607×253，**恰好**是 1/3 整帧（153600 = 460800/3）分 607 个
  满包后的尾包余数 → 说明板上捕获/抽字/攒包/发包算术全对，607 个满包被
  「 formar 出来了」；
- 105（未抽字代）→ 29（1/3 抽字代）÷3 ≈ 35≈29：两代 bit 每窗实际见到的
  **原始显示读字都只有 ~100 个**；
- 缺口显示 0（孤儿尾包防污染后，缺口 0 + 仅尾包 = 收到的唯一包 seq=0）。

**两个假设，Wireshark 一次定案**：
- **H1 PC 丢包**：31MB/s 突发持续 16.7ms，Windows UDP 64KB 缓冲只吸收 1.7ms，
  GIL/调度停顿即丢。已上缓解：`sys.setswitchinterval(0.0005)`、recv_into
  热路径、SO_RCVBUF 8MB（Windows 可能钳制，无害）。
  **测试**：Wireshark 抓 `udp.port==2`，按一次 D，数 type=0x0004 的包：
  - ~607 个 → PC 栈/Python 丢包 → 换 WSL/Linux 收包端验证，或写原生接收器
    （C/Go/Rust 小工具），或把 rb 流量换成更低速（1/9 抽字，覆盖 11%）；
- **H2 RTL 每窗只写 ~29 字**：`video_read_en` 在窗内只见了 ~100 个脉冲。
  **测试**：同一次抓包只见 1 个 0x0004 包 → H2。然后加 4 个粘滞计数器
  （tap2 写入字数 / fifo2_full 丢弃数 / B 包数 / B 已发字数），挂状态包空字节
  或新调试命令读出，一次上板分清。重点排查：
  ① `cap_win` 是否真开满一帧（vs_rise_v 每帧一拍？vs_0 形态）；
  ② `video_read_en` 真实占空（video_delay 驱动的 pop 波形——它到底是不是
  每 pop 一次走一个字，还是突发性/条件性拉高）；
  ③ FIFO B 写侧是否中途 full 卡死（写 video_clk 75M / 读 udp_clk 125M）；
  ④ thin_cnt 相位：thin_cnt 连续计数（含窗外脉冲），窗内保留字 = 每 3 个
  取 1 但**相位偏移未知**——PC 端假设 3j 无偏移，若偏移非 0 只是整体错位，
  不会变成 29 字，不是主因但 diff 前要对齐。
- 个人（上一模型）判断：H2 权重更高（「缺口 0」与 H1 的丢 606 包矛盾），
  但 29=精确尾包余数又指向 RTL 已发满——**先抓包，别急着改 RTL**。

### 2.3 定案后的收尾路径

- H1 路线：PC 侧解决接收（Linux 端/原生工具/更低速），读回通了 → 用 diff
  做撕裂终判（读回花→SDRAM 读/控制器；读回净而屏花→video_delay/HDMI）；
- H2 路线：修捕获窗 bug → 同上终判；
- 终判完成后：把撕裂根因修掉 → 用户验收 → **整理提交**（见 §5 提交建议）→
  合并 main。
- 若最终证明 SDRAM 读数据损坏且与官方 IP −6.7ns 违例相关：候选方向是降
  ext_mem_clk 或审查控制器时序收敛（历史记录：−6.7ns 时代 720p 显示正常，
  所以别急着赖 IP，先查我们自己读侧逻辑）。

---

## 3. 未提交改动明细（工作区 vs 2440369）

全部**未提交**（用户纪律：上板验证过才提交）：

| 文件 | 内容 |
|---|---|
| `board/.../ETH/eth_front.v` | 3:1 抽字 thin_cnt（FIFO B 写入口） |
| `board/.../top_tf_hdmi_audio.v` | 捕获窗 display_valid 门控 |
| `boardtest/vsrc/tb_ethfront.v` | T16 期望更新（抽字后 26 字节包）|
| `scripts/web_console/app.py` | setswitchinterval(0.0005)、recv_into 热路径、孤儿尾包防污染、SO_RCVBUF、'D' 命令表、双帧槽 |
| `scripts/web_console/templates/index.html` | init 启动块修复（曾被拼接吞掉）、错误钩子 __errs、双画布、3:1 抽字渲染/diff+覆盖率 |
| `docs/TODO.md` | 第二十一/二十二轮记录 |
| `.scratch_p12.py` | **删除待提交**（旧轮残留，用户/前轮已删，git status 显示 D）|

另有 `board/td_project/**` 的大片 M/D —— TD 综合产物（bit/报告/日志），**
不入库**，历来的做法是不 add 它们（.gitignore 没有全覆盖，add 时手动排除）。

---

## 4. 近期提交历史（fix/multires-engine-timing 分支）

```
2440369 eth_subsys 补 tap2_clk 端口穿透            ← 已上板（用户综合过）
3e016c1 读侧 dump：video 域一帧捕获窗…             ← 已上板（用户综合过，读回只剩尾包）
19f9001 'L' 以太网修复（tx_pkt 同拍锁存保持）      ← 已上板验证（用户确认 L 成功）
abced46 攒包/流缓冲 BRAM 推断修复（force_ram 等）  ← 已上板（资源爆掉修复）
f5f695c 撕裂根因修复（pad 前导误发）+ 写侧流 + PC 预览 ← 回归全绿；pad 修复
                                                       板上效果与撕裂关系未单独验证
16be618 docs 第二十轮交接
09ec7c6 into_burst 寄存一拍                        ← 时序修复（用户综合过）
dde10a8 多分辨率信箱 + 写引擎尾部修复 + 'L' 通道
```
main 停在 4a8362f。合并 main 时机：读侧 dump 通、撕裂修复、用户验收后。

---

## 5. 临时文件 / 调试残留清单

**可以删**（确认无引用后）：
- `.scratch_p12.py`（仓库根，已删待提交）；
- `boardtest/logs/*.log` 若嫌大可清（会由回归重新生成；当前被 git 跟踪，
  删了会出现 D 状态，提交时决定去留——历史上是跟踪的）；
- `scripts/web_console/__pycache__/`（gitignore 已挡）；
- WSL `/tmp/c.js`、`/tmp/console.js`、`/tmp/web.log`（本次调试残留）。

**保留（有用途）**：
- `scripts/dump_dir.py`（FAT32 目录/簇链验证）、`pl_dump.py`（'L' 串口/UDP
  解码器）、`eth_probe.py`（早期以太网探针，确认无用可删但先问用户）；
- `scripts/sync_boardtest_sd.py`（**必留**：boardtest 副本唯一合法同步方式）；
- `img/*.img`（gitignore，本地测试卡镜像，含 card_user_real.img 真卡截取）。

---

## 6. 本项目专项踩坑（新模型必读，全是血泪）

1. **TD BRAM 推断三要素**（缺一落成 LUT/FF 爆资源）：`/* fehdl force_ram=1,
   ram_style="bram" */` 注释 + **无复位独立 always** 读写口 + 深度 ≤1024。
   本轮 str_mem 1030×8 爆过一次（LUT 120%、mslice 6870>4900）。
2. **TD 多 always 多驱动**（HDL-8007）：同一寄存器复位和逻辑必须收敛在
   同一个 always 块。
3. **Gray 异步 FIFO 两条铁律**：full/empty 必须**寄存**（组合式
   `next==对侧同步指针` 与指针推进互为组合环，"恰好剩一字且使能有效"时
   振荡，Verilator 拒绝收敛）；寄存读出弹**当前队头 mem[rbin]**
   （写 rbin_next 会整流丢首字）。
4. **跨域发送的数据必须与 toggle 同拍锁存保持**：tx_req/tx_pkt 是 1 拍脉冲，
   eth 侧 toggle 同步晚 ~3 拍，直接给原信号会锁到回落后的兜底内容
   （'L' 转储 11 条全变 ACK 的根因）。
5. **C++ 模型顶替的模块是仿真盲区**：boardtest 里 SD 写响应、读引擎都是
   模型扮演；frame_fifo_write/read 的 RTL 级验证靠 tb_readeng；**video 全域
   （video_timing/video_delay/捕获窗）完全无仿真**——这些区域的改动只能
   上板验。且复用被模型顶替模块的接口前先弄清其真实语义（借道音频读通道
   的方案就是没弄清单会话语义被回归否决的）。
6. **Flask 非调试模式缓存模板**：改 index.html 必须重启 app.py + 浏览器
   Ctrl+F5，否则一直测旧页面。
7. **bash heredoc 写含 `\x` 转义的文件补丁会翻车**（真实控制字节/NUL）：
   文件补丁一律 Write 工具落盘 .py 再执行。
8. **调试用 app.py 实例占端口**（5000/UDP:2），用完必须杀干净，否则用户
   起不来或连到你的 loopback 实例。
9. uart_link 发送 LSB 字节先行；转储包 tag 在首字节；以太网 16 字节帧 =
   8B 应用头(AA BB CC DD type_hi? —— 注意线序 byte4=type LSB)+8B 载荷。
10. 仿真不是绿就完事：**上两次提交时 logs 没重跑，103 个像素失配漏网**——
    全量回归必须在提交前跑（`make -C boardtest regress`）。

---

## 7. 第一优先级行动清单（接手后按序）

1. 重启 app.py + Ctrl+F5（拿到 §2 的全部 PC 修复），按 D 复测一次读回
   （也许 setswitchinterval 已经治好 H1）；
2. 若仍旧 29 字 → **Wireshark**（udp.port==2，数 0x0004 包）→ 定案 H1/H2；
3. 按定案走 §2.3 的分支路线，读回通了做撕裂终判；
4. 修撕裂根因 → 用户验收；
5. 整理提交：建议按「读侧 dump 通」「撕裂修复」「清理」拆 2~3 个提交，
   署名 Boxchan，然后合并 main；把 §5 可删项清一遍。

——以上，交接完毕。有疑问先读 docs/TODO.md 第十六~二十二轮流水，
再问用户（他什么都知道）。
