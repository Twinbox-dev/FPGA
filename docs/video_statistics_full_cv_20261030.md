# 视频诊断统计显式裁剪与 Sobel/锐化恢复

## 基线和目的

从 `feature/direct-video-playback@d28c27f` 开发。目标是评估 `DIRECT_VIDEO_STATUS=0` 时上游统计是否仍占资源，并恢复此前关闭的 Sobel/锐化。媒体板不改，显示板保留完整频谱 DFT；不引入 stash 中的频谱下放实验。用户已自行测试确认无问题，并授权本轮提交。

## 对资源估计的核对

提出的方案认为 TD 未跨模块删除统计，可回收 800–1,100 LUT。先仅添加统计开关、保持邻域 CV 关闭，冻结同设置版本单独综合，结果：

| 综合指标 | d28c27f | 仅显式关闭统计 | 关闭统计并恢复六种 CV |
| --- | ---: | ---: | ---: |
| LUT | 15,747 | 15,706 | 16,202 |
| FF | 11,905 | 11,905 | 12,131 |
| BRAM9K | 51 | 51 | 51 |
| BRAM32K | 8 | 8 | 11 |
| DSP | 16 | 16 | 16 |

仅统计候选少 41 LUT，FF 不变。细看层次：head 仍为 246 SEQ、audio 269 SEQ、parser 202 SEQ、ingress 90 SEQ，关闭前后相同。主要诊断计数与读回 CRC 链在本工具/产品配置下原本已经被删除，不能声称释放了 800–1,100 LUT。41 LUT 是整机映射差额，不是上千个诊断寄存器被移除的证据。

显式开关仍有用途：固定诊断硬件边界，避免未来端口连接变化时被意外保留。完整 CV 恢复会增加资源，不能把它与统计开关的单项测量混为一谈。

## 开关覆盖与保持的正确性通路

为 `video_hybrid_pipeline`、`video_head_cache`、`video_row_ingress`、`direct_video_row_parser`、`direct_video_audio` 增加/传递 `STATUS_ENABLED`，顶层使用 `DIRECT_VIDEO_STATUS`。模块默认启用统计，保持既有历史测试/诊断行为；产品顶层关闭。

- 关闭 head 的被动读回 CRC、好/坏计数及只为诊断服务的 CRC 表。
- 关闭 hybrid 的 spills/prefetches/fasts/错误计数、统计 Gray 编解码/同步和输出寄存器更新。
- 关闭音频的播放后 CRC 统计及其表、计数/CDC；parser 与 ingress 的诊断接收计数也关闭。关闭时相关诊断输出为零。
- 保留音视频接收 CRC、SDRAM 返回像素 CRC、完整行发布、坏包拒绝、欠载静音/缺行标志。
- 保留 READY、NACK、绝对 CREDIT 及其 consumed sequence Gray CDC。它们不是统计。
- 保留音频 played frame Gray CDC，因为它参与 slot 准入，不是计数显示。

`direct_video_feedback_tx` 并非只发送 WATERMARK：产品仍发 READY/CREDIT/NACK 和紧凑健康标志；关闭的是可选统计包。

## 恢复的功能

顶层 `PRODUCT_CV_NEIGHBORHOOD_ENABLED=1`，PC `direct_video_profile.json` 的 `cv_neighborhood_enabled=true`，让 App 再次开放 Sobel 梯度和锐化。原图、灰度、二值化、雪花、频谱、字幕/OSD、GT911、多窗口、转场、PC 图传与 2×全屏视频保留。视频播放时仍强制原图路径，停止后恢复原设置。

## 仿真

保留原测试，新增/扩展：

- `video-status-equivalence`：同一生产与读取刺激并行驱动统计开/关两套流水线；比较实际 SDRAM 命令/地址/写数据、HDMI 数据/有效、READY/NACK/CREDIT 与身份字段，覆盖三时钟域、行序号回环及启动缺行 NACK 补齐。
- `audio-status-equivalence`：统计开/关逐拍比较 PCM、有效和 missing 标志，覆盖 CRC 错包静音、缺块、帧号回环、会话重启和四个 RAM slot。
- 视频 parser 原测试增加统计关闭副本，逐拍比较元数据/像素、CRC 结果与 commit/reject；诊断计数应为零。
- `cv-capability-full` 确认 Sobel/锐化控制被接受；`cv-unit` 覆盖固定效果、运行时切换、帧边界锁存与同步。
- `video-fullscreen-chain` 通过实际解包与 CV 延迟链逐像素检查三帧 1280×720 输出。
- 视频 CRC/元数据错误、音频和包解析既有回归通过。

## 构建与验收

仅统计测量冻结于 `boardtest/captures/resource_experiments/video_stats_off_20261030/`；完整功能版本冻结于 `video_full_cv_stats_20261030/`。完整版本综合约 2m10s，布局布线约 5m39s；成功生成 bit。

| 布线后指标 | d28c27f（Sobel/锐化关闭） | 本轮完整 CV | 变化 |
| --- | ---: | ---: | ---: |
| LUT / 19,600 | 16,625 | 17,068 | +443 |
| FF | 11,894 | 12,127 | +233 |
| slices / 9,800 | 8,958 | 9,168 | +210 |
| BRAM9K / BRAM32K | 51 / 8 | 51 / 11 | 0 / +3 |
| DSP / PLL | 16 / 4 | 16 / 4 | 不变 |
| Setup / Hold WNS | −5.699 / −3.056 ns | −5.699 / −3.008 ns | setup 不变、hold 改善 0.048 ns |

当前超过 17,000 LUT 68 个，功能已恢复但不能写成达到低于 17K 的目标；负时序裕量仍存在。媒体板保持 14,061 LUT。

使用 `program_sram.ps1` 成功写入两板 SRAM：显示板日志为 `boardtest/captures/sram_download/program_display_20261030_173216.log`，媒体板为 `program_media_20261030_173223.log`。新 App 已读取完整能力 profile，Sobel 与锐化收到实际应用 ACK（`CV=sobel`、`CV=sharpen`）。实际回归还覆盖 SD 六图、三种布局/转场、轮播返回单图、字幕/设置、PC 图传及 D 源图 golden（460,800 字、缺口零，与 IMG2.BMP 一致）。D 不是显示侧 CV 像素读回。原始记录为 `boardtest/captures/video_full_cv_live_result_20261030.json`。

Web 的 18 项软件测试在普通用户非沙箱环境全部通过，含真实 FFmpeg 和本机 UDP 回环。沙箱首次运行时该回环用例未得到反馈、超时；不将其记为产品修复。本轮没有重复上一版本的三布局视频长跑，视频及 CV 的实际观感由用户自行验收；不把旧版本的自动发送统计冒充本版本结果。

板测期间用户同时测试串口，曾出现索引读数疑问；按用户要求暂停后，其自行完成测试并确认无问题。期间额外尝试的窗口元数据写入改动未烧录，已在提交前恢复为实际验收源码。本版不声称修复新的窗口索引 bug。

验收后已将实际烧录的同一个 bit、综合/布线报告、运行日志及真实工程配置同步至正式 TD 输出和 `best_result`，重新发布 `video_build_manifest.json`。已逐项核对冻结输入与提交源码一致；媒体板正式构建不变。提交可直接恢复配套 bit，不依赖忽略的 captures 目录。

## 文档整理

本轮保留独有技术内容：三份资源阶段记录合并为 [资源优化历史](resource_optimization_history.md)，两份视频接入记录合并为 [视频接入历史](history/video_integration_20261027_28.md)。早期单板架构、设计及开发日志移至 `docs/history/`，并修正相对导航链接。README、当前架构、控制台和 CV/资源入口按实际功能更新，避免把双线性、静音多窗口、左上原尺寸视频或暂关 CV 当作当前状态。未删除历史仿真、故障证据或仍有独立用途的专题文档。
