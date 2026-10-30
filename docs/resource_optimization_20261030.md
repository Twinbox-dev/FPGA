# 显示板资源优化：最近邻缩小（2026-10-30 已验收）

## 基线与范围

基线为 `feature/direct-video-playback@d281ca0`。频谱下放与 CV 实验保存在 stash，未带入本候选；媒体板不修改。当前产品仍关闭 Sobel/锐化，其他开关保持 d281ca0，不能把本轮数字表述为六种 CV 全开的资源。

用户允许牺牲画质及未来可拓展性来节省资源。本候选将图片多窗口缩小从双线性改为中心对齐最近邻。图片比例并非都为整数：例如 640×480 在四宫格内是 480×360，571×720 是 285×360。因此保留任意合法尺寸的等比例适配，不把实现限制为隔一取一。

## 实现与画质取舍

`view_nearest_shrink` 对每个目标像素采样：

```
sx = floor((2*dx+1)*source_width /(2*dest_width))
sy = floor((2*dy+1)*source_height/(2*dest_height))
```

硬件通过两个 12-bit 整数相位累加器在原始 bottom-up 输入中选点，不逐像素相除。删除生产缩小路径的两行 RGB565 缓存、插值乘法器及插值中间寄存器，不增加输出行缓存。缩小目标尺寸、居中黑边、不放大、RGB565 打包、音频旁路和板间协议保持现有规则。奇数像素的输出尾字高半字补零；提前结束输入时剩余输入像素按零处理。

画质代价是细线、纹理可能出现锯齿和摩尔纹；不进行低通抗混叠。历史双线性模块和仿真保留，旧 pipeline 仿真改用 `boardtest/diagnostics/bilinear_reference/view_image_pipeline.v`，防止历史 golden 被悄悄改成最近邻。

`view_scale_geometry` 新增编译期 `COORDINATES_ENABLED`；生产最近邻只使用尺寸，不生成 Q16 插值坐标。默认值仍服务既有双线性历史测试，生产常量关闭后综合剪除对应逻辑。

## 资源与时序

同一 d281ca0 工程设置，在独立冻结目录完成整机综合和布局布线：

| 指标 | d281ca0 | 最近邻候选 | 变化 |
| --- | ---: | ---: | ---: |
| 综合 LUT（含 ripple） | 16,544 | 16,014 | −530 |
| 综合 FF | 12,341 | 12,033 | −308 |
| 布线后 LUT | 17,501 | 16,947 | −554 |
| 布线后 FF | 12,329 | 12,017 | −312 |
| slices / 9,800 | 9,304 | 9,045 | −259 |
| BRAM9K | 49 | 49 | 0 |
| BRAM32K | 10 | 8 | −2 |
| DSP | 18 | 16 | −2 |
| Setup WNS | −5.699 ns | −6.268 ns | 恶化 0.569 ns |
| Hold WNS | −3.068 ns | −3.042 ns | 改善 0.026 ns |

布局布线与 bitgen 完成不等于时序收敛。当前 setup 仍为负且恶化 0.569 ns，不能声称静态时序通过。候选已完成下述自动板测，用户随后反馈“测试没问题”并授权提交。综合约 2m18s，物理流程约 4m12s。

冻结目录（忽略的实验输出，不是提交中的正式产物）：

`boardtest/captures/resource_experiments/nearest_20261030/`

其中 `manifest.json` 记录输入源码和配置；`board_display/user_source/` 是生成候选的实际源码；配套 bit 是：

`board_display/td_project/lab_ex5_i2s_v1.0_Runs/phy_1/lab_ex5_i2s_v1.0.bit`

该 bit 路径相对于上述冻结目录。用户验收后，已将同一个 bit、综合/布线报告、运行日志及实际使用的 `.prj/settings.cfg` 同步至正式 `board_display/td_project/*_Runs`；`best_result` 的 bit/布线摘要同步更新。正式 `video_build_manifest.json` 已按冻结输入重新发布，核对所有冻结源码及工程配置与提交文件逐字节一致。因此回溯本次提交无需依赖忽略的 captures 目录。媒体板继续使用提交中 d281ca0 配套的正式 bit 和报告。

## 已执行仿真

WSL Verilator 执行：

```
make -C boardtest view-nearest view-nearest-pipeline view-geometry
make -C boardtest view-bilinear view-image-pipeline view-control-path view-framepath
```

全部通过。新缩小器和实际补黑 pipeline 各有 14 组逐像素 golden：单图原尺寸、双图、四图、非整数比例、奇数宽高、单像素、零输入和提前截断，连续帧无中间复位，源/目的有背压。几何测试 73 组；历史双线性及补黑回归、窗口控制和真实异步 FIFO/排空屏障仿真亦通过。上述证据不代替 HDMI 画质、触摸或视频实板验收。

## 自动板测（2026-10-30）

用户给两板上电后，核对冻结目录全部 manifest 输入及工作区源码，核对媒体板正式 bit 与其 manifest 一致。通过现有 `scripts/program_sram.ps1` 普通用户 CLI 将最近邻候选下载至 cable0，将 d281ca0 媒体板正式 bit 下载至 cable1，均为 SRAM。下载日志：

- `boardtest/captures/sram_download/program_display_20261030_152319.log`
- `boardtest/captures/sram_download/program_media_20261030_152353.log`

PC 原有两个旧 App 实例已关闭，本轮只留一个当前工作区 App。用户接回 USB 网卡后，从真实 Flask API 执行以下测试，产品 RTL 和 App 源码未在板测中再修改：

- 遍历实卡六张 BMP 的切图事务；目录索引为 1/3/5/6/7/9，包含 WAV 条目的列表索引不能直接当作 `IMG编号`。
- 三种转场设置后切图，双图和四宫格进入/退出、焦点窗 N/P、非目标窗图片索引保持；完成时布局有效掩码分别为 1/3/15。
- 当前启用的原图、灰度、二值化、雪花、频谱及灵敏度、OSD、音量、亮度/对比度命令 ACK，字幕 `NEAREST TEST` 收到最终校验/提交确认。这里 ACK 不等于肉眼确认相应效果。
- D 收到 460,800 字、缺口为零，与 `diag_audio/IMG0.BMP` 原始像素逐字一致。D 是媒体板源图快照，不是显示板最近邻/SDRAM 扫描读回；缩小结果的逐像素证据来自前述仿真，HDMI 仍需人工看。
- 实际 App 图片上传：单图 127×95、1×1、320×180，双图 1280×720，四图 571×720，全部收到 `result=2`；每次上传后 SD 下一张均正常完成。
- 实际 App 上传本机 `diag_audio/vedio.mp4` 并启用音频，分别从三种布局启动视频。每轮自动检查时分别已发送 606/607/608 帧，READY 正常，`skipped_rows=0`，接收反馈的 `video_missing/audio_missing` 均为 false。测试包含丢包重传，不能写成网络完全无丢包。
- 视频期间 N 被忙状态拒绝，音量与 S 保持可用。停止后通过网页实际使用的 `/api/eth/video/status` 确认释放，原布局、代次、图片索引和有效掩码一致，随后 SD N 继续有效。通用 `/api/status` 本身不触发视频释放查询，临时测试脚本已按真实前端流程修正。

测试原始记录在忽略目录：`nearest_live_result_20261030.json`、`nearest_live_tail_result_20261030.json`、`nearest_video_api_result_20261030.json`（均位于 `boardtest/captures/`）。第一份含初始回归结果及测试脚本错误映射目录索引导致的 golden 文件查找异常；第二份完成正确 golden 比对及图传，第三份完成三布局视频回归。不能把测试脚本问题描述为已修复的产品 bug。

自动测试后视频已停止并恢复单图。用户随后自行测试，确认“测试没问题”，并授权将本版源码、测试、bit/报告及文档提交至当前 feature 分支。该验收不包含恢复 Sobel/锐化，它们仍按 d281ca0 的能力配置关闭。产品频谱 DFT 仍在显示板，本轮未应用 stash 中的频谱下放实验。

## 后续架构审查边界

- 当前 `DISPLAY_DIAGNOSTICS=0`、`VIDEO_LINK_DIAGNOSTICS=0`、`DIRECT_VIDEO_STATUS=0`。未例化的 probe 定义及 generate 中关闭的诊断并不消耗产品 LUT；删除源码有助于整理，但不能报为资源收益。
- 综合层次报告中网络子系统约 2,500 LUT/ripple，视频 pipeline 约 2,315，图音协议接收器约 1,068。层次数字包含子项，不能与子模块再次相加，也不是布线后 LUT。
- 下一批应检查当前产品实际使用的数据格式是否仍承担多种格式的硬件成本，以及互斥的图片/视频缓冲和数据搬运是否可以复用。每项仍须以整机资源和行为测试证明收益。
- READY/credit/NACK、图音提交、SDRAM 在途读排空、错误重试与跨时钟握手承担现有功能。不能把它们因历史调试来源直接归为死代码；删除会改变当前正确性契约，需先形成替代方案。
- 本次未恢复被关闭的 Sobel/锐化，也未将频谱下放；后续恢复时必须重新测量，不能沿用本表声称完整功能低于 17K LUT。
