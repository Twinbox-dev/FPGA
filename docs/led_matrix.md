# 显示板 IS31FL3731 LED 点阵（静态测试版）

本记录对应显示板 LED 点阵功能的当前构建。**当前产品构建使用固定测试阶梯，真实 DFT 频谱未接入 LED**；HDMI 频谱及其余产品功能不受影响。

## 硬件与接入

- 显示板 I2C：`matrix_i2c_scl = J12`、`matrix_i2c_sda = K11`（`pin.adc`）。
- IS31FL3731：地址 `0x74`，约 50 kHz I2C，144 路 PWM，有效 15×7 点阵。
- 顶层参数：`PRODUCT_LED_MATRIX_ENABLED = 1`；当前 `PRODUCT_LED_TEST_PATTERN = 1`。
- 模块：`audio_to_15ch`、`matrix_core_mapper`、`matrix_transition_arbiter`、`matrix_transition_animator`、`is31fl3731_i2c_master`（均在 `board_display/user_source/hdl_source/led_matrix/`）。

## 数据通路

```
显示端 spectrum_dft（sd_card_clk，16 路 levels，0..120）
  -> audio_to_15ch
       col 0..13 = band 0..13
       col 14    = max(band 14, band 15)      // 16->15 合并
       每列经 point_height 映射为 3-bit 高度 0..6
  -> matrix_core_mapper
       15 列柱体；峰值保持约 250 ms、按 10 ms tick 衰减的顶灯
  -> matrix_transition_arbiter / animator
       切图时在音频 bitmap 上叠加 LED 转场
  -> is31fl3731_i2c_master
       15×7 物理通道映射、初始化、PWM 刷帧
```

当前 `PRODUCT_LED_TEST_PATTERN=1`：LED 显示固定的 15 列测试阶梯
`0,0,0,1,1,2,2,3,3,4,4,5,5,6,6`，不读取真实 DFT；频谱开关（`bar_en`）和音量静音仍会关闭/清零点阵。

## 构建与资源（2026-10-31 18:48）

- 构建清单与 bit 随发布标签 `dual-V4.0` 归档（主线不再跟踪 `*_Runs/` 与 manifest）；
  当时 manifest 内全部源码哈希与提交源码一致。
- 显示板 bit（标签内路径 `board_display/td_project/lab_ex5_i2s_v1.0_Runs/phy_1/lab_ex5_i2s_v1.0.bit`），
  SHA-256 `010EE1BBE108ED1BBF9519C1D9C1302688E6A5841B95BA13E25422AF776FA0AE`。
- 布局布线：17,527 / 19,600 LUT（89.42%），BRAM9K 51/64，BRAM32K 11/16，12,392 FF；
  SWNS −9.599 ns、HWNS −2.935 ns。**仍为既有静态时序违例，未收敛**，不能称为时序通过。
- 最小诊断工程 `boardtest/diagnostics/led_matrix_minimal`：50 MHz I2C/整屏点亮冒烟，
  229 LUT，SWNS +10.744 ns；只验证总线/面板/供电，不验证列行映射与高度。

## 板级观察与边界

- 用户上板确认：静态阶梯显示正常；频谱开关与 LED 亮/灭联动正常。
- LED 转场基本能够触发，但存在偶发漏触发；当前未定位，暂按硬件/仲裁疑点搁置。
- 真实 DFT 频谱接入未进入本构建。实验中发现：
  - DFT 在同一拍更新 `levels` 与 `done_toggle`，LED 侧下一拍采样存在 1 拍竞争；
  - 16→15 的“取 band14/15 最大值”与“只取前 15 路”是两种不同策略，需最终确认；
  - 显示板在约 89–91% LUT 下多次出现布局布线差 1 条网络，真实频谱集成未通过放下验证。
  这些实验未提交。
- HDMI 频谱、CV、多窗口、字幕、触控、OSD、视频、七段数码管等既有功能未改动。

## 后续

1. 明确 LED 的 16→15 策略（合并或丢弃第 16 路）。
2. 以锁存 + 延迟计算的方式接入真实 DFT levels，先解决 1 拍竞争。
3. 在显示板资源/布线可行的前提下，评估是否保留 LED 转场与峰值顶灯，并完成时序与板级验收。
