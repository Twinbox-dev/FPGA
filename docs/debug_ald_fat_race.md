# 板级音频刺耳根因 #3：ald file_req 与图像流尾竞争（2026-09-27 定）

> 症状：切图后播放的是**上一个残留**在 BUF2/BUF3 里的音频（诊断卡表现为
> 播 TST4 直流/旧音频），boot 首图装载永远正确。
> 该 bug 与 `timing_report_howto.md` 里的时序问题是**独立的两类病**：
> 时序违例是"板上随机错"，这个是"逻辑必然错、只是以前测不出来"。

## 根因

切图装载的完成判定是 `img_ok && write_done_seen`（像素流尽 + 写口 finish），
但 **fat32_ro 读文件扇区还没收尾**——最后几个扇区的 SPI 传输仍在进行，
fat32 尚未回到 `S_MOUNTED`（`o_file_idle=0`）。

此时外控块触发 ald（音频装载子相位）：

1. `ald_start_pulse` 正常被打包器/wav_reader 消费（pstate 0→1）；
2. 但 ld FSM 下一拍发 `file_req` **一拍脉冲**，fat32 不在 `S_MOUNTED` 直接**丢弃**；
3. WAV 根本没被请求 → `w_hdr_ok` 永不置位 → 写通道不开 → BUF2/BUF3 原样保留；
4. ~15k 周期后**图像文件**的 `file_done` 到达，而 `aud_eof_seen` 的锁存条件
   只查 `(aud_item_active || ald_active)`——`ald_active=1`，图的 eof 被**误算到
   ald 头上**；
5. `aud_item_close = eof && !aud_wr_active`（从没写过）立即成立 →
   **ald 空提交**：`cmt_len` 用的是扫描期记录的 `wav_len_rec`（长度正确！），
   播放端拿着正确长度去读**残留内容**。

## 判别特征（以后一眼认出来）

- 提交后播放缓冲内容 = 该缓冲**上一次**被写的内容（扫描期最后一个 WAV / boot 音频）；
- 探针：`ald` 期间 pstate 走 `0→1→0`（不进 `1→2`，即 `w_hdr_ok` 没来过），
  无音频写通道 WR_OPEN，FAT 无 `8→10`（S_MOUNTED→S_OPEN）迁移。

## 修复（sd_card_bmp.v，board_display/ 与 boardtest/vsrc/ 同步）

1. **ald 触发加 `fat_idle`**：`img_ok && write_done_seen && fat_idle`——
   等 fat32 读完图文件尾、回到 MOUNTED 再踢 ald。kick 之后到 WAV 流完之间
   不存在别的 `file_done`，eof 归属必然正确。boot ald 路径本来就有 `fat_idle`。
2. **LD_FILE 保持-等待**：`if (fat_idle)` 才发 `file_req`，否则留在 LD_FILE。
   fat32 只在 MOUNTED 收请求（电平采样，1 拍脉冲忙时即丢），保持等待根治同类竞争。

## 为什么逃过了此前所有测试

- 竞争窗口 = 像素流尽先到 vs fat32 扇区尾先到，**取决于卡的簇布局/文件大小**，
  以前四种卡恰好都是 fat32 先收完；
- 用户卡所有图配**同一个** 0.WAV，缓冲装没装对内容完全听不出来
  （SD/SE 通过纯属巧合：BUF2 扫描残留的就是 0.WAV）；
- 第一个能暴露它的测试是诊断卡（4 个不同 WAV 配 4 张图）。

**教训**：乒乓缓冲 + "内容随机凑巧相同"会让整类 bug 隐形。验证集必须让
每个缓冲装载**可区分内容**（判别式诊断卡由此而来，见
`../Desktop/diag_audio`，脚本 `scripts/gen_diag_card.sh` 生成仿真短音版）。
