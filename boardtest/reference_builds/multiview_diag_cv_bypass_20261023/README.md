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

## 后续正式工程阶段

测试源覆盖提取到正式工程并以 CV 直通重新综合的阶段已保存为 `772abc8`；当时显示板为 13,271 LUT、9,306 FF、34 BRAM9K、7 BRAM32K、18 DSP，媒体板为 15,640 LUT、10,687 FF、20 BRAM9K、2 BRAM32K、5 DSP。该阶段不宣称 CV 效果通过。

随后工作区恢复 `cv_pixel_effects_runtime`，重新生成正式全功能 bit 并通过本轮自动/用户板级检查。现行功能和证据见 [多窗口实现](../../../docs/native_frame_multiview_handoff.md)，资源见 [板卡状态](../../../docs/board_status.md)。本目录两份历史 bit 不会因此升级为完整 CV 产品版；继续保留用于复现旧隔离结果。

`check_multiview_scan.py` 解析 64-byte 诊断体，`check_multiview_scan_short.py` 解析 16-byte 诊断体；short 指回包格式，不是删减版测试流程。必须选择与诊断 bit 一致的解析器。
