# 媒体板 MF168 激光手势

本记录对应媒体板 MF168 双激光测距手势前端。手势在媒体板本地解码，复用现有
`media_view_scheduler` 切图与亮度控制；显示板无需改动。

## 硬件与接入

- 两路 MF168（UETVL004DPB3000）激光测距传感器，UART 115200 8N1：
  - 左：`laser_left_rx = J4`
  - 右：`laser_right_rx = H4`
- 板载指示 LED `led[3:0]`：`A4`、`A3`、`C10`、`B12`，高有效。
- `timing.sdc` 对两路激光 RX 加 `set_false_path`（异步 UART，模块内部 3-FF 同步后使用）。
- 模块：
  - `MF168/mf168_link.v`：8N1 接收，帧头 `A5 5A`，解析 ERROR/TYPE/RANGE/AMPLITUDE/USER_OUTPUT 与校验和；
  - `MF168/gesture_cmd_gen.v`：存在检测、左右滑动、双束亮度步进。

## 手势行为

- **存在检测**：最近 3 帧中 2 帧进入 200–400 mm 窗口为进入；150–450 mm 窗口内保持；
  200 ms 采样超时、80 ms 历史窗口。
- **左右滑动**：
  - 左束先进入、右束随后进入 = 左→右，触发 `next`；
  - 右束先进入、左束随后 = 右→左，触发 `prev`；
  - 两束进入间隔小于 60 ms 视为“接近”而非滑动（AMBIGUOUS），800 ms 配对超时。
- **亮度**：双束同时存在且距离同方向变化时按 50 mm/步、100 ms 停留、250 ms 冷却发送
  既有亮度命令 `0x5D`（增）/`0x5B`（减）。
- **与现有控制的关系**：
  - `next/prev` 接入 `media_view_scheduler` 的 local next/prev，与实体按键、自动轮播同一路径；
  - 手势脉冲在调度器忙时保持到 `job_start`，避免一拍脉冲落在事务中被丢弃；
  - 手势属于本地事件，不产生命令 ACK（`suppress_cmd_ack`）；控制核事件仲裁为
    以太网 > 串口 > 手势。
- **LED 指示**：LED1 = 左→右（next），LED2 = 右→左（prev），LED3 = 亮度步进，
  LED4 = 以上都没有（idle，其余三灯熄灭时点亮）。

## 构建与资源（2026-10-31 22:07）

- 媒体板 bit 与构建清单随发布标签 `dual-V4.0` 归档（主线不再跟踪 `*_Runs/` 与 manifest）。
- 媒体板 bit（标签内路径 `board_media/td_project/media_net_Runs/phy_1/media_net.bit`），
  SHA-256 `463578AE7888DD7E33B9F2E8821B53B0320A534CE4EDD9EF0D9D7EFC32CDC8A7`。
- 布局布线：16,188 / 19,600 LUT（82.59%），10,090 FF，BRAM9K 19/64，BRAM32K 2/16；
  SWNS −4.206 ns、HWNS −3.188 ns。**仍为既有静态时序违例，未收敛**。
- 该 bit 由桌面更新工程构建，后在仓库内按同一源码集合重新发布 manifest 并完成板测；
  `.al` 的桌面外部路径和 UDP 栈上误加的 `AutoExcluded` 已修正，不影响网表。
- `.prj` 与源码清单已包含 `MF168/mf168_link.v`、`MF168/gesture_cmd_gen.v`；
  新增引脚与 false_path 已写入约束。

## 板级验证

- 用户上板确认：左右滑动切图、双束亮度调节与 LED 指示均通过。
- 与显示板提交版（LED 静态测试阶梯，见 [LED 矩阵](led_matrix.md)）联调通过。
- 未覆盖：不同安装距离/角度的传感器标定、长时间连续手势、复杂光照/反射干扰。

## 边界

- 手势为媒体板单板功能；显示板 RTL 未因本功能改动。
- 时序仍存在既有违例，不能称为时序通过；资源数字按完整布局布线报告。
