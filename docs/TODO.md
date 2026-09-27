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
