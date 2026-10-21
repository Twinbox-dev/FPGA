# 双板资源平衡记录（2026-10-21）

本记录以 `feature/dual-board-architecture` 合并后的双板工程为对象。媒体板和显示板分别综合、布局布线；所有新 bit 仅写 SRAM。

## 基线

以媒体板 50 MHz SD、HC-08 和音频回环修复版为基线：

| 板卡 | LUT | FF | BRAM9K | BRAM32K | DSP | Setup WNS | Hold WNS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 显示板 | 13,182 | 9,836 | 40 | 5 | 10 | −5.699 ns | −3.188 ns |
| 媒体板 | 14,367 | 9,625 | 23 | 2 | 2 | −4.351 ns | −2.850 ns |

显示板的 `transition_line_buf` 已使用 BRAM32K：每个 bank 为 1024×32 位，两 bank 合计占 2 个 BRAM32K。无需再次迁移。

## 媒体板 MAC 抓包器候选：撤回

媒体板层级报告中，`media_mac_capture` 约占 281 LUT 和 1 个 BRAM9K；关闭它还会移除 `eth_front` 中仅供探针 B 使用的异步 FIFO。候选把顶层 `MAC_CAPTURE` 从 1 改为 0，综合结果为 14,044 LUT、9,374 FF、20 BRAM9K、2 BRAM32K、2 DSP，资源收益为 323 LUT 和 3 个 BRAM9K。

候选布局布线的 setup/hold WNS 为 −3.765/−3.200 ns。Setup 改善 0.586 ns，但 hold 比基线恶化 0.350 ns，超过本轮 0.300 ns 上限 0.050 ns。按验收规则撤回该候选，没有下载它的 bit。媒体板继续保留 MAC 抓包器、D 快照和源数据探针。

## 显示板 FIFO 映射候选：保留

显示板 `eth_front.v` 中的 `tap_afifo` 只有四个实例，均为 512×32 位：两个 Ethernet 探针 FIFO，以及 `media_transaction_writer` 的图像、音频接收 FIFO。原来每个 FIFO 映射到两个 BRAM9K；将同一同步读写 RAM 声明改为 `ram_style="bram_32k"` 后，每个实例映射到一个 BRAM32K。读写指针、异步复位、同步读延迟和 FIFO 深度没有改动。

| 指标 | 基线 | 候选 | 变化 |
| --- | ---: | ---: | ---: |
| LUT | 13,182 | 13,161 | −21 |
| FF | 9,836 | 9,839 | +3 |
| BRAM9K | 40 | 36 | −4 |
| BRAM32K | 5 | 9 | +4 |
| DSP | 10 | 10 | 不变 |
| Setup WNS | −5.699 ns | −5.699 ns | 不变 |
| Hold WNS | −3.188 ns | −3.188 ns | 不变 |

四块 9K RAM 被换成四块目前余量充足的 32K RAM，资源没有形成新的短板；功能仿真和双板六图验收均通过，因此保留该候选。

验证命令：

```text
make -C boardtest media-writer media-display-path media-packet-drain
python scripts/media_sd_board_acceptance.py --images 6 --timeout 45 --settle-seconds 3
```

板级验收覆盖 IMG1→IMG2→IMG3→IMG4→IMG5→IMG0；每张 D 快照均为 460,800 字、序号缺口为 0，且逐字匹配对应 BMP。四个配对 WAV 均报告提交成功，IMG3/IMG4 静音提交成功。逐图结果保存在忽略目录 `boardtest/captures/20261021_173338_sd_board_acceptance.json`。

候选 bit SHA-256：`B5F237FEFDFC5EA36D172A30AE4F933D09B7EF419FEE593B4BE895FB78C034BE`。布局布线报告位于显示板 TD 工程 `phy_1` 目录。

该 bit 于 2026-10-21 下载到 cable0 的 SRAM。HDMI 视觉效果和喇叭输出仍由用户做最终主观确认；本轮 PC D 快照覆盖了 SDRAM 写入、读回与以太网传输数据。
