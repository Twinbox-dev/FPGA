# 多窗口诊断参考构建

## 用途与限制

此目录保存 2026-10-23 用户确认多窗口正常的诊断 bit 对。它供复现和对比使用，不是正式产品版本。

- `display_diag.bit`：显示板诊断构建，保留多窗口渲染，加入 SDRAM 扫描诊断和 `0x004B` 测试光标；CV 被替换为 RGB 直通，因此不能用它验收 CV。
- `media_diag.bit`：媒体板诊断构建，在媒体源状态中暴露错误原因和文件索引。
- JTAG 目标：显示板 cable0，媒体板 cable1。
- 源码基线：`d195887`。提交 `699f801` 相对它没有 HDL 改动。

用户在这对 bit 上确认多窗口显示正确。随后保持显示诊断版、仅将媒体板换回正式 bit，网页状态也报告四窗有效；单窗“下一张”使焦点窗口索引从 3 变为 5 并以成功状态结束。因此媒体诊断覆盖不是该次切图成功的必要条件。

## 重新生成

先从仓库根目录生成隔离工程：

```powershell
python boardtest/diagnostics/prepare_display_digest.py `
  --output boardtest/captures/multiview_live/display_digest_scan_only `
  --scan-only --bypass-cv --test-cursor

python boardtest/diagnostics/prepare_media_source_diag.py
```

分别在生成的 `syn_1/` 与 `phy_1/` 中按 TD CLI 流程综合和布局布线。输出仍位于忽略的 `captures/` 中；只有经过重新验收并明确需要保存的 bit 才复制到本目录。

对应诊断源码入口：

- `boardtest/diagnostics/prepare_display_digest.py`
- `boardtest/diagnostics/display_frame_digest.v`
- `boardtest/diagnostics/display_test_cursor.v`
- `boardtest/diagnostics/prepare_media_source_diag.py`
- `boardtest/diagnostics/check_multiview_scan.py` 与 `check_multiview_scan_short.py`

## 2026-10-23 正式工程提取候选

用户要求把测试构建的 RTL 放回正式工程，先以 CV 直通验证多窗口。当前工作区已将测试版的显示顶层、显示网络 wrapper、媒体图源错误状态及忙拒绝逻辑提取到正式源码，未移植生成探针的独立仿真工程。显示顶层仍保留扫描诊断和测试光标入口；CV 像素通路被直通，CV 模块源码仍保留，但本候选不验收 CV 效果。

正式 TD 工程已重新综合、布局布线并生成两板 SRAM bit。Web/UDP 实板状态验收：

- 单图 `N`：IMG1 提交为 IMG2，`busy=0`、`result=0`。
- 双图：布局提交成功，两个窗口均有效。
- 双图焦点窗切图：窗口 1 从 IMG2 更新到 IMG5，窗口 0 保持 IMG4。
- 双图直接切四宫格被拒绝；返回单图后进入四宫格成功，四个窗口有效。

最终显示状态为四宫格、四窗有效、空闲、结果成功。布局和图索引来自板卡 `VIEW_STATUS` 回包；本阶段尚未采集 HDMI 屏幕图像。正式 P&R 资源：显示板 13,271 LUT、9,306 FF、BRAM9K 34、BRAM32K 7、DSP 18；媒体板 15,640 LUT、10,687 FF、BRAM9K 20、BRAM32K 2、DSP 5。两板最终 setup/hold WNS 仍为负值，按报告记录，不称时序收敛。

候选 bit 保存在各自正式 TD 工程 `*_Runs/phy_1/`，当前仍未提交，待验收后与源码和报告一起提交。此候选用于确认无 CV 时的多窗口功能，不代表 CV 已恢复。
