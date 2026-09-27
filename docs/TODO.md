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
