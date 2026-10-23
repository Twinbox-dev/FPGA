# 可变尺寸图像与固定多窗口实现

更新：2026-10-23。原交接计划已实施；本文作为当前功能/模块说明，不再作为自动执行计划。阶段现场和资源实验已迁至 [开发历史](history/multiview_development_log.md)。

## 当前验收与构建

当前工作区保留可变尺寸单图、双图、四宫格及六种运行时 CV。`772abc8` 的显示顶层仍将 CV 直接旁路；本轮把 `cv_pixel_effects_runtime` 接回正式 HDMI 路径，并用正式 TD 工程重新综合、布局布线及下载。

2026-10-23，自动验证完成布局切换、焦点窗更新、六种 CV 命令和六张源图 D 对比；用户随后确认功能使用正常。用户又用 GUI 全量综合两板并上板，确认重新下载媒体板后恢复正常，最终复测通过并授权全量提交。GUI/CLI 顶层来源一致，显示 RTL 在这轮文档清理期间没有变化。正式资源/时序快照见 [板卡状态](board_status.md)。本版源码与两板 GUI 实测 bit/报告一同保存。

两板下载顺序为显示板 cable0 → 媒体板 cable1。只重烧显示板会清空其显存和布局状态，媒体板可能仍保留上一次已提交状态；本轮“单独重烧显示板无图，随后重烧媒体板恢复”的现象已实证。该现象支持重配置后应用状态不同步的判断，尚未专门实现或验收独立重配置自动恢复；不要把它误记成重新综合用了另一份 RTL。

## 模式与交互

| 布局命令 | 编码 | 窗口框 | 有效掩码 |
| --- | ---: | --- | --- |
| `6` 单图 | 0 | 1280×720 | 0b0001 |
| `7` 左右双图 | 1 | 每窗 640×720 | 0b0011 |
| `8` 四宫格 | 2 | 每窗 640×360 | 0b1111 |

窗口按左到右、上到下编号。x≥640 属右窗，y≥360 属下窗。首次进入多窗口显示当前图及列表后续一张/三张，列表按 BMP 项回环。各窗保留自己的索引，允许重复图片；N/P、轮播或触控切图只更新请求发生时锁定的焦点窗，加载期间移动光标不改变本次目标。

仅允许单图与双图/四宫格互切。双图不能直接切四宫格，反之亦然；网页、后端和 FPGA 都执行该约束。返回单图重新加载当时焦点窗的图片及其配对 WAV。

## 源图、缩小与黑边

网络传未压缩 24-bit BMP 转换后的 RGB565，宽 1–1280、高 1–720。不传黑边、不在媒体板垂直翻转。文件行序自底向上；两连续像素打成一个 32-bit 字，低半字先出现。奇数宽度的相邻行连续打包，只有整图像素数为奇数时才补末字高 16 位。

单图按原尺寸居中填黑，不放大、不缩小。多窗口按目标框等比例双线性缩小、不裁剪、不拉伸；比窗口小的图保持原尺寸。缩放和补黑发生在装载时，显示扫描不再实时做四路缩放。

`view_scale_geometry` 计算目标尺寸与边距；`view_bilinear_shrink` 用定点插值生成 RGB565；`view_image_pipeline`/`media_frame_pad` 处理反压与黑边。横纵只有一像素、奇数尺寸、截断帧和多张连续帧由 golden 仿真覆盖。

## SDRAM 槽位和黑窗更新

全局 BUF0/1 是两个各 460,800 字的图像区；BUF2/3 保留音频双缓冲，不能当作空闲图像 bank。完整地址表见 [双板架构](dual_board_architecture.md)。

| 模式 | 每窗 32-bit 字数 | 一整页字数 |
| --- | ---: | ---: |
| 单图 | 460,800 | 460,800 |
| 双图 | 230,400 | 460,800 |
| 四图 | 115,200 | 460,800 |

首次进入多窗口，在非活动全屏区依次准备所有窗口；旧单图及音频继续工作，整页齐备后统一提交。已有多窗口布局更新一个槽时：

1. 锁定窗口/布局代次，清除目标有效位，配置通过视频帧边界生效。
2. 读引擎确认旧配置的在途返回已排空，才允许向媒体板返回 PREPARE 成功。
3. 目标槽原地写入；该窗口扫描输出黑字，整屏 FIFO 字数和 HDMI 时序不变。
4. 图像校验、填黑/缩小和 SDRAM 写入完成后，发布新有效位；帧配置生效及排空确认后报告完成。

其他槽不改写。失败的原地更新保持目标黑色，不承诺恢复旧像素；可重试或返回单图。窗口行宽 320 字，突发不可越过该边界。不能只在最终 RGB 上画黑色矩形而让旧读请求继续访问正在覆盖的槽。

这套方案用一块全屏区保存一整页缩小后的图，避免了早期评估中的四份 720p 原图、四窗双缓冲和额外后台合成帧；旧两份可行性文档已合并到本文，不再作为另一套待实现架构。

## 音频、CV、转场和 OSD

- 多窗口不发送或播放 WAV，单图保留现有图音提交和转场结束后换源。
- 多窗口直接切；单图继续支持直接切、交叉溶解和 32 像素柔边替换。
- 多窗口不清除音量、频谱、字幕、OSD 或 CV 设置。频谱/字幕由用户按需关闭。
- CV 在整屏合成之后处理整屏，包括黑边；亮度/对比度、频谱、字幕/OSD 和光标随后叠加。没有逐窗 CV。
- OSD 显示源图宽高；多窗口跟随光标焦点窗，尺寸与有效图片元数据同步。

六种 CV 的帧边界锁存和等延迟切换见 [CV 说明](display_cv_effects_exploration.md)。

## 协议与状态

包头和通用媒体字段见 [媒体链路协议](media_link_protocol.md)。图像 BEGIN 为 16 字节：

```text
frame_id:u16, image_index:u8, flags:u8, total_words:u32,
width:u16, height:u16, layout:u8, window:u8, generation:u16
```

媒体字段小端，`total_words=ceil(width×height/2)`；校验覆盖实际传输字，包括奇数末尾的零高半字。窗口状态仍使用 V1 大端 TYPE/LEN 包头，载荷的 generation/尺寸按小端。

| 类型 | 方向 | 载荷 |
| --- | --- | --- |
| 0x0048 查询 | 媒体→显示 | seq:u8 |
| 0x0048 VIEW_STATUS | 显示→媒体 | 16 字节状态体 |
| 0x0049 PREPARE | 媒体→显示 | seq, action, layout, preferred_window, generation:u16, reserved:u16=0 |
| 0x004A PREPARE_REPLY | 显示→媒体 | seq, result, locked_window, layout, generation:u16, base_image_index, valid_mask |

action：0 启动/布局，1 下一张，2 上一张，3 取消，4 D 快照锁，5 释放快照锁。preferred_window 为 0–3 时显式指定；0xFF 使用当前光标；0xFE 优先使用已锁定的本地 GT911 目标，否则使用光标。准备结果 0 成功、1 忙、2 非法、3 代次过期。

VIEW_STATUS 逐字节：

```text
sequence:u8, generation:u16, layout:u8, busy:u8,
focus:u8, valid_mask:u8, image_index[4]:u8,
focus_width:u16, focus_height:u16, result:u8
```

媒体板用 PC V1 type=0x0003 转发这个 16 字节状态体；USB 以 0xA7 起始转发。不能把它和旧的 type=0x0003 原始像素探针按同一种长度解析。

图像 RESULT=0 表示单图图像就绪，之后继续音频；多窗口 RESULT=3 表示本窗已暂存、整页仍需下一窗。最后一窗和显示配置生效后 RESULT=2 才是实际提交。只收初始 ACK 或 HTTP 200 不代表 HDMI 已换图。

## 忙与仲裁

`media_view_scheduler` 统一调度 SD 读取、N/P、布局和快照。忙时拒绝新的图像/布局/D 请求，不建立无界队列；自动轮播暂停计时，完成后重新计时。显示设置走独立控制核，共享的 UDP 发送在包边界仲裁，不在 DATA 中间插控制字节。

`view_session_manager` 管理目标锁定、代次、页掩码、同槽隐藏及旧读排空。`view_video_config` 在视频帧边界提交配置；`frame_fifo_read`/`view_scan_address` 和写地址模块限制窗口行边界、刷新与忙门控、异步 FIFO 归属。超时取消必须先排空写事务再解锁，不能让后来的帧占用未结束请求。

网页基于板卡状态灰显控制，连接、S 和日志保持可用；双/四图直接转换始终禁用。后端 `/api/cmd` 返回 409 拒绝忙/非法布局；真实完成、失败或 S 查询确认空闲后才解锁。重下载后后端可能仍缓存旧 sequence，先发 S 请求重新同步。

D 是媒体板重读锁定源图，不是显示扫描或 CV 输出。正式 PC 快照的 layout/window/generation 固定为零；快照使用零样本音频握手，不校验配对 WAV 内容。产品 D 不能代替显示端像素验收。

## 模块与验证入口

| 范围 | 生产模块 / 工具 |
| --- | --- |
| 媒体源和网络发送 | `media_image_source`、`media_frame_format`、`media_image_tx` |
| 统一窗口调度 | 媒体 `media_view_scheduler`；显示 `view_protocol_rx`、`view_session_manager` |
| 缩小/填黑/入存 | `view_image_pipeline`、`view_bilinear_shrink`、`media_transaction_writer` |
| 扫描与跨域配置 | `view_video_config`、`view_scan_address`、`view_write_address`、`frame_fifo_read/write` |
| 全屏图像处理 | `cv_pixel_effects_runtime`、`display_levels_rgb` |
| 参考诊断 | `boardtest/diagnostics/` 与 `boardtest/reference_builds/` |

```sh
make -C boardtest view-geometry view-bilinear view-image-pipeline
make -C boardtest view-scan-address view-write-address view-framepath
make -C boardtest view-session view-control-path view-image-jobs view-commands
make -C boardtest cv-unit axis
python scripts/web_console/test_view_status.py
node scripts/web_console/test_frame_view.js
```

这些定向测试覆盖缩小 golden、黑边/单轴/截断、反压、窗口行地址、排空、代次、目标锁定、整页/单窗提交、并发命令拒绝及 CV 像素/同步。它们不等于厂商 SDRAM IP 或完整 TMDS 物理仿真。

## 2026-10-23 板级证据

正式两板 bit 上验证：单图 N、进入双图、双图焦点窗 N、禁止双图直接进四图、返回单图、进入四图、四图焦点窗 N、返回单图，均以 VIEW_STATUS 完成且掩码正确；其余窗口索引未变。六种 CV 的显示 ACK 均返回对应值。

六张源图的 D 验收如下；源图索引是实卡 FAT 列表索引，不是连续图片编号：

| BMP | FAT 索引 | 源尺寸 | D 字数 | 缺口 / 像素差异 |
| --- | ---: | --- | ---: | --- |
| IMG0 | 9 | 1280×720 | 460,800 | 0 / 0 |
| IMG1 | 1 | 1280×720 | 460,800 | 0 / 0 |
| IMG2 | 3 | 1280×720 | 460,800 | 0 / 0 |
| IMG3 | 5 | 504×720 | 181,440 | 0 / 0 |
| IMG4 | 6 | 571×720 | 205,560 | 0 / 0 |
| IMG5 | 7 | 640×480 | 153,600 | 0 / 0 |

配对文件为 IMG0/1/2/5 四个 WAV，IMG3/4 无配对。以上 D 表仅证明源图精确，不把零样本快照握手当成四份 PCM golden 验收。此前带临时监测的构建确认了扫描非零、完整 AXIS 帧及行结束计数；这些诊断证据与正式产品的源码/bit 应分开归档。最终显示观感由用户在本轮正式构建上确认正常。
