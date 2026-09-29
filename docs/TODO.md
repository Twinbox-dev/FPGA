# TODO — 下一步计划（2026-09-23 定，2026-09-26 更新 3a 进度）

按顺序推进，每项完成后 `make regress` 必须全绿再提交。

## 进行中

- [x] **文档补齐**：`docs/architecture.md` 总览 + 各 RTL 文件头注释
      （原因：项目逐轮堆积，缺少总览地图，接手成本高）

## 下一步：3a 音画同步（官方核心需求）—— 已完成（2026-09-26）

官方要求：每张图片配一段音频，切到该图时音频同步播放。
系统级仿真 S1–S8 全 PASS（`card.img` 24 项、`card_frag`/`card_mbr` 各 24/20 项、
`card_empty` 4 项），四张卡 `make regress` 全绿。

**前置：确认 App 接口语义 —— 已完成（2026-09-23）**
- [x] 精读例程 `frame_fifo_write.v` / `frame_fifo_read.v` / `frame_read_write.v`
- [x] 三个与预期不符的发现，均已落进设计：
      1. 写口**不接受地址**，地址由存储侧线性生成，翻转是 `WRITE_V_FLIP` 参数
         → `bmp_dec` 原先自算地址+翻转的写法上板会**上下颠倒**，已改为纯流式
      2. 写口**没有背压**（FIFO `full_flag` 根本没接出来）→ 不发明 ready，
         改为建模 FIFO 占用 + 溢出报警，并把"生产者速率 < 0.99 字/拍"写成约束
      3. 传输长度必须是突发的整数倍，否则板级状态机死锁；例程靠 307200 恰好
         整除侥幸避开 —— 音频缓冲若复用这套接口会踩中，已加 `o_len_err` 断言

**存储层升级（`fb_sim` → `mem_sim`）—— 已完成（2026-09-23）**
- [x] 端口/握手/突发/仲裁 1:1 对齐 `frame_read_write`
- [x] 三类诊断 + 模块级主动故障注入验证（`csrc/mem_sim-main.cpp` 13 项）
- [x] 时钟比建模：顶层 1/4 时钟使能，把 `vga_ctrl` 放进 25MHz 像素域
      （同频会让读 FIFO 水位钉死在补水阈值上、每帧必下溢，诊断退化为恒亮）
- [x] ~~容量扩到音频乒乓~~ —— **不做**：音频走"从卡实时流式"，不进 SDRAM

**音频通路：从卡实时流式 —— 已完成（2026-09-26）**
选型理由：音频 192KB/s vs SPI 25MHz 的 3.1MB/s = 只占 6% 带宽。SDRAM 保持纯
视频用途，例程的 `frame_read_write` 一行不改；音频时长不受缓冲容量限制。
代价是 `fat32_ro` 开第二个上下文。

- [x] `fat32_ro`：目录项捕获 8 字节主名 + 播放列表查找口，
      供同名配对（`IMG001.BMP` ↔ `IMG001.WAV`）
- [x] `sd_arbiter`：双 fat32_ro 扇区读仲裁，音频优先 + 迟到请求 pending 排队
      （两个陈旧 LBA 陷阱均已修复并写入文件头时序约束，见 `sd_arbiter.v`）
- [x] `audio_fifo`/`audio_path`：双 FIFO 乒乓 + 48kHz 节拍播放；
      **续播期写目标切回播放 FIFO**（边播边补），否则长尾 WAV 必然下溢；
      无配对提交双 FIFO 同清 → 静音
- [x] 高水位停流（按写目标 FIFO 水位 ≥1920 停卡流，尾样本不再被写丢弃）
- [x] 双就绪原子提交：图落盘 + 音就位 → 场同步沿同时切换
      —— 装载期间旧图旧音照常播放，切换瞬间无黑屏无静音
- [x] 测试 S1–S8：挂载/分类/逐张提交 + 像素比对 + 配对 WAV 从头逐样本比对 +
      无下溢 + 无配对静音 + 存储层诊断 + 死卡错误

## 之后

- [ ] **C 音频可视化**：16 带 Goertzel + overlay 叠加（显示时拦截，不写帧缓存）
      —— 顺带为 OSD 字幕铺好同一套叠加机制
- [ ] **3b HDMI 音频接口整形**：48k 节拍、24bit 对齐、N/CTS 计算
      —— 纯板级对接面（`I_audio_valid` + L/R + ACR），仿真只验参数正确性
- [ ] **板级迁移**（另库）：见 `docs/architecture.md` 的"板级迁移"章节

## 已知技术债

- [ ] `vga_ctrl` 板级要改用途（产 hs/vs/de 喂 AXIS，而非直出 VGA）
- [ ] `fat32_ro` v1 无 FAT 扇区缓存（逐簇重读，~6% 额外扇区读）
- [ ] 轮播 `type_map` 只覆盖前 6 项（超出部分按图片处理）
- [ ] MBR 卡的 `mdir` 列不出内容（mtools 不认分区表，不影响功能）
- [ ] **切图延迟 = 当前 WAV 播完**（LD_IDLE 等音频实例流完回 S_MOUNTED 才开装
      下一张，最长 ~1s）：板上表现为按键后要等旧音频收尾。若想即按即切，需让
      `fat32_ro` 支持流中 i_restart（当前未验过该路径，慎改）
- [ ] **装载期旧音只剩 ~40ms**：按键后旧音频从播放 FIFO 余量继续播，新音频
      装载独占卡流 → 旧音放干后静音直至提交。演示可接受；若要全程有声需双卡流
      或加大播放 FIFO

## 2026-09-27 状态：上板两轮失败后仿真再全绿（未提交，等本轮上板验证）

**已修复并验证（详见 docs/debug_ald_fat_race.md / boardtest_speed.md）：**

- [x] **板级刺耳根因 #3**：ald file_req 与图像流尾竞争（切图后播的是缓冲残留音频）。
      修复 = ald 触发加 `fat_idle` + LD_FILE 保持-等待。诊断卡（4 不同 WAV 配 4 图）
      是首个能暴露它的用例——此前所有卡内容"碰巧测不出来"。
- [x] **仿真提速 12min→~2min**：短测试 WAV（gen_diag_card.sh / truncate_wav_in_img.py）、
      7 卡并行回归（make -C boardtest regress）、1ms 去抖（仅 boardtest 副本）、
      -O3、getenv 缓存。基线：单卡 ~50s，全量 ~2min。
- [x] 7 卡全量回归全绿：card / card_mbr / card_frag / card_empty / card_diag /
      card_user / card_user_2wav（22–29 项/卡）。
- [x] **S7 自动轮播仿真用例**（SIM_AUTO=1，key_auto 是唯一此前零覆盖的 RTL 路径）：
      开 auto → 等自动提交 → 关 → 像素/音频/停止切换四项全过，card 卡 29 项。
- [x] **S7c 测试缺陷修复（RTL 无辜）**：提交检出与音频 verify 之间烧的按键去抖
      周期（400000 clk = 恰 192 输出样本）把 base 推进圈中间，整圈长度断言
      48960≠49152。教训：**音频圈 base 必须在提交检出的那一拍捕获**，
      verify_loop 因此加了外部 base 入参。症状极像 RTL 回卷 bug，排查花了
      WR_OPEN/FAT 迁移/PSTATE/队列寄存器全套 trace 才证伪——先怀疑测试夹具。

**2026-09-27 上板第三轮失败已定位并修复（等第四次重综合）：**

- [x] 现象：数码管停 2（SD init OK 但 fat_mounted=0），图/音/按键全无。
- [x] 根因：重综合后 clk0 -1.784ns/109 端点，fat32_ro 簇→LBA 链（上轮临界，
      本轮过线）→ mount 首目录扇区地址错。详见 timing_report_howto.md 案例三。
      全局 -6.565ns 是 U3 基线（clk2），不是它。
- [x] 修复：fat32_ro 拆流水（S_BPB2/S_LBA/rd_lba+1），7 卡回归全绿且周期数不变。
- [x] 第四轮重综合（09-27 10:55）：clk0 已干净（-0.133ns/5端点），板级行为
      与第三轮完全相同 → **时序诊断被实验否证，改走板级观测路线**。
- [x] **数码管调试面板已装**（top_tf_hdmi_audio.v，只读不改功能，仿真已回归）：
      6 位数码管 = 原状态码 | fat状态两位hex | flagA={video_pll_lock,sys_pll_lock,
      Sdr_init_done(SDRAM),display_valid} | flagB={hdmi_locked,fat_err,disp_buf[1:0]}。
      健康读数：`2 | fat状态 | E | 8或9`（提交后 flagA=F）。
      判读：flagA<8 → PLL 问题（解释无信号）；flagA bit1=0 → SDRAM init 挂
      （解释无信号）；flagB bit2=1 → fat32 进了 S_ERR=扇区数据错（重插/换卡）；
      fat状态=01/02 → 扇区读握手挂死；=09 同 fat_err。
- [x] 第五轮上板：面板读数全健康（图像正常、切图正常）——"图像全无"实为
      TF 卡接触不良。音频仍噪声。
- [x] **音频噪声根因 #4/#5 已定位并修复**（详见 docs/board_debug_panel.md）：
      #4 写引擎 WRITE_V_FLIP 误伤音频通道（音频字被打散=噪声，静音仍静音/
      正弦变噪声/切图爆音全对上）；#5 读引擎音频会话被视频抢占后永不恢复
      （修完 #4 会暴露为"一声后永久静音"）。两修都在 frame_fifo_{write,read}.v。
- [x] 补真实 RTL 级自检 `make -C boardtest readeng`（T1-T4 全 PASS）——主仿真
      的 C++ 引擎模型是盲区，被替模块改动必须补 RTL 级用例。
- [x] 第五轮上板判读：音调/静音/切换全对，但 5s 文件 ~1.26s 回卷咔一声、
      click 被 4 抽 1 打碎、音调实际 ×4 → **根因 #6**：播放域 rd_en 是 4 拍宽
      脉冲，真实 FIFO 每拍弹一字，净消耗 ×4（详见 board_debug_panel.md）。
      修复 = rd_en_r 清零移出 en25 门控（两副本同步）。C++ 模型曾把该行为按
      边沿触发建模，仿真不可见；card_diag 回归 27 项全绿。
- [x] **第五轮上板复听：全过（2026-09-27）**——音调/时长/静音/切图/自动轮播
      全部正确，根因 #4/#5/#6 修复验证完毕。
- [ ] 残余小瑕疵（低优先级）：静音 WAV 每 ~5s 回卷点有一个小爆破（类似 TST4）。
      疑因：回卷=读会话重启（S_ACK 清 FIFO + PL 弹性队列清空），aud_valid 出现
      短暂 gap / 会话首字在 FIFO 清空后弹出旧值被捕获。排查方向：wrap 时不清
      FIFO（同缓冲重播无需清）、或给 PL 引出 FIFO empty_flag 门控首字捕获。

**提交前清理（上板通过后）：**

- [ ] boardtest/vsrc 副本的 public_flat 探针与 board/ 重新对齐（或保留并文档化）
- [ ] board_sim.cpp 调试打印取舍（WR_OPEN/FAT/PSTATE 已 gate 在 SD_VERBOSE，可留）
- [ ] img/*.img.bak 删除

## 2026-09-27 第六轮：720p + RGB565 改造（仿真全绿，等上板）

架构决策：**原生 1280×720@60 + SDRAM 1 字存 2 像素（RGB565 双像素字）**（方案乙）。
SDRAM 2M 字恰好用满：视频 A/B 各 460800 字、音频 A/B 各 587776 字（**98s** @24k/8b/mono）。
565 解包级定位为后续拓展（字幕/亮度/叠加）的天然 888 域注入点。

- [x] RTL：video_define 宏切 VIDEO_1280_720；bmp_dec 720p（两副本）；
      sd_card_bmp 加 565 打包器 + 装载超时 100M→300M（两副本）；
      video_delay 整体重写（565 解包 + 2:1 串行化，`re=de_d[18]&~p`、
      `vout<=~pd?lo:hi`，低半字=偶数下标像素）；frame_read_write 新增
      `o_vid_rd_empty` 下溢诊断口；top_tf_hdmi_audio：FRAME_WORDS=460800、
      BUF 0/460800/921600/1509376、HDMI 核 720p 时序 + VIDEO_VIC(4)、
      CTS 74250、面板 d0={视频下溢,音频欠载} 粘滞位。
- [x] 仿真：board_sim.cpp N_WORDS=460800 + pack565 字比对；
      tb_readeng 换新布局 + FRAME(640,720)；board_top.v 720p。
- [x] 素材：gen_bmp.py 1280×720（ZBADSIZE 1281×721）；prep_media.sh 720p 规格
      + 音频告警阈值 2351104B；7 张卡全部重建（TST/用户 BMP 均 ffmpeg letterbox
      720p，card_user 重建为真 64MB MBR 卡）。
- [x] **坑：gen_card.sh 碎片卡洞/尾簇数必须随图放大**——8KB 簇下 720p BMP=338 簇，
      原洞100+尾60 装不下→Disk full；改洞 250+尾 101（各自<338、合计>338）。
- [x] 7 卡回归 + readeng 全绿（2026-09-27）。
- [ ] **上板（等用户）**：TD 重配 video_pll → 74.25MHz / 371.25MHz（5×）；
      重综合后查 hdmi_5x_clk 371M 组与 clk0 组时序；上板验画质（565 位复制
      与打包是否逐位对）、音画同步、面板 d0 下溢位恒 0；通过后提交并补文档。
- [ ] 已知 stale：旧 `vsrc/`（top.v/mem_sim.v 等）与 `boardtest/logs/` 仍是 640p
      资产，不在回归范围内；docs 中 640×480 历史表述待随本轮提交统一修订。

## 2026-09-27 第六轮上板判读一：图像"异常锐利" = 相邻像素互换（已修，待重综合）

- [x] 现象：上板图像边缘异常锐利/不自然，与笔记本 100% 缩放查看同一 BMP 对比
      明显不对（用户坚持排查代码，正确）。
- [x] 根因：**video_delay.v 2:1 串行化的 lo/hi 分支对调** → 每对相邻像素左右
      互换。逐拍推导：显示偏移 o 的捕获拍 c=o+1 上 pd(c)=o mod 2、
      read_data=word⌊o/2⌋，故 o 偶应取 lo（偶数像素）、o 奇应取 hi——原代码
      写反。平滑区不可见、边缘 1px 重影="锐利"；压缩前推导本来是 `~pd?lo:hi`，
      实现时写反（注释还忠实记录了错误行为）。
- [x] **仿真盲区教训（第二轮）**：视频读通道完全不在 boardtest 内（C++ 模型
      替代 frame_read_write，video_delay 根本不编译）→ 写侧 565 打包有 golden
      比对护住，读侧解包裸奔。补 `make -C boardtest vdelay`
      （tb_vdelay.v：行为级 FIFO 桩逐拍比对 3 行像素序 + 位复制 + 跨行连续；
      已验证对 bug 版本判 FAIL、修复版 PASS，有判别力）。
- [x] 同批待综合改动：top_tf_hdmi_audio.v（面板 d0 下溢检测跳过每帧首行，
      消除帧首 SDRAM 未填满的正常竞态误报；seg_und 独立线修双驱动）；
      video_pll.v（TD6.2 生成版手工加回 extlock 端口）；CTS=75000（实跑 75MHz）。
- [x] 上板其余判读：面板 C8F8xx/C9F2xx 解读=系统健康（flagA=F、fat
      MOUNTED↔STREAM、disp_buf 翻转、HDMI 锁定）；"切图没音频"=卡内容只有
      首图配 WAV，非 bug（用户换卡后确认音频正常，d0=8 印证音频位干净）。

## 2026-09-27 第七轮：UART 交互通道 v1（仿真全绿，待重综合 + 上板）

- [x] 硬件：uart_rx=F12（PULLUP）/ uart_tx=D12（DS8），8N1 @1Mbaud
      （CH340G 桥，参数化 BAUD/CLK_FREQ_HZ）；clk=sd_card_clk 域免 CDC，
      1M=整 100 拍/位。
- [x] 协议：命令帧 [CMD,~CMD] 成对校验（N 下一张/A 自动轮播/S 状态回读/
      H 心跳开关，未知不成对静默丢）；虚拟按键=50ms 低脉冲与物理键线相与，
      复用 sd_card_bmp 去抖零侵入；状态包 8 字节 A5|state|fat|flagA|flagB|
      underrun|00|00（与面板 d5..d0 同源）；心跳默认关，开后 1s/包。
- [x] board/uart_link.v + uart_tx_byte（5 状态 FSM，停止位独立 TX_STOPBIT
      状态保证满 1 位宽，否则连发帧错）；top_tf_hdmi_audio 挂实例 + dbg 线、
      sd_card_bmp 键线相与。
- [x] tb_uart.v 8 项全绿（make -C boardtest uart）：脉冲宽度/不成对拒收/
      未知拒收/状态包内容/心跳开关/毛刺拒收（VK_PULSE_CYC=5000、
      HEARTBEAT_CYC=2M 缩短参数，波特率语义不变）。
- [x] **坑三连（详见 docs/uart_link.md 调试记录）**：pkt_idx 双 always 多驱动；
      判发条件 pkt_idx<pkt_len 恒错（idx 递增 len 递减，和恒 8，只能发 5 字节）；
      tx_load 未屏蔽 done 拍（done 拍 st 已 IDLE 而 len 递减下一拍才生效 →
      多装 1 字节 + len 4 位下溢失控连发）。
- [x] PC 端 scripts/uart_console.py（pyserial，单键即发，状态包自动解码）；
      文档 docs/uart_link.md。
- [ ] **上板（等用户重综合）**：N/A 切图、S 状态包（uart_console 解码对照
      面板读数）、H 心跳；通过后提交（Boxchan，无尾注）。

## 2026-09-28 第八轮：HDMI 改口 + UART 虚拟按键不触发（已修，待重综合）

- [x] HDMI 换口：pin.adc 六处引脚 C3/G5/F1/E1/P2/R2 → K1/F5/E3/B3/P1/R1
      （信号名/电平属性不动）。**上板验证通过——此后 HDMI 使用 HDMI1 接口**，
      提交时在 commit message 注明。
- [x] UART 按 N 不切图（用户上板反馈）：根因 = 虚拟按键脉冲宽度与消费方
      去抖窗零裕量。key_press_debounce（DEBOUNCE_MS=50）需连续 5,000,000 个
      低采样沿才发 press_pulse；而 uart_link 脉冲实际只有 VK_PULSE_CYC−1 拍
      （vk_cnt 从 CYC−1 递减的 off-by-one），50ms 参数 → 4,999,999 拍 < 5M，
      **确定性不触发**。物理键无恙（人手按压 ≫50ms）。
- [x] 修复：VK_PULSE_CYC 5M→10M（100ms），uart_link.v 默认值 + top 实例
      override 两处；tb_uart 脉宽断言从 ±100 收紧为精确 [VK−2,VK] 锁死；
      8 项回归全绿（实测脉宽恰 = VK，与推演吻合）。教训入 docs/uart_link.md。
- [ ] 上板（等用户重综合）：按 n 切图、a 自动轮播、s 状态包、h 心跳；通过后
      提交（Boxchan 无尾注，commit message 注明 HDMI 已改用 HDMI1 接口）。
- [x] 上板结果（2026-09-28 02:30，重综合含 10M 修复后）：s 状态回读 ✓、
      h 心跳 1s/包 ✓（RX 解码/TX 回传/引脚方向/波特率全部打通）；
      **n/a 虚拟按键仍不生效**（buf 不翻转、fat 恒 0x08）——10M 脉冲下
      仍复现，脉冲宽度假设被证伪，根因待查（下一步方向：确认 bitstream
      里 VK_PULSE_CYC 实际值；查 sd_card_bmp 侧 key_next_press 生成与
      fat_mounted 条件；注意 fat 状态机对 key_next_press 有
      bmp_cnt!=0 等前置条件）。
- [ ] 待解疑：02:30:59 无 UART 命令时 state 0x1→0x4、fat 0x08→0x02
      且 3s 内未回 0x1/0x08（buf 恒 0）——当时未发任何命令，可能是物理
      按键或装载流程卡住，复测时留意。
- [x] **根因已找到并修复（2026-09-28 补）**：uart_link 的 vk_cnt 只有 23 位
      （上限 8,388,607），VK_PULSE_CYC 改 10M 后装载值 9,999,999 被截断成
      1,609,599 ≈16ms，板上永远过不了 50ms 去抖。三版本三种死法：5M 版
      差 1 拍（off-by-one）、10M 版位宽截断、TB 缩短参数（5000 拍在 23 位
      内）两者都测不出。修复：vk_cnt 扩 32 位 + tb_uart 新增 T9（第二实例
      全真实默认参数实测脉宽 >5M 去抖窗，已验证对 23 位 bug 版判 FAIL），
      9 项全绿。教训入 docs/uart_link.md。
- [x] 疑点收口：02:30:59 的无命令 state 0x1→0x4 迁移——16ms 脉冲下 vk
      路径不可能触发，判定为物理按键/其他来源，非本 bug 组成部分；复测
      时若再现再查。
- [ ] 待用户重综合 + 上板：n 切图（buf 翻转）、a 自动轮播（fat/buf 周期
      变化）；通过后提交（Boxchan 无尾注）。
- [x] 按用户要求删除心跳功能（uart_link 去掉 CMD_HB/hb_en/hb_cnt/hb_tick、
      HEARTBEAT_CYC 参数、pkt_req 只剩 cmd_stat；tb_uart 去 T6/T7 心跳用例
      重编号为 7 项；脚本去 h 键；文档同步）。仿真 7 项全绿后提交。

## 2026-09-28 第九轮：vidUND 恒 1 = 开机首帧读 FIFO 未稳态（已修，待重综合）

- [x] 现象：UART 状态包 vidUND 恒为 1（粘滞位），开机烧录后首次 s 即为 1、
      切图后仍 1；audUND 干净、画面正常 → 非真实持续欠载。
- [x] 根因：display_valid 拉高时读引擎第一笔 SDRAM 突发未落地，首帧第 2 行起
      FIFO 短暂空一次即永久钉住粘滞位（line_seen 只跳过首行，不覆盖开机
      整帧过渡）。时序报告佐证：uart 路径正 slack、20 违例全在装载链。
- [x] 修复（top_tf_hdmi_audio.v，改动小）：开机稳态窗口——帧计数 vs 上升沿，
      前 4 帧不检测（vf_cnt<4），窗口后真欠载照常置位；面板 d0 同步恢复干净。
- [ ] 待用户重综合上板：开机首包 vidUND=0、切图后再查是否仍 0；确认后提交。

## 2026-09-28 第十轮：key3 上一张 + UART 'P' + 状态包增强 + 七段码退休（方案已定，实施完待回归确认）

- [x] 方案（用户拍板）：只加 P 命令；状态包保留字节放 img_idx+wav 标志；七段码退休保留硬件。
- [x] key3 上一张：pin.adc key3=B1（PULLUP）；fat32_ro 新增 o_bmp_prv 跳表
      （与 o_bmp_nxt 同拍建链、首项收口回填末项，成环对称）；sd_card_bmp
      key_prev 输入+第三去抖器+prev_req_pending（与 next 同规则：装载中记一次、
      坏图光标停在坏图上、下一拍 prv 继续回退、本轮装载只认一个方向）；
      top 接 key3 & vk_prev_n；uart_link CMD_PREV='P'(50)+vk_prev_n（100ms 脉冲）。
- [x] 状态包增强：pkt[6]={3'b0,img_idx}、pkt[7]={7'b0,img_wav}
      （sd_card_bmp 新增 img_idx_out/img_wav_out 输出）；uart_console.py 加 p 键
      + img/wav 解码。
- [x] 七段码退休：top 移除 6 位调试面板 mux（state/fat/flagA/flagB/underrun
      译码链），保留 seg_scan/seg_decoder 与引脚约束，显示固定占位 '8'；
      遥测源信号仍喂 uart_link（同一组状态两种出口的"出口"少了面板出口）。
- [x] tb_uart 8 项全绿（新增 T8 'P' 脉冲；T5 状态包校验更新）。
- [x] **主仿真暴露两个金模型潜伏 bug（都被 S8 揪出）**：①next/prv_bmp_idx 的
      `cand<6` 限制（o_type_map 遗留语义）——RTL 跳表全范围建链，第 6 项后的
      WAV 被金模型当 BMP，期望链错位+在途装载污染后续用例；②tmap 构建循环
      只建前 6 项。修：全范围 tmap/判 WAV；press_adaptive/S8 好图窗口 120M→220M
      （配对图=图+音频两段装载，S2 同量级）。新增 S8：从光标连续 prev 回退
      （坏图跳过→提交→像素 golden 比对→音频/静音切换），prv 表 dump 验证
      [0]=4 [1]=0 [2]=1 [3]=2 [4]=3 与设计一致。光标语义教训：img_idx=最近
      尝试项（提交/失败都写），期望链必须基于光标而非最后提交的图。
- [ ] 全 7 卡回归确认 → 用户重综合上板（key3 上一张、UART p、状态包 img/wav、
      面板占位）→ 通过后提交（Boxchan 无尾注）。

## 2026-09-29 第十一轮：boardtest 提速（SIM_FAST 直连扇区档）

- [x] 起因：修 S8 后单卡 382M→1104M 周期（S6 从假跳过变真实配对装载 + S8 新增），
      且主卡 SIM_AUTO 曾卡 20 分钟——根因是 verify_loop 找音频圈起点 idx 未命中时
      **每拍 O(n) 全量重扫 play_bytes**（旧代码潜伏，被修正后的模型首次踩中）。
- [x] verify_loop 改增量游标（MISS 也能在窗口内跑完并给诊断）；press_adaptive/
      S8 好图窗口 120M→220M（配对图=图+音频两段装载）。
- [x] **SIM_FAST=1 直连扇区档**：fast_sd_stub（stub_sd_card_top.v）+ C++ 按 LBA
      投喂（feed_fast_sd）+ boardtest 顶层 fast_en 二选一；默认档引脚级不变。
      实测 card.img 1104M/135s → 369M/50s（2.7×），7 卡并行 ~6min → ~2.5min。
      踩坑记录：①电平触发请求导致 end 后立即重锁存重出数（改边沿触发，同
      stub_sd_card_top 规则）；②扇区协议层固定块寻址（快速档无 HCS 协商）；
      ③**1 拍/字节超出下游节拍假设**（音频打包器按 ack 取字节→扫描项永不关闭，
      挂载后空转），加 PACE_DIV=4（2 拍实测仍崩，4 为边界内侧）。
- [x] 另一种踩坑：把 adapter 的 i_dval 输出改接到探针线导致 fat32_ro 的 i_dval
      悬空（挂载失败）——加探针时勿断原连接。
- [x] 双档全回归：快速档 7 卡 FAIL=0（主卡 33 项含 S7/S8）；默认档 7 卡 FAIL=0。
- [ ] 用户上板测试：key3 上一张 / UART p / 状态包 img+wav / 面板占位 + vidUND
      干净；全部正常后提交（Boxchan 无尾注）。
- [x] **上板验证通过（2026-09-29）**：七段码全 8 占位 ✓、上一张/下一张逻辑正确 ✓、
      串口通信正常（n/p/a/s）✓、轮播正常 ✓。提交。
