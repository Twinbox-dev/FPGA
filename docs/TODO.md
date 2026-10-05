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

- [x] **对比度调节**（2026-10-02）：注入点与亮度同一条调色级（`top` 的
      `adj_px`：对比度→亮度→一次钳位）。对比度 = 围绕中灰 128 的增益，7 档
      用**移位加减精确实现**（0.5/0.75/1.0/1.25/1.5/1.75/2.0，无 DSP/无乘法）；
      档位跨域照抄亮度格雷码；遥测进 ACK flags bit[4:1] 与状态包 flagA 高 4 位。
      命令 `.`/`,`（无需 Shift）；前端亮度·对比度合成一个瓦片（仍 5 个一行）。
      tb_uart 新增 T13（档位/钳位/两个遥测位）。**待上板验证**。
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

## 2026-09-29 第十二轮：控制通道分层 + 音量功能

- [x] 分层重构（高内聚低耦合）：`ctrl_core.v`（传输无关：命令表、虚拟按键脉冲、
      音量参数、状态包内容）+ `uart_link.v` 瘦身为纯 UART 前端（8N1 + [CMD,~CMD]
      成帧 → cmd/cmd_val；stat_req → 发 8 字节包）。将来以太网 frontend 接同一个
      ctrl_core，UART 不用删。
- [x] 音量功能：`+`(0x2B)/`-`(0x2D) 八档（上电=8 原始，0=静音），top 在送 HDMI
      核前 `×gain>>3`（gain=8 恒等，不影响现有字节级音频比对）。
- [x] tb_uart 重接为 uart_link+ctrl_core 双模块，新增 T9（音量档位/上下界钳位），
      9 项全绿；脚本加 +/- 键；.al 登记 ctrl_core.v（CompileOrder 41）。
- [ ] 待上板：音量 +/- 生效（听感）、其余功能回归；通过后提交。
- [x] 轮播周期调节（2026-09-29 续）：ctrl_core 持 `auto_period_s`(1..10s，上电 1s
      与旧行为一致)，命令 `>`/`<`；sd_card_bmp 的 auto_tick 由固定 1s 改为
      `auto_period_s × CLK_FREQ_HZ` 阈值比较；top 接线；tb_uart 新增 T10（档位/
      上下界钳位），10 项全绿。脚本加 `>`/`<` 键。
- [x] **上板验证通过（2026-09-29）**：音量 +/- 听感正常、轮播周期 `>`/`<` 生效、
      其余功能（n/p/a/s、面板全 8）回归正常。提交。
- [ ] **亮度调节（延后，未做）**：需在 75MHz 像素时钟域（`vout_data` 送 HDMI 核
      前）加缩放/偏移，且**视频读通道不在 boardtest 覆盖内**（老盲区）——须先定
      加在哪一级、是否 clamp、并复核该域时序余量（+1.76ns），不建议仓促上。

## 2026-09-29 第十三轮：命令应答（ACK）+ 亮度调节

- [x] **命令应答（return）**：每条被接受的命令（除 S）在参数生效后（延迟两拍，
      此时 vol/period/bri 均为新值）自动回 **ACK 包 5A|cmd回显|vol|period|
      img|wav|bri|00**；S 仍回状态包 A5。ctrl_core 输出 tx_req/tx_pkt 合并两口，
      uart_link 只改端口名。PC 脚本双类型解码（A5 状态 / 5A ACK）。
- [x] **亮度调节**：`]`(5D)/`[`(5B)，9 档（上电 4=原始 0 偏移），ctrl_core 持
      bri_level 并以**格雷码**输出跨时钟域（sd_card_clk→video_clk 2FF 同步，
      每步进只变 1 位，同步后恒为合法值）；top 在 video_clk 域每通道加偏移
      `(档-4)×16` 并钳位 [0,255]（display_valid 门控，黑屏不受影响）。
- [x] tb_uart 新增 T11（亮度档位/钳位 + ACK 端到端内容校验）+ drain_tx 排空
      任务（每命令回包后，recv 类用例前必须排空在途包），12 项全绿。
- [x] 踩坑两连：①T11 recv 在 fork 外起——ACK 在 pair 解码拍即开始发送，
      recv 错过首字节失锁（同 T5 竞态，send 必须 fork 并发）；②tx_pkt 拼接
      4 位字段未补零（52 位拼接零扩展致字段错位）——逐字节 {pad, field} 补齐。
- [x] 文档：docs/uart_link.md 双包格式/亮度实现/验证 12 项。
- [ ] 待上板：亮度 ]/[ 生效（画面明暗）、每键 ACK 回显（脚本应显示 ACK 行）；
      通过后提交。综合后复核 video_clk 域时序（新增 3×8bit 加法+钳位）。
- [ ] **下一步（用户已定方向）：以太网**。分层已就绪——新写 eth 前端接
      ctrl_core 即可；数据面（图/音上传）走 frame_fifo_write 写口（源无关）。
      板侧方案待定（W5500 SPI 硬协议栈 ~1 周 / 自写 RMII MAC+UDP 2-3 周）。
      PC 侧构想：Flask 小服务器嵌 UART 控制 + 网络数据通道（见下轮讨论）。
- [x] 补：tb_uart 最终 12 项全绿（T11a ACK 端到端 / T11b 档位钳位）。
- [x] **上板验证通过（2026-09-29）：ACK 应答 + 亮度 全部正常，功能一切稳定。提交。**
- [x] 时序复核（用户综合后的 final_timing.rpt，2026-09-29 17:22 版）：
      video_clk 域内 0 违例（最差 +2.192ns）——亮度加法+钳位干净；
      clk1 Summary 的 -1.468 为 **sd_card_clk→video_clk 跨域**路径（仅 2 端点：
      aud_l/aud_r → HDMI 音频乘法器，第五轮就有的电平跨越架构，靠 aud_valid
      保持 2084 拍保证采样，非本轮引入，上板稳定佐证良性）；bri_gray 2FF 同步
      未出现在违例中。clk0 -0.627 仍为 fat32 装载链临界（历史，上板无碍）。

## 2026-09-29 第十四轮：Web 控制台第一步（串口双控，以太网占位）

- [x] `scripts/web_console/`（app.py + templates/index.html）：Flask + pyserial
      + SSE 推流。双控开关（串口现 / 以太网 501 占位）；按键面板与
      uart_console 同键；板卡回包（ACK/状态）实时滚动；键盘快捷键。
- [x] 传输抽象：SerialLink（现）/ LoopbackLink（--loopback 开发档：命令回环
      假 ACK，无板卡验 UI 全链路）/ EthTransport 占位——与 FPGA 侧 ctrl_core
      分层呼应，以太网落地=后端加一个 Transport，前端/ctrl_core 不动。
- [x] 解码复用 uart_console.py（decode_pkt/decode_ack，单一事实来源）。
- [x] 文档 docs/web_console.md（用法/架构/接口约定/以太网落地顺序）。
- [ ] **依赖自装**：`pip install flask pyserial`（用户环境未装，本次未代装）。
- [ ] 待实测：真板连接（COM26）跑通页面控制 + ACK 滚动；通过后提交。
- [x] 按用户要求收敛 PC 端工具：**`uart_console.py` 并入 `web_console/app.py`
      并删除**（解码函数/CMDS 内置，Web 控制台成为唯一 PC 端工具）；串口号/
      波特率改为**页面选择连接**（去掉 argparse）；命令说明与 underrun 解读
      内嵌页面（可折叠块）；开发档改 WEB_LOOPBACK=1 环境变量。
- [ ] 待用户实测 Web 控制台（真板 COM26 跑通页面控制 + ACK 滚动）后提交。
      注意 flask/pyserial 需自装。
- [x] 前端 UI 重做（仪器面板风）：玻璃拟态顶栏+分段式双控滑块、渐变按钮+
      键位角标、终端式回包区（标签着色+clear）、underrun 命令说明内嵌可折叠块；
      loopback 判断挪到模块级（test_client 可测），SSE 全链路冒烟通过
      （link + ACK 推流）。
- [x] 用户重写 UI/后端并实测通过：串口枚举下拉（USB 优先+自动选中，唯一自动连，
      WEB_NOAUTO/WEB_BAUD）；按键按语义分组由 /api/keys 下发渲染（单一事实来源）；
      实时指标瓦片（音量/周期/亮度/img 从 ACK/状态包文本解析+闪烁）；自动轮询
      状态开关（1s）；hit 动画/终端式回包区等。粗查无问题（RANGE/元素 id/
      connected 门控齐全）。docs/web_console.md 已同步。

## 2026-09-30 第十五轮：以太网移植（官方 TEMAC + UDP 栈），待用户 TD 侧操作

- [x] 发现官方 demo `32_Ethernet_test`（APUG013 UDP 参考设计）：TEMAC_CORE
      官方 MAC IP + udp_ip_protocol_stack 官方协议栈 + RGMII PHY（板载
      RTL8211）——自写 MAC 2-3 周的工作量被官方 IP 取代，W5500 方案废弃。
- [x] 移植：demo 的 15 个源文件拷入 board/.../ETH/（temac_block、rgmii 接口、
      IDDR/ODDR、client fifo、时钟生成等原样；不拷 tpg/loopback/test 顶层）；
      新写 `eth_front.v`（应用层：RX 跳 8 字节头解析 [CMD,~CMD]，TX 组头+应答
      包 16 字节；不依赖 demo 缺失的 ram_fifo 库宏）+ `eth_subsys.v`（子系统
      打包：时钟/复位/UDP 栈/TEMAC/fifo/eth_front，网络配置 192.168.137.2
      百兆）；top 集成 + 命令仲裁（eth 优先）+ RGMII 引脚（demo adc 同款）+ .al
      登记 18 项（TEMAC_CORE.ipc 在 IP_FILE 段）。
- [x] tb_uart 12 项回归全绿（top/ctrl_core 改动不涉主仿真路径）。
- [x] 文档 docs/ethernet.md（网络配置/帧格式/文件清单/CDC 设计/待办）。
- [ ] **用户 TD 侧**：重新生成 TEMAC_CORE.ipc → 综合 → 查新时钟域时序 →
      上板网线直连（PC 侧 192.168.137.1/24）。
- [x] **Web 控制台 EthTransport + eth 模式落地**（2026-10-01）：后端 UDP socket
      （bind 本机 :2 收包/发往板卡 :1，剥 8 字节应用头解码）；两条链路共享
      `SUBS` 订阅表推同一条 SSE；前端双控开关改为两通道**各自独立连接**
      （`connState`），eth 卡片换成真实连接面板（板卡 IP 输入 + 连接/断开）。
      未上板验证（待网线），本机路由/收发已用测试客户端冒烟通过。
- [ ] **遗留风险**：①应用头格式从 tpg 源码反推（APUG013 PDF 加密未读），若
      上板不通先核对头的字节序/长度语义；②demo 顶层 udp 栈 RX 有
      `.temac_rx_valid(!temac_rx_valid)` 取反（fifo _n 低有效），已照抄；
      ③TX 首字节时序（ack 拍 valid 置位、SEND 拍出 buf[0]）需上板验证。
- [x] **上板验证通过（2026-09-29）：ACK 应答 + 亮度 全部正常，功能一切稳定。提交。**
- [x] 用户重综合通过（无需手动生成 TEMAC IP——TEMAC_CORE_gate.v 网表直接参与
      综合，.ipc 留作以后重新生成的配置）。时序复核见 docs/ethernet.md：
      **setup 全局 0 违例**，以太网各域干净；hold 主体为 eth↔sd 跨域握手
      路径伪违例（2FF 同步覆盖，功能安全），已记录判读依据。
- [x] **根因④（最根本，千兆收发时钟）**：RGMII 时钟接法是从**百兆** demo 抄的
      （`gtx_clk/gtx_clk_90` 都接 0° 时钟、`rgmii_rxc` 直连原时钟）。千兆 125MHz
      必须移相 90°。已照厂商 **HX4S20 千兆例程**（`DEMO/33_HX4S20_Etherent_test_
      01_02_final_1000`）改：`gtx_clk=clk_125_out`、`gtx_clk_90=temac_clk90`、
      `rgmii_rxc=rx_pll 的 clk1_out`。**rx_pll 内联在 eth_subsys.v**（不单独建
      文件——TD 保存工程时会覆盖 .al，手工新增的源文件条目会被抹掉、报
      `xxx is a black box`；生成出来的 IP 本就是 EG_PHY_PLL 原语包装）。
      症状：收发全废（收到的字节是垃圾、发出去的 PC 收不到），但链路协商正常。
      ⚠ rx_pll FIN=125M 仅千兆可用。
- [x] **以太网控制实测通过（2026-10-02）**：ping 9/10 通；Web 控制台 eth 模式
      下所有命令（N/P/A/S/音量/周期/亮度）都能触发、ACK 正常。
- [x] **根因⑤（命令晚一拍）**：顶层命令仲裁用寄存器 `eth_cmd_c` 送 ctrl_core，
      非阻塞赋值让 `eth_take` 那一拍送出的还是**上一条**命令，且本拍命令被丢。
      表现：ACK 错位一拍（按 N 回 A 的 ACK）、画面"感觉慢几秒"。已改为组合取用
      `eth_cmd`。**这条是用户实测发现的**（"按下自动轮播，再按下一张，回来的是
      自动轮播的 ACK"）。
- [x] **顺手修掉**：`eth_front` 发送漏发 8 字节应用头（`tx_buf` 只有 64 位却按
      16 字节索引），改 128 位整帧 `{tx_pkt, TX_HDR}`。
- [x] **补 eth 仿真**（2026-10-02，用户要求）：`tb_ethfront`（11 项，含应用头不
      参与解析/跨包不误配/栈未就绪不丢帧）+ 把顶层仲裁抽成 `cmd_arb` 模块
      （放 `ctrl_core.v` 内，不新增文件以免被 TD 覆盖 .al）并补 `tb_cmd_arb`
      （6 项，含"连续两条命令不串"）。两个 TB 都做了**变异验证**：
      - 应用头改回旧写法 → tb_ethfront T6/T8 FAIL
      - 命令字节过寄存器打拍 → tb_cmd_arb T1/T2/T4 FAIL（复现"ACK 错位"症状）
- [x] **自动轮播状态遥测**（2026-10-02）：`sd_card_bmp.auto_play_out` →
      `ctrl_core.auto_on` → ACK 的 flags 字节 bit0 + 状态包 flagB bit4；
      前端加指标瓦片 + A 按钮高亮。**顺带抓出并修掉一个潜伏 bug**：ACK 拼接
      只有 63 位（`{3'b0, bri_level}` 少一位）→ 高位补零、字段错位半字节。
- [x] **HDL critical 全清**（2026-10-02）：隐式声明（HDL-7225）改为先声明后用、
      RGMII 端口重复声明（HDL-5372）删除、`tx_rdy_w` 重复声明（HDL-5007）删除。
- [x] **速率决定（2026-10-02，用户拍板）**：**跑千兆**。综合时序有违例
      （125M eth 域 Fmax 44MHz、setup -5.3ns/281 端点，SDRAM 域也被拖），
      **属已知且接受的风险**——功能实测通过、最坏只影响以太网模块本身。
      `GIGABIT` 参数 + `pin.adc` 注释保留了切回百兆的完整方法（百兆时序全绿）。
- [x] **根因③（千兆发送）**：RGMII 发送引脚缺 `OUTDEL`——千兆 TXC=125MHz 时
      时钟须比数据晚 ~2ns 才采得准。已照厂商 **HX4S20 千兆例程**
      （`DEMO/33_HX4S20_Etherent_test_01_02_final_1000`）改 `pin.adc`：
      `txc {DS=16; SLEWRATE=FAST; OUTDEL=3;}`、`tx_ctl/txd {DS=16; SLewRATE=FAST;}`。
      症状：链路/接收全正常、板子也在发包，但 PC 收不到任何字节。
- [x] **根因⑥（复位后 eth 永久失效，2026-10-02 二次上板）**：按复位键打断以太网
      后 IP 回不来（显示/串口正常、PHY 链路仍在 1G、拔插网线无效 → 只有板内 eth
      逻辑死了）。我们自己的状态全部有复位且自校正、IP 暴露的复位一个没漏 →
      只能是 IP 内部（门级网表/加密 IP 的初始化多半只在配置时刻生效）。
      已改：`eth_subsys` 只上电复位一次（`eth_rst_latch`），按键复位不再打断 eth。
      卡死时用断电重上电恢复。
- [ ] **以太网功能实测待网线**（PC 侧 192.168.137.1 + Web 控制台 eth 模式）。
- [x] **首次上板实测（2026-10-02，网线到位）：ping 不通，定位到两个根因**——
      **①（主因）`eth_rst_in` 极性接反**：`clk_gen_rst_gen.reset` 高有效，
      demo 的 `~key1`（按键平时为高）在"不按"时是 0；我们的 `rst_all` 平时
      已是 0，却写成 `~rst_all` → 平时恒 1 → 整个以太网子系统永久复位
      （PHY 链路仍正常协商，故现象极迷惑）。已改为 `eth_rst_in = rst_all`。
      **②
      `input_local_ip_address_valid`/`input_local_udp_port_num_valid` 移植时
      错接 `1'b0`（以为"不用动态 IP/端口"），官方栈靠该 valid 装载地址/端口，
      0 = 从未装载 → 板卡无 IP → ARP 不回。已改回 demo 用法（valid 恒 1 +
      常量地址/端口）。另发现官方 demo 上电 IP 是 240.**0**（每 10 分钟 +1），
      用 demo 验链路要 ping 240.0。详见 docs/ethernet.md。
- [x] **网络配置改为 192.168.137.x**（2026-10-01，用户笔记本地址）：板卡
      `LOCAL_IP=192.168.137.2` / 回包 `DST_IP=192.168.137.1`（子网 255.255.255.0），
      端口 1/2 不变；eth_subsys.v 参数 + 头注释、docs/ethernet.md、docs/web_console.md
      同步。
- [ ] 可选优化：SDC 加 eth↔sd 跨域 set_false_path（当前伪违例已记录判读依据）。

## 2026-10-02 第十六轮：以太网调通 + 千兆决策 + 对比度

**以太网排障全记录（按根因发现顺序，详见 docs/ethernet.md）：**
- [x] **根因①（主因）**：`eth_rst_in = ~rst_all` 极性反——clk_gen_rst_gen.reset
      高有效，rst_all 平时为 0，取反后恒 1 → 子系统永久复位（PHY 链路照常协商，
      现象极迷惑）。→ `eth_rst_in = rst_all`。
- [x] **根因②**：`input_local_ip_address_valid` 等错接 1'b0 → IP 从未装载。
      → 照 demo 用法（valid 恒 1 + 常量地址）。
- [x] **根因③**：RGMII 千兆收发时钟照抄百兆接法——TX 90° 时钟没接（两个都 0°）、
      RX 时钟没过 rx_pll 再生、发送引脚缺 OUTDEL。对照厂商 **HX4S20 千兆例程**
      （33 号）修正；rx_pll 内联进 eth_subsys（不新增文件，避开 TD 覆盖 .al）。
- [x] **根因④**：顶层命令仲裁 `eth_cmd_c` 经寄存器打拍 → 每条命令推迟到下一次
      按键才生效（"ACK 错位一拍"+"感觉慢"）。→ 组合取用（eth_cmd 在 pending 期
      稳定）。**用户"ACK 顺序反了"的观察直接定位此 bug。**
- [x] **根因⑤**：eth_front TX 漏发 8 字节应用头（tx_buf 64 位按 16 字节索引，
      越界读）。→ 128 位整帧 {tx_pkt, TX_HDR}。
- [x] **根因⑥**：按键复位打断以太网后 IP 回不来（门级网表/加密 IP 的初始化只在
      配置时刻生效——厂商例程从不复位 eth）。→ `eth_rst_latch`：只上电复位一次，
      按键复位不再打断。**复位后 eth 卡死用断电重上电恢复。**
- [x] **诊断方法**：数码管临时改 eth 诊断面板（1 秒窗口计数），逐级定位
      "收在动/发不动/栈不回包"；**数码管物理顺序 dig0=最右**（与最初设计相反，
      已记录）；完成后已拆除恢复固定显示。
- [x] **以太网上板验证通过（2026-10-02）**：ping 通、Web 控制台 eth 模式全部
      命令可用。已知现象：按复位键后 eth 不受影响（根因⑥修复）。
- [x] **速率决策（用户拍板）**：跑**千兆**。时序违例（125M eth 域 WNS -3.9ns、
      SDRAM 域 -6.7ns）**已知且接受**——功能实测通过，最坏只影响 eth 模块。
      GIGABIT 参数保留切回百兆的完整方法（百兆时序全绿，网卡须强制 100M）。
- [x] **PC 网卡注意**：千兆用自动协商；百兆必须强制 100M 全双工（否则协商到
      1G 而 MAC 是百兆 → 链路显示已连接但数据不通）。

**对比度调节（2026-10-02 上板验证通过）：**
- [x] 命令 `.`（升）/ `,`（降），7 档（0.5/0.75/1.0/1.25/1.5/1.75/2.0），
      上电 = 2（原始）；围绕中灰 128 的增益，移位加减实现（不占 DSP）。
- [x] 调色级扩成"对比度 → 亮度 → 一次钳位"单级流水；ct_gray 格雷码跨域
      （照抄亮度方案）。
- [x] 遥测：ACK flags 字节 bit[4:1] + 状态包 flagA 高 4 位（保留位，包长不变）。
- [x] 前端：亮度·对比度合成一格瓦片（仍 5 个一行）；按键面板新增"对比度"组；
      ACK 只报本条命令相关项（S 仍全量，纯 PC 侧解码逻辑）。
- [x] tb_uart 19 项（T13 对比度 + T5 断言随 flagA 更新）；全量回归通过。

## 2026-10-03 第十七轮：音频脉动条（底部横条）

- [x] **方案（2026-09-30 与用户对齐）**：底部横条全宽 40 行 / 蓝→绿→红渐变 /
      快升慢降 / 白色峰值刻度线 / `Q` 开关（默认关）/ 灵敏度可调（`;` `'`）/
      画面底部被遮 40 行（用户选 A 方案直接盖）。
- [x] **新模块 `SD/pulse_bar.v`**（双域单模块）：
      音频域（sd_card_clk）包络 = max(|L|,|R|)（**音量后**信号 → 音量低条也矮），
      攻击每样本 ≤+16、衰减每 32 样本 -1（48kHz 满格 ~170ms）；灵敏度 = 右移量
      20-3*sens；env 8 位格雷码跨域。视频域（video_clk）行计数（**de 下降沿**
      +1，行内全程 r_cnt==本行行号）、fill=env*40>>8、渐变两段线性插值、
      峰值线白色。**组合输出**（打一拍会与像素流错位 1 像素）。
- [x] **渲染位置**：调色级（对比度/亮度）之后覆盖——条为绝对色不受调色影响。
- [x] **调试中抓出 3 个新坑**（全部 tb_pulsebar 首 Run 暴露）：
      ①2 位格雷码译码写反（{g1^g0,g0} → {g1,g1^g0}），灵敏度整体错一档；
      ②`env_v*6'd40` 表达式宽度按 LHS=8 位 → 乘法先截断再 >>8 恒 0（与 ACK
      63 位同类坑，**先落宽乘积再切位**）；③位切片 [13:6] 手滑（>>6 ≠ >>8）。
- [x] **ctrl_core**：`Q`(51)/`;`(3B)/`'`(27) 命令 + bar_en/bar_sens 寄存器 +
      bar_sens_gray 输出；ACK flags 重排：bit[3:1]=对比度（原 [4:1]）、
      bit4=脉动开关、bit[6:5]=灵敏度（包长不变）。
- [x] **tb_pulsebar** 22 项 ALL PASS + 变异验证（格雷译码改错版 → 7 项 FAIL）。
- [x] **tb_uart** T14（Q 开关/灵敏度钳位/ACK 遥测）+ T13b 掩码随 flags 重排更新
      → 23 项 ALL PASS。
- [x] **前端**：新增"音频脉动"按键组（Q 高亮跟随板端状态）；键盘直发支持
      `q` `;` `'`；ACK 文本显示 脉动/灵敏度。
- [ ] **待用户综合上板**：`pulse_bar.v` 已登记 .al（CompileOrder 43）。
- [x] **冷上电黑屏根因确诊（2026-10-03，用户 UART 遥测 `S` 回读）**：黑屏时
      `state=0x0` = **SD 卡 init 未完成**（嫌疑①坐实）——rst_all 释放只等
      PLL+20ms，SD 卡自身上电 boot 可达秒级；init FSM 对未就绪的卡无限重试
      却卡在不前进的状态，boot 链"一次性、无重试"。
- [x] **修复：boot 看门狗自愈（A 方案）**：rst_all 释放后 display_valid 5s
      内不来 → 自动重拉 rst_all 1ms（等效自动按复位键，整体重跑；以太网不受
      影响——其只上电复位一次）。**限 3 次尝试**（真坏卡不无限循环重置 UART）；
      display_valid 出现即冻结；手动复位键重置尝试计数。修复本身在 top
      （仿真边界外，与 video_delay/eth_front 同类），上板验证覆盖。
- [x] **脉动条加高 40 → 64 行**（用户实测 40 行脉动感不足）：BAR_H 取 2 的幂，
      fill=env>>2 纯移位、渐变断点随条高缩放（0/32/63 锚点蓝→绿→红）；
      渐变公式若沿用固定断点会在 t>39 溢出花色（已参数化）。tb 同步 ALL PASS
      （其中两处期望色是我手算错误、TB 抓出修正）。
- [x] **前端灵敏度按钮顺序**对齐"减左加右"惯例（app.py groups 顺序 + fallback）。
- [x] **复位键偶发丢音（嫌疑③坐实）+ 音频 boot 自愈**：看门狗修好黑屏后，
      用户在健康系统上按复位键，暴露出音频 boot 链（首图提交→扫描→boot_ald
      →音频提交）"一次性、无重试"的竞争——任一握手脉冲被丢即永久静音。
      修复：**音频 boot 看门狗**（sd_card_bmp 内）——图已提交+扫描完+当前图
      有配对而 8s 未进入播放态（PL_RUN）→ 重跑整条音频 boot（scan_start_pulse
      重扫描 + 清 ald_boot_done），图像不闪。**限 3 次**（播放成功即清零）。
      配套：①boot_ald 触发条件加 `!aud_rescan`（rescan 清 ald_boot_done 到
      扫描块清 done_r 之间有 1 拍窗口，会拿旧扫描数据提前点火抢写口）；
      ②scan_start_pulse 分支补 `aud_scan_done_r <= 0`（同因）；
      ③新增 `aud_playing = (plstate == PL_RUN)` 观测。
- [x] **音频自愈上板结果（2026-10-03，用户实测）**：复位键偶发丢音概率**明显
      下降但未根除**（少数情况下音频起不来）。用户决策：**本轮停止修复**，
      记为已知瑕疵——初赛为源码+视频+文档线上提交，不影响。
      【后续排查线索】①看门狗触发条件要求 `pair_valid[img_idx] && aud_scan_done_r`，
      若复位竞争导致扫描本身失败（done_r 未置位），看门狗不会武装——需先确认
      失败时扫描是否完成；②3 次重试用尽后放弃，若根因是卡侧（用户怀疑卡本
      身）重试也无济于事；③可加"扫描失败重试"（当前只有 boot_ald 成功路径的
      看门狗，扫描环节失败无观测）；④digit 面板已拆，可临时复用观测 aud 相位。

## 2026-10-03 第十八轮：多分辨率信箱适配（基础合规 + 扩展 A3）

- [x] **背景**：赛题基础要求写明"读取 640x480 24bit BMP"，而 bmp_dec 此前只接受
      1280x720——评委按赛题规格放裸 640 卡会被当坏图跳过（合规缺口）。用户拍板
      契约分层：**PC 只解压/转容器（分辨率保持原样，仅超 1280x720 时等比缩小），
      FPGA 信箱适配任意 <=720p 的 24bit BMP → 1280x720 输出**（居中+黑边，
      比例不失真——不做拉伸，4:3→16:9 拉伸会变形）。
- [x] **bmp_dec**：头校验放宽为 `1<=w<=1280 && 1<=h<=720 && 24bpp && 不压缩`；
      导出 o_img_w/h；**行 4 字节对齐填充跳过**（pad=(4-w*3%4)%4，⚠ 不能取
      row_bytes[1:0]——4 对齐后恒 0）；完成判据改为 px_cnt==w*h；新增
      **o_hdr_ok**（byte53 置位、i_restart 清零）。
- [x] **frame_fifo_write**：新增 `vrow_off` 端口（20bit 有符号，字）——vflip
      首地址加该偏移，使部分高度会话（h<720）的首流行落在帧的 y0+h-1 行
      （居中）。全帧会话 off=0 行为不变。tb_readeng 新增 T2b 验证（首字精确
      落 BUF0+599*640）；⚠ T2b 首版单位写错（-120 行 vs -76800 字）。
- [x] **sd_card_bmp 信箱打包器重写**：装载序列重排 LD_FILL（全帧涂黑会话，
      460800 字垫非图像区）→ LD_FILE（等 o_hdr_ok）→ LD_IMG_ACK（len=img_h*640）
      → LD_STREAM（发射）。发射 FSM 按流序逐行输出 1280px：行内 [x0,x0+w) 弹
      **64x24 弹性缓冲**（纯触发器堆——源 1px/96clk ≪ 汇 1px/clk，边距期积压
      ~14px，刻意避开大深度 BRAM 推断陷阱），窗口外补黑。写口 mux 三态
      （fill/音频/图像），vrow_off 涂黑会话强制 0（负偏移会回卷砸音频区）。
- [x] **调试三连（S3b 棋盘格 8px 相移暴露）**：
      ①C++ 写模型 exp_len 硬编码 N_WORDS → 信箱会话永不 finish → 3s 超时
      （S5-S8 连锁）→ 改用 dut->write_len；
      ②golden 信箱模型行映射写反（br=h-1-row → br=row）：解码器按**文件序**
      发射（文件行 0=显示最底行），发射序比对不可再翻转——IMG003 棋盘格
      （8px 周期）第一次暴露该类错误，横向均匀的 IMG001/002 不敏感；
      ③**o_hdr_ok 缺失**：img_w_dec 跨装载保持旧值，`(img_w_dec!=0)` 判据让
      新会话拿**上一张图的尺寸**提前开门（S8b 出现 IMG004 被 320 列窗口
      letterbox 的实锤）→ bmp_dec 新增 o_hdr_ok（restart 清零）。
- [x] **测试资产**：gen_bmp 新增 IMG005(640x480)/IMG006(333x217 奇宽+行填充)/
      XODD(500x300)/ZBADSIZE(1281x721 拒绝)；gen_card 自动纳入；golden 信箱
      模型（发射序比对，含行对齐 stride）。
- [x] **回归**：mini 单图卡 23/23；全量 7 卡 FAIL=0（card 33 含 4 个多分辨率
      用例、card_mbr 30）。card.img 装载时长因小图显著缩短。
- [x] **PC 契约落地**：prep_media.sh / 桌面 bmp转720p.py 改为"保持原分辨率，
      仅超 1280x720 等比缩小"，尺寸校验随 BMP 头。
- [ ] **待用户综合上板**：裸 640×480 卡直接可显示（居中黑边）= 基础合规 +
      扩展 A3 同时拿下。
- [x] **板级"按下一张没反应/环缺图/单向切图"三 bug 连环（2026-10-04，真实卡
      结构复现卡 card_real.img 在仿真中完整复现后修复）**：
      ①**文件请求双主人无仲裁**：音频扫描的 aud_req_pulse 与图像 file_req 直接
      或入 fat32，扫描窗口（boot 后 1-4s，每张无配对图切换也会重扫描）内两请求
      同拍撞车，图像请求被吞 → "按下一张没反应"。修复：扫描项改道装载 FSM
      （scan_kick），fat32 的 i_file_req 单一来源。
      ②**scan_req_active 永不清除**：①的改道引入——扫描项经 FSM 发完请求后
      标志滞留 1，此后所有图像装载的 file_idx 被劫持成滞留的 aud_req_idx（指向
      某个 WAV）→ img_err 弃载 → 环只剩旧图、无法循环。修复：LD_FILE 发完请求
      即清 + 装载发起时兜底清。
      ③**开机首图捕获竞态**：first_idx_r 捕获与 boot 装载发起同拍，装载采到
      旧值 0（= WAV 条目）→ img_err 跳过又把真首图跳过。修复：装载发起门控加
      first_idx_captured。
      验证：card_real.img（卷标+LFN+SYSTEM~1+交错文件，1:1 复刻用户卡结构）
      27/27；全量 7 卡 FAIL=0（33/30/1/23/31/25/27）。

## 2026-10-04 第十九轮：环端失灵排查（板级"环还是坏的"第二轮）+ 'L' 转储通道

- [x] **覆盖盲区实锤**：board_sim 原 S5/S6 只从 boot 图按 2 次 next、S8 prev 回退到
      首个合法图即 break——多图卡的**回绕边**（尾图 next→首图 / 首图 prev→尾图）
      从未被踩到。板级两轮"环端失灵"均落在此盲区，仿真全绿≠环没病。
- [x] **S9/S10 全环遍历用例**：从光标双向各绕整环一圈回起点，每步自适应期望
      （合法图提交比对/非法项跳过）。S8 补 cursor 写回（此前 S8 后 cursor 失真，
      S9 首步会拿错误的期望起点）。
- [x] **真卡镜像落盘**：用户 TF 卡（14.6G，usbipd→WSL sde）**只读** dd 前
      256MiB（用户约束 ≤1G）→ img/card_user_real.img。dump_dir.py 解析：MBR
      （LBA2048）+ FAT×2 + 数据区@17MiB；目录序 IMG0.WAV→…→IMG0.BMP 与
      mdir 一致；全部簇链在截取内（scripts/dump_dir.py 复核 OK）。
      IMG3/IMG4 无配对 WAV、IMG3/4/5 为多分辨率小图——正是"切到 IMG3 死"的
      高危结构。
- [x] **'L' 播放列表转储落地**（板级排障主通道，此前 ctrl_core 只有空管道）：
      sd_card_bmp 新增生产者（pl_dump_start → N+1 个 64bit 包，包间 400µs）。
      条目包 {01,idx,is_bmp,pair_valid,pair_wav,nxt,prv}、收口包 {10,计数/
      first_bmp/光标/装载状态}。is_bmp 用跳表重建（i==first_bmp 或
      nxt[prv[i]]==i；i==0 单独判；bmp_cnt==0 全 0）——**不占用** fat32_ro
      与音频扫描共享的 i_pl_idx 查找口。top 三线接线；board_top/board_sim
      S11 golden 比对（建表算法同构重构）；docs/uart_link.md 包格式 +
      scripts/pl_dump.py（串口/UDP 双模式，nxt 环完整性自动判断裂）。
- [x] **boardtest 副本重建事故与恢复**：误用 board 副本直接覆盖 boardtest
      副本（SIM_FAST 端口/1ms 去抖 ifdef/探针标注丢失）→ scripts/
      sync_boardtest_sd.py 从 board 副本 + 三类增量确定性重建（26 处标注，
      含丢失轮次的 4 个新探针）。**教训：两副本差异是结构性的，同步必须走
      脚本，禁止裸 cp。**
- [ ] **待仿真结论**：build_ring/sim_ring × card_user_real（全保真档）后台
      运行中——S9/S10 过=RTL 环逻辑对真卡结构无恙，板上故障另有其因（'L'
      转储上板取证）；S9/S10 挂=仿真复现，直接修。
- [ ] 待用户综合上板（多分辨率信箱 + 本轮全部改动），上板先发 'L' 存证。

- [x] **第十九轮续（同日深夜）：S10 假失败复盘——RTL 无罪**
      首版 S10"上一张环遍历"4 个像素失配经 HDROK 取文件序列实证为**测试自身
      bug**：press_adaptive 硬编码 press_next，prev 环实际又按了一圈 next——
      模型按 prv 链出期望、RTL 按 nxt 执行，内容错位=假失败（"陈旧 write_len"
      亦同理：fidx=7 配 len=307200 恰是 IMG5 640x480 的正确长度）。
      HDROK 序列证明 RTL 导航完全自洽：S9 从光标 7 出发 7→9→1→3→5→6→7
      精确回环。修复：press_adaptive 加 prev_dir 参数。
- [ ] **修正版 S10（真 prev 环）card_user_real 重跑验证中**。→ 过=prev 回绕边
      也有实证，环问题可以安心上板。
- [x] **附：SIM_FAST 档在 card_user_real（MBR+真卡结构）boot 后死锁**——快速档
      缺陷独立立卡，待查（不影响全保真档结论）。

## 2026-10-05 第二十轮：写侧分叉探针（下轮开工，方案已定）

**现状（板上实证）**：多分辨率信箱功能打通——IMG3/4/5 装载成功（解码像素=w×h 整、
已发射=len 整、锁存高度正确）、环全健康、超时兜底生效。**残余：图像雪花/撕裂/
白条 + 音频杂**（黑边逻辑正确、坏点随切图变动）。

**时序线**：into_burst 组合链违例 −6.7(4a8362f 就有)→−7.5→−7.9→−8.196（窗口化
比较仍违例，报告 01:58 为窗口版）→ **已寄存化**（09ec7c6，判决晚一拍无功能
影响，tb_readeng 全 PASS）→ **待综合看报告**：into_burst 路径应消失。
官方 SDRAM IP 自带违例不可调，我们的逻辑必须时序干净。

**撕裂定位三分法（下轮实施写侧分叉后）**：
- 写侧分叉数据 ≠ 原图 → 解码/发射上游错
- 写侧分叉 = 原图，显存读回 ≠ 原图 → 写引擎/地址错（当前最大嫌疑）
- 两者都 = 原图 → 显示读通路错
音频杂大概率与撕裂同源（共 SDRAM 写通路，音频缓冲同受害）。

**写侧分叉实施清单（用户拍板开工，注意：上位机以太网模块改动多别改错）**：
1. sd_card_bmp：输出 tap_word[31:0]/tap_val（图像会话 img_word_val/img_word，
   涂黑/音频不打）；tap 时钟=sd_card_clk
2. top：tap 三线接 eth_subsys → eth_front（加 tap_clk/tap_val/tap_word 端口）
3. eth_front：Gray 异步 FIFO（512×32，双钟 sd_card_clk→udp_clk，写 125M 域
   推/读拉）+ 流包 FSM：FIFO 攒 255 字发一包（应用头 8B[AA BB CC DD 00 03
   len] + seq[15:0] + 255×word LSB 字节先发，udp_data_length=8+2+1020=1030）；
   与现有 ACK 16 字节小包路径并存（TX_WAIT 分支仲裁：tx_pulse 优先）；
   序号供 PC 检测缺口；包尾不足 255 字不封包（等下次装载，FIFO 跨会话
   fifo_aclr 语义待定——建议装载开始清 FIFO+seq 清零，PC 按 seq 回卷判新会话）
4. PC：EthTransport 收流包（type 区分）→ 按 seq 重组 words[]（缺口报告）→
   前端 canvas：RGB565→RGB888，行 r 落显示行 y0+h−1−r（h=收到字数/640，
   y0=(720−h)/2，vflip 补偿同 RTL）→ 与原图逐字比对差异报告
5. 验证：装载 IMG2 应收满 460800 字；比对差异定位写通路
6. 已知风险：Gray FIFO 手写需仔细（跨钟指针同步）；eth_front TX 状态机扩展
   勿动 ACK 路径；综合后先查时序报告确认无新增违例

**提交状态**：fix/multires-engine-timing 分支 @09ec7c6（dde10a8 全量+寄存化
修正），main @4a8362f。分支里混入临时文件（scripts/_fix_engine.py 残版、
boardtest/logs/*.log）待清理。

## 2026-10-05 第二十轮：写侧分叉落地 + 撕裂根因实锤修复（pad 前导误发）

**撕裂根因（仿真全卡复现并修复）**：
- 现象：全量回归所有「像素与 golden 逐像素比对」失败，首失配全部在行 0
  （字#0/1/20/80/160/236…），got 多一个 00000000 黑字后全体右移一字。
- 钉死：失配模式与「会话开头多插一个 pad 黑字」完全自洽（小图行 0 开头是黑，
  失配推迟到首个非黑像素才显形，位置才"散乱"；正反两向失配都对得上）。
- 根因：LD_IMG_ACK 同拍发 emit_start_pulse 并切 LD_STREAM，img_emit_en 晚一拍
  升起——这一拍 `!img_emit_en && LD_STREAM && !pad_done` 成立，**pad 错发在会话
  开头**，占掉第 0 字预算：整帧 SDRAM 内容右移一字、最后一个真字不落 SDRAM。
  板上撕裂/白条的直接根因；pad_done 被吃掉后末尾补偿也不复存在。
- 修复：pad 加 emit_seen 前置（img_emit_en 曾升起才许补），复位/load_start_pulse
  清零。tb_readeng 直注 FIFO 测不到打包器，所以 T30-T33 拦不住。
- 上两次提交里 logs 是旧的（33 项小套件，09ec7c6 未重跑全量），回归从未暴露。

**写侧分叉（本轮完工，tb_ethfront 15/15 全绿）**：
- sd_card_bmp：tap_word/tap_val（原有）+ 新增 tap_end（离开 LD_STREAM 检测，
  正常收尾/超时/img_err 弃载都覆盖；弃载不发则 FIFO 残字污染下一帧）。
- eth_front（全内联，不加新文件避 .al 登记问题）：
  - 内联 tap_afifo：Gray 异步 FIFO 512×32（tap_clk=sd_card_clk 写 → udp_clk 读）。
    ⚠ 两个教训：①full/empty 必须寄存——组合式 `next==对侧同步指针` 与指针推进
    互为组合环，"恰好剩一个字且使能有效"时振荡（Verilator 拒绝收敛）；寄存化后
    只可能悲观不可能越界。②寄存读出弹的是**当前队头 mem[rbin]**（写 mem[rbin_next]
    会整流丢首字、全体移位一位）。
  - TX 统一 FSM：TX_WAIT/RDY/ACK/SEND + S_BUILD；tx_sel 选 ACK 包（tx_buf 16B）/
    流包（str_mem 1030B BRAM 攒包）；ack_pend 记账（pulse 在途不丢，ACK 发完时
    若恰有新 pulse 则保留）；ACK 优先，流包补位。
  - 流包：type=0x0003，seq[15:0]+N×32bit（N=255 满包/尾短包），字 LSB 字节先发，
    udp_data_length=10+4N；BRAM 攒包时序：弹字 bi≡1(mod4)、锁存 bi≡2、写字
    bi≥11 写 bi-1 地址、末写拍 4N+10。
  - 会话收口：tap_end → tap 域 toggle → udp 域边沿 → flush_pend，等 32 拍写指针
    沉降后排空 FIFO，排空即 seq 归零（PC 靠 seq==0 判新会话）。
  - sys_rst（rst_all）两域各自同步：eth 的 reset 上电锁存一次，按键复位只能靠它，
    否则 FIFO 写侧清读侧不清、指针错位。
- eth_subsys/top 接线：sys_rst=rst_all、tap_clk=sd_card_clk、tap_* 三线。
- 写侧纯旁路：FIFO 满丢字不反压主路；不碰 frame_fifo_write/into_burst 雷区。

**PC 端（web_console）**：
- app.py：EthTransport 读线程分流包分支（type 0x0003）：seq 重组（seq==0 清会话、
  缺口计数），静默 0.4s 收口整帧入 ETH_FRAME；SSE 只推 frame 通知；
  /api/frame 返回原始字流（小端）+ X-Frame-* 元数据头。
- index.html：流帧卡片 + canvas 渲染（RGB565→888，行 r 落 y0+h−1−r 同 RTL vflip）
  + 可选本机 24bit BMP 对照 diff（差异标红 + 计数）。

**提交状态**：fix/multires-engine-timing，待回归全绿后提交；综合上板后合并 main。
**上板顺序**：综合 → 查时序报告（into_burst 路径应消失；千兆 eth −3.6/官方 SDRAM
−6.7 为已知接受）→ 烧录 → 连以太网 → 装载任意图 → Web 前端看流帧与 diff。

**第二十轮补丁（资源爆掉修复，同日）**：首版 str_mem 攒包缓冲（1030×8）写进
带复位的 FSM 大 always 且深度超 1024 → TD BRAM 推断失败，落成 8240 FF + 千位
读 mux：LUT 23623/19600（120%）、mslice 6870>4900 综合报错。修复=三要素齐上
（`/* fehdl force_ram=1, ram_style="bram" */` + 无复位独立 always 读写口 +
深度 1024），满包字数 255→253（10+4×253=1022≤1024）；tap_afifo 的 mem 同样
搬进独立无复位 always + pragma。tb_ethfront 15/15 复验全绿。**教训：本项目
新增任何存储阵列，TD 推断三要素是硬约束（见 docs/board_status.md）。**

**第二十轮上板反馈（2026-10-05）**：①PC 流帧干净 → **写通路板上实锤正确**，
撕裂隔离到显存读出/显示侧（仿真盲区），且错位位置每次不同=动态性，指向
SDRAM 读/控制器（官方 IP −6.7ns 违例是头号嫌疑）或视频读引擎。②'L' 以太网
怪相（1 条转储+11 条相同 ACK）根因：pl_pkt_val 是 1 拍脉冲，eth toggle 跨域
同步晚 ~3 拍才锁存 tx_pkt→锁到 ACK 兜底包；修=top 用 eth_tx_pkt_r 与 toggle
同拍锁存保持；另把转储首包与命令 ACK 拉开 400µs（防 toggle 粘连假边沿）。
回归 433/433 全绿。③首帧 Web 无图：boot 装载早于控制台连接，UDP 丢包所致，
N/P 重装载即可捕获（非缺陷）。④下一步撕裂取证=读侧 dump（显存读回经以太网
比对：读回干净→video/HDMI 通路；读回也花→SDRAM 读/控制器）；零成本前置=
撕裂时读 S 状态包 underrun 位。

## 2026-10-05 第二十一轮：读侧 dump（三分法最后一块）

**背景**：上板实证写侧流帧干净（写通路正确），撕裂在读侧且动态变化。
读侧 dump = 显存线性读回经以太网比对：读回花 → SDRAM 读/控制器（官方 IP
−6.7ns 违例头号嫌疑）；读回净而屏显花 → video_delay/HDMI 读通路。

**实现**：
- ctrl_core：'D'（0x44）→ rdump_start；'L' 以太网怪相已修（eth_tx_pkt_r 与
  toggle 同拍锁存保持 + 转储首包拉开 400µs）——pl_pkt_val 1 拍脉冲 vs 跨域
  同步晚 3 拍的通用教训：**跨域发送的数据必须与 toggle 同拍锁存保持**。
- sd_card_bmp：dump FSM 借音频读通道（rd_req/rd_en mux，dump 期间屏蔽播放
  refill，停播自愈看门狗恢复）；泵字由 aud FIFO 水位门控（frame_read_write
  新增 aud_rd_usedw 出口）；线性读 disp_buf_idx 缓冲 460800 字 → tap2 出口。
- 触发：装载提交自动（仅无配对音频的图——配对图立刻开播，借道会出杂音）
  + 'D' 手动（随时，含同一静止缓冲反复取 = 动态性实锤实验）。
- eth_front：双流 FIFO（写侧 0x0003 / 读回 0x0004 各一条，各自独立 seq 与
  收口归零）——来源零歧义，避免跨域类型标记。BRAM 总占用 +2×9k。
- PC：/api/frame?slot=rb；前端第二画布（读回正立直接渲染，无需 vflip）+
  BMP 对照 diff 独立跑双帧。判读口径：写侧净+读回花→SDRAM；双净+屏花→显示。
- tb_ethfront T16/T17（读回源独立 FIFO/seq、双源互不串扰），17/17 全绿。

**终版设计更正（同日）**：借道音频读通道的 dump FSM 在仿真里被否——C++ 读
模型单会话语义下 dump 与播放互踩（12 个音频用例假失败），真机上也会打劫
播放（看门狗降级静音）。**终版 = video 域一帧捕获窗**：dmp_trig（'D' 或装载
提交自动，两提交点都发）→ toggle 跨域 → vsync 开窗圈取一整帧
video_read_en/data（显示读通路本身的出口）→ tap2（独立 tap2_clk=video_clk
域 Gray FIFO，type=0x0004，独立 seq）→ 与写侧同一条 TX FSM。零额外 SDRAM
流量、不碰读引擎会话、不碰音频通道，放音乐也能自动抓。判读不变：捕获帧花
而写侧净→SDRAM 读/控制器；双净而屏花→video_delay/HDMI。附带收益：配对图
也有自动捕获。tb_ethfront T16/T17 双源用例 17/17；回归 433/433 全绿。
**教训：C++ 模型顶替的模块其接口语义（单会话请求/握手）必须先弄清再复用；
跨源流通道用"每源一条 FIFO+固定 type"比"共享 FIFO+类型标记"少一类 CDC 歧义。**

## 2026-10-05 第二十二轮：读侧 dump 调试进行中（交接：下一模型从这里接手）

**已上板验证的结论（不要重做）**：
- 写侧流帧：板上整帧 460800/460801 字到达 PC，画面干净 → **解码→打包→SDRAM
  写通路逐字节正确**。撕裂隔离在读侧，且每次错位位置不同（动态性）。
- 'L' 以太网：已修好（eth_tx_pkt_r 与 toggle 同拍锁存保持；跨域发送的数据必须
  与 toggle 同拍锁存——tx_req/tx_pkt 是 1 拍脉冲，同步晚 3 拍就锁到兜底包）。
- 'D' 命令链路：ACK 正常回；读回捕获窗、双流 FIFO、3:1 抽字、攒包发包链
  **RTL 侧算术已验证正确**：PC 收到的 29 字尾包 = 153600 − 607×253，恰好是
  1/3 整帧（153600 字 = 460800/3）分 607 个满包后的余数。

**唯一未定问题：读回帧到 PC 只剩 29 字**。两种假设，一次抓包定案：
- H1 PC 丢包：Windows UDP 内核接收缓冲 64KB 硬上限（SO_RCVBUF 被钳制，实测
  无效），31MB/s 突发持续 16.7ms，线程调度/GIL 停顿 >1.7ms 即丢。已上缓解：
  sys.setswitchinterval(0.0005) + recv_into 热路径 + 孤儿尾包防污染。
  **决定性测试：Wireshark 抓 udp.port==2，按一次 D，数 type=0x0004 的包**：
  见 ~607 个 → PC 栈丢包（试 WSL/Linux 收包端，或原生接收器）；只见 1 个 → H2。
- H2 RTL 每窗只写出 ~29 字：105（未抽字）→ 29（1/3 抽字）≈ 87 原始字，两代
  bit 一致——**捕获窗内 video_read_en 只见到 ~100 个脉冲**。若 H2 实锤，查：
  ① cap_win 是否真开满一帧（vs_rise_v 是否每帧只一拍；vs_0 形态用 ILA/引脚
  引出）；② video_read_en 的真实占空（video_delay 驱动的 pop 波形）；③
  fifo2_full 是否中途卡死（FIFO B 写侧 video_clk 75M / 读侧 udp_clk 125M）。
  建议加 4 个粘滞计数器（tap2 写入数 / fifo2 丢弃数 / B 包数 / B 发送字数）
  走状态包或新调试命令读出，一次上板分清。
- 注意 H1 与「缺口 0」矛盾（若真丢 606 个，缺口应显示 606）——H2 权重更高，
  但 29 字恰好等于尾包余数又指向 RTL 已发满——**先抓包再动 RTL**。

**工作区未提交改动（用户要求：验证过才提交）**：
- eth_front：tap2_clk（video_clk 域写侧）+ 3:1 抽字 thin_cnt；双流 FIFO
  （0x0003 写侧 / 0x0004 读回，独立 seq 与收口归零）。
- eth_subsys：tap2_clk 穿透（2440369 已提交，其余未提交）。
- top：video 域一帧捕获窗（dmp_trig→toggle→vsync 开窗→tap2）+ display_valid
  门控（消启动期垃圾捕获）。
- sd_card_bmp/frame_read_write：音频借道方案已回退，sd_card_bmp 只剩 dmp_auto_r
  （两提交点置位）+ dmp_trig 输出。
- ctrl_core：'D'(0x44)→rdump_start。
- web_console：'D' 按键、双帧槽(wr/rb)、3:1 抽字渲染与 diff（含覆盖率显示）、
  SO_RCVBUF/setswitchinterval/recv_into 热路径/孤儿尾包防污染、init 启动块修复
  （曾被拼接吞掉致整页控件消失）。
- tb_ethfront 17/17（T16/T17 双源+抽字）；回归 433/433（捕获窗在 video 域，
  仿真盲区，与视频通路一样属 boardtest 已知盲区）。

**撕裂主线状态**：写侧干净 → 等读侧 dump 通了做最终三分。若 dump 证实 SDRAM
读也干净，撕裂在 video_delay/HDMI——注意用户屏显「动态错位」与 underrun 位
干净并存，官方 SDRAM IP −6.7ns 违例仍是读数据损坏的头号嫌疑。

## 2026-10-05 第二十三轮：读回工具代码级复盘与修正（待重新综合上板）

- **29 字并非 H1/H2 二选一的证据**：`eth_front` 发送读回包时递增 `seq2`，
  但组包头误用写侧 `seq`。写侧收口后它恒为 0，PC 每收到一包都按新会话清空，
  故最后只剩整帧抽样后的 29 字尾包、缺口也为 0。已改为按来源选 `seq2/seq`；
  `tb_ethfront` 新增两满包+尾包及下一会话检查，19/19 全过。
- **读回像素对齐**：真实 `rfifo_32_32_512` 的 `dout` 在 `read_en` 之后更新；
  top 的 `tap2_val` 延迟一拍，使写入抓取 FIFO 的字与有效脉冲同拍。`cap_tog`
  增加复位；`thin_cnt` 在 `tap2_end` 清零，保证每会话抽样相位从 0 开始。
- **PC 3:1 映射**：读回第 j 字对应完整显存字 `3j`，网页现在按此散点渲染，
  diff 只比较抽到的像素；后端保留不满行的读回尾字并返回 stride=3。
  若有 seq 缺口，本帧不做像素比较，避免后续字错位给出假结论。
- **HDMI AXI 行末**：旧适配器仍按 640 宽发 `TLAST`（且偏晚一像素），现按
  1280 宽在第 1280 个有效像素发出。新增 `boardtest axis` 定向仿真通过。
- **证据边界修正**：写侧探针在 SDRAM 写 FIFO 之前；它证明 BMP 解码/打包
  输出干净，不能证明显存写入干净。最新 TD 报告的 `ext_mem_clk` 域内最差
  +0.747ns；全局 −7.785ns 来自 `sd_card_clk → ext_mem_clk` 的信箱行偏移
  配置路径，不能直接解释为逐字写地址失约束。
- 验证：`boardtest ethfront` 19/19、`boardtest axis`、PC 端完整抽样帧渲染/BMP
  对照测试、Python 帧 API 测试均通过。**仍待 TD 综合与上板**：读回应收
  153600 抽样字（608 包：607 满包+29 字尾包），缺口应为 0；再用相同 BMP
  对比读回散点，结合屏显和 `S` 状态包判断写入/读出/HDMI 哪一级出错。

## 2026-10-05 第二十四轮：真板 IMG4 读回与时序复盘（根因尚未定案）

- 从真卡只读镜像提取 IMG4.BMP（571×720），与 PC `18:58:42` 捕获的写侧
  460800 字按 RGB565/水平黑边逐字比对：**460800/460800 完全一致**。
  此探针位于 frame_read_write 写 FIFO 之前，故不能据此证明 SDRAM 写入正确。
- 读回为 153600 抽样字、seq 缺口 0。IMG4 图像区域的 68640 个抽样字中，
  68359 个（99.59%）能在原帧的“预期地址 +1 字”或“+5 字”位置找到
  **完全相同的 32 位字**；只有 281 个两者都不匹配。主要是稳定的字序/地址
  错位，不是随机 RGB 位翻转。连续两次手动 D 的 614400 字节读回完全相同；
  与较早一帧仅差 29 字。经 N→P 重新装载 IMG4 后，写侧仍逐字相同，读回
  与装载前仅 77/153600 字不同。`S` 状态包显示“异常: 无”。
- `tb_ethfront` 已改为独立约 75MHz 读回源时钟，并逐字校验两个 253 字满包；
  **19/19 全绿**，仿真内网络 FIFO/组包未复现 +1/+5。新增 `framepath`
  集成自检用工程真实异步 FIFO、100/125/75MHz 三时钟、简化 SDRAM 口，
  用板上同款 256 字突发连续测 1024 字写入/读出均准确；厂商加密 SDRAM IP
  与板上布线仍在仿真边界外。
  该自检还揭示：真实写 FIFO 是 show-ahead，同拍 `App_wr_en/addr/din` 在模型中
  正确；原 `tb_readeng` 写 FIFO 桩按数据晚一拍建模，不能用它证明真实口时序。
- **时序报告不能把两条负路径混为一谈**：已上板正常的 720p 提交 `357bb16`
  的 `SDRAM DQ → ext_mem_clk` 路径 WNS 为 −6.565ns；`main`、当前报告均为
  −6.699ns，数据路径延迟恒 6.453ns（100% cell、0% net），没有因多分辨率
  变成 −8ns。该路径起点是 SDRAM hard IP 的 DQ，终点是读数据 PAD 寄存器，
  报告的半周期预算 4ns、推算 Fmax 46.733MHz；改到 100MHz 只把预算加到
  约 5ns，**不会让 STA 数字自动转正**。全局 WNS 变成约 −8ns 的新路径是
  `sd_card_clk → ext_mem_clk`：
  `img_h_l` → 信箱行偏移组合计算 → `App_wr_addr_r`；这是会话首地址配置路径，
  IMG4 高度 720 时偏移为 0，音频写通道也不使用 vflip，不能直接解释每几个字
  交替出现的 +1/+5 错位和音频杂音。当前 `ext_mem_clk` 域内 WNS +0.240ns。
- **下步判别**：需在真实 SDRAM IP 两侧取证，至少确认 `App_wr_en/addr/din`
  写口是否顺序正确，以及 `Sdr_rd_en/dout` 返回时的字序。若选择试降频，需在
  TD 中重生成 sys_pll 的 clk1/clk2 并保持合适移相关系，保存现有 bit 作 A/B；
  从 125→100MHz 只增加半周期预算约 1ns，不能把报告中的 −6.699ns 自动
  变成收敛，因此上板读回改善与否才是判据。暂不凭该负数单独断定 IP 故障。

**125→100MHz 受控 A/B（2026-10-05，等待 TD/上板）**：原 125MHz 的
`sys_pll.ipc/.v/.vhd`、bit 与 timing report 已复制到 git 忽略的
`img/golden/clock125/`，含 SHA-256 清单。TD 里只重生成 `sys_pll`：C0 保持
100MHz/0°、C1=100MHz/0°、C2=100MHz/180°；video_pll 与其它 RTL 不动。
用相同 IMG4 再取 wr/rb，可运行
`python scripts/analyze_frame_dump.py --bmp img/golden/IMG4.BMP --url http://127.0.0.1:5000 --save-dir img/golden`
输出写侧精确字数、读回正确地址计数与 +1/+5 偏移计数。125MHz 对照值：
wr 精确 460800/460800；rb 图像区地址正确 14484/68640；+1/+5 合计
68358/68640；重新装载后相对前帧仅 77/153600 字变化。保存原始抓帧后再判读。
TD 6.2 重生成 `sys_pll.v` 会删掉封装层手工接出的 `extlock` 端口，导致 top
例化报 cannot find port；本轮已在 100MHz 生成文件中恢复端口声明及
`.extlock(extlock)` 连接。今后每次重新生成该 IP 后要复查此端口。

**100MHz 上板 A/B 已完成（同日）**：新 bit `20:13:23`，报告显示 ext_mem_clk
域内 WNS +2.432ns、信箱偏移跨域 −0.044ns、原 SDRAM DQ 路径 −5.699ns。
IMG1（配 WAV）写侧 460800/460800 全对，读回主要为原地址/+4 字；用户听感
音频杂音与 125MHz 差不多。随后同一 IMG4 比较：写侧仍 460800/460800
全对，读回图像区原地址仅 11201/68640，主偏移为 +2/+6 字（125MHz 为
+1/+5）。静止重抓仅 31/153600 字变化；用户反馈 IMG4 屏显也差不多。
**结论**：降到 100MHz 未治愈主错位，频率变化使整体偏移改变一字，
相隔四字的规律仍在；不能仅凭旧 −6.7ns 路径断定随机采样错误。

**下一版诊断改动（待 TD 综合上板）**：`top_tf_hdmi_audio.v` 的
`DUMP_AT_SDRAM_OUTPUT=1` 把原 type 0x0004 / 3:1 读回流临时切到
`Sdr_rd_en/Sdr_rd_dout`（与视频读 FIFO 写入口同拍），`mem_return_dump`
在下一视频读会话 ACK 后计 460800 个视频返回字、过滤音频字；不足整帧时
下次 ACK 冲洗。原 video FIFO 出口捕获逻辑保留，参数设回 0 即可切回。
`make -C boardtest memdump` 定向仿真通过。若新抓取点仍有 +2/+6，问题
在该入口之前（写 FIFO/引擎、SDRAM IP/阵列、读请求/返回）；若该点干净而
旧出口坏，则在视频读 FIFO/消费侧。另修复 boot 看门狗比较常量
`27'd250_000_000` 越过 27 位而被截断，改为 28 位以实现标注的 5 秒。

**SDRAM 返回口板级结论（同日 20:48 bit）**：IMG4 写侧旧探针仍与原图
460800/460800 字一致。新的 type 0x0004 在 `Sdr_rd_en/dout` 与视频读 FIFO
写入口同拍抓取，图像区 68356/68640 抽样字仍位于原图 +2/+6 字偏移；
与上一 bit 的 FIFO 出口抓帧相比，图像区只差 485/68640 字。重复 D 仅差
31/153600 字。主错位已在视频读 FIFO **之前**，不能靠改 video_delay/网页
或 FIFO 消费拍序修复。此边界仍包括写 FIFO/引擎、SDRAM IP/阵列及读请求。

**下一版写入口双流探针（待 TD 综合上板）**：`DUMP_WRITE_PORT=1` 时，图像
写会话的 type 0x0003 改为与 SDRAM IP 同拍的 `App_wr_din` 全量数据，
type 0x0004 改为每三字抽一个 `App_wr_addr`。触发来自原图像发射首字、
结束来自 LD_STREAM 的 `tap_end`，避开前置全帧涂黑；两路同时取样，
不增加 SDRAM 访问，也不更改功能写口。`boardtest writeprobe` 和
`ethfront` T20（双流并发）通过，ethfront 总计 20/20。
本版无需按 D；切到 IMG4 或 N/P 重新装载后，运行
`python scripts/analyze_frame_dump.py --bmp img/golden/IMG4.BMP --url http://127.0.0.1:5000 --save-dir img/golden/writeport --write-port-addresses`。
应得 type3 数据 460800/460800 精确、type4 地址 153600/153600 精确，
否则分别定位数据或地址在 IP 入口前已错。此诊断版网页的“读回画布”收到
的是地址字，不可按颜色图像解释；直接用分析器读原始帧。

**写入口真板结果（同日 21:12 bit）**：IMG1 的 type3 全量
`App_wr_din` 前 460800/460800 字与 BMP 完全相同，type4 的
`App_wr_addr` 抽样 153600/153600 地址与 vflip 预期完全相同。
IMG4 的抽样地址也 153600/153600 全对，但 type3 全量数据探针只收
455747 字，P→N 重装后收 457012 字，seq 缺口仍 0：图像黑边补字使写口
突发密集，**探针自己的 A FIFO 丢字**，网页的黑横条是观测流重组错位，
不能视为 IP 输入的数据错误。B 地址流未丢；末尾多一次 App_wr_en，
抽样到越界地址 0x1FFD80（BUF3 最后 640 字区域），此处应后续修复，
但不解释整帧稳定 +2/+6 错位。

**下一版读请求地址诊断（待 TD 综合上板）**：`DUMP_WRITE_PORT=0`，
`DUMP_READ_REQUEST_ADDR=1`，D 触发后 type4 每三字抽一个
`App_rd_en/App_rd_addr` 的请求地址，原 type3 恢复图像发射探针。
`mem_return_dump` 的会话窗复用，功能读请求本身不变。运行
`python scripts/analyze_frame_dump.py --bmp img/golden/IMG4.BMP --url http://127.0.0.1:5000 --save-dir img/golden/readaddr --read-port-addresses`
（此时 type4 是地址，网页读回画布不可按像素解读）。若所有 153600 地址
为显示缓冲基址+3j，而此前同图的 `Sdr_rd_dout` 仍 +2/+6，边界就落在
厂商 SDRAM 控制器/物理阵列内部；若请求地址已错，查 frame_fifo_read RTL
或 TD 时序。IMG1 有配对 WAV，用户反馈 100MHz 下杂音差不多。

**读请求地址真板结果（同日 21:44 bit）与首个确定 RTL 修复**：IMG1 的
写侧原预览恢复并与 BMP 460800/460800 字一致；D 的 `App_rd_addr`
抽样 153600/153600 地址均为正确的显示缓冲基址+3j，故读请求逻辑也
不能解释先前 `Sdr_rd_dout` 的 0/+4（IMG1）与 +2/+6（IMG4）错位。
写入口探针曾见每 460800 字会话实际发 **460801 次 App_wr_en**，
末字地址 0x1FFD80（BUF3 尾部）。`boardtest framepath` 用真实 show-ahead
写 FIFO、256 字突发复现：请求长度 1024，旧 RTL 发 1025 次、末地址 1024。
根因在 `frame_fifo_write.v` 的下一拍允许条件仅比较旧 `write_cnt` /
`burst_cnt`，未把本拍已经发出的 `App_wr_en` 计入。条件改为
`write_cnt + App_wr_en < write_len_latch` 且
`burst_cnt + App_wr_en < BURST_SIZE` 后，集成仿真精确发 1024 次、
末地址 1023、1024 字内容全对；`boardtest readeng` 稀疏尾部自检全绿。
**待真板验证是否也消除图像 +2/+6 和音频杂音**：下一 bit 的
`DUMP_READ_REQUEST_ADDR=0` 恢复 D 抓 `Sdr_rd_dout`，type3 写侧预览
继续保留原始全帧。此版是有仿真复现的功能修复，不再只切诊断位置。

**写使能修复后的板级反馈（同日 22:06 bit，里程碑）**：用户观察屏显瞬间
修复大半，IMG5 配对 WAV 的杂音基本消失。IMG4 type3 正式写侧预览仍与
真卡 BMP 460800/460800 字一致。type4 控制器返回流图像区域原先交替的
+2/+6 两支中，**+6 支基本消失**，68615/68640 抽样字现在恰对应原图
+2 字位置。静止 IMG4 再按 D，614400 字节读回与首次完全相同；残余
近乎固定的 +2 字偏移仍待定位。`S` 状态包有 audUND 粘滞位，应结合
重启后再看，不能把历史粘滞当成当前持续欠载。此提交只宣称重大改善，
不宣称图像/音频最终全无瑕疵。

## 2026-10-06 多分辨率修复收口

本节之前是按日期写下的排查流水，保留当时的错误假设与未完成判断；**当前结论以
[`multires_fix_postmortem.md`](multires_fix_postmortem.md) 为准**。最终板上 IMG4 的
153600/153600 个读回抽样字全帧吻合（含左右黑边）；IMG5 重装后亦为
153600/153600，首次曾有一个非白色单字差异。用户确认 HDMI/PC 白条消失。

最终源码保留图像 ACK 后 16 拍等待、写引擎当前读忙复查、整帧填黑每 16 拍一字、
图像左右黑色 padding 每 4 拍一像素；撤回无效的填黑 ACK 等待和 128 字写突发。
IMG5 配对 WAV 杂音在写口末字越界修复后由用户反馈为基本消失，未做新的模拟音频测量。

后续若由稳定提交引入新功能后出现故障，**先 diff 稳定版与当前源码、审查新增路径的
行为逻辑和探针覆盖，再扩大到时序/IP 假设**。当前 D 读回仍只覆盖约 1/3 显存字，
最终 STA 仍有既存负 WNS；两者作为后续独立工作，不把功能通过写成时序收敛。
