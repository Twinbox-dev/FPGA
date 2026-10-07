# 验证与日常迭代

本文记录**当前已经实现**的验证入口。已上板稳定基线是 `main` 的 `98caa0b`：
SDRAM 时钟 100 MHz，已上板验证；用户将同一版改为 125 MHz 后上板黑屏，
因此开发和对照均以 100 MHz 为准。最终多分辨率修复的证据见
[`multires_fix_postmortem.md`](multires_fix_postmortem.md)。

## 按改动范围选择验证

| 改动 | 开发时先运行 | 收口时 |
|---|---|---|
| `frame_fifo_write/read`、仲裁或跨域 FIFO | `make -C boardtest framepath arbrace readeng` | 七卡回归、TD、上板 |
| `video_delay`、AXI 像素适配 | `make -C boardtest vdelay axis` | 七卡回归、HDMI 上板 |
| `eth_front`、命令、Web 预览 | `make -C boardtest ethfront cmdarb uart`；`node scripts/web_console/test_frame_view.js`；`python scripts/web_console/test_stream.py` | 七卡回归、PC/板卡联测 |
| SD/FAT/BMP/WAV 状态机 | `make -C boardtest smoke`；涉及配对时加 `paircheck` | 七卡回归、真实卡上板 |
| 仅文档或不执行的脚本 | 相应格式/脚本检查 | 无需为了文档重跑全部仿真 |

`boardtest` 需要 WSL/Linux 的 Verilator、make 和测试卡镜像。已有构建结果可复用；
修改对应源码后 make 会重编。只跑一张卡：

```sh
make -C boardtest smoke
make -C boardtest paircheck
make -C boardtest transition-unit
make -C boardtest transitionpair
SIM_TRANSITION=2 SIM_PAIR=1 boardtest/build_board/sim_board img/card_user.img
make -C boardtest lean-smoke
SIM_LEAN_LIST=1 SIM_PAIR=1 boardtest/build_board_lean/sim_board img/card_diag.img
make -C boardtest regress CARDS="card_user card_user_2wav"
make -C boardtest regress
```

`smoke` 使用 `card_diag`，在首图像素逐字比对与全部 WAV 扫描/BUF2 打包比对后
结束（`SIM_SMOKE=1`），**不覆盖播放回卷、切图、上一张或自动轮播**；
`paircheck` 在全列表配对 golden 断言、首图音频和第一次图音切换后结束
（`SIM_PAIR=1`），实测诊断卡 18/18、约 1 分 21 秒；不覆盖后续轮播/回卷。
`transition-unit` 覆盖混合器、逐像素相位、行就绪、100/75 MHz 双时钟行缓存、
SDRAM 阻塞时整行回退及真实帧 FIFO 与行预取同时工作，共六项；最后的寄存式
读口预留修改后仍全部通过。`transitionpair` 使用诊断卡验证带 WAV 的图音延迟
原子提交（19/19）；`SIM_TRANSITION=2` 的 `card_user` 用例验证无配对 WAV 时
完成切换后才静音（13/13）。默认直接切的 `paircheck` 保持 18/18。
`regress` 默认仍运行全部七卡。可选卡名固定为
`card card_mbr card_empty card_frag card_diag card_user card_user_2wav`，脚本会先检查
镜像存在。日志生成在 `boardtest/logs/`，属于可再生输出，不纳入 Git。
修改 `boardtest/vsrc/` 中的 SD/FAT/BMP/WAV 副本时，用
`scripts/sync_boardtest_sd.py` 核对与板级 RTL 的同步关系。

## 覆盖边界

`boardtest` 主仿真用 C++ SD 卡模型和简化的显存/读写行为，不包含厂商 SDRAM
控制器、板级布线、完整 HDMI/TMDS 或以太网物理层。模型顶替的接口不能被误当成
真实 RTL 的逐拍证据。真实写 FIFO 和突发时序要看 `framepath`、
`arbrace`、`readeng`；视频读和封包分别看 `vdelay`、`axis`。
厂商 IP 的物理时序和真实显示效果仍需 TD 报告与上板确认。

读回探针目前每三个显存字抽一个，只能证明覆盖到的样本正确。验证图像时应同时
比较有效图像和上下左右黑边；详见修复复盘。新增功能若在稳定版上失败，
先 diff 新旧源码并检查新引入的行为逻辑，再扩展到时序/IP 假设。

## 容易重犯的实现错误

- TD 推断 BRAM 时，存储数组需要合适的 `force_ram`/style 标注、无复位的独立
  读写 always 和支持的深度；之前 1030×8 的缓冲落成 LUT/FF，资源直接超限。
- 同一寄存器的复位与更新不能分属多个 always；TD 会报多驱动。
- Gray 异步 FIFO 的 full/empty 应寄存，读出当前队头 `mem[rbin]`；
  曾有组合环和跳过首字的失败实例。
- CDC toggle 发出时，同拍锁存并保持跨域数据；单拍 `tx_pkt` 直接跨域曾让
  以太网转储包退化为 ACK。
- 修改 Web 模板后重启 `app.py` 并刷新浏览器，否则可能仍在看缓存页面。
- TD 重生成 `sys_pll` 后可能删掉生成封装中的 `extlock` 输出；顶层仍连接
  `sys_pll_lock` 用于复位释放。综合前检查 `sys_pll.v` 的端口声明和原语连线。

## 合并前检查

涉及功能 RTL 的变更至少运行相关模块测试和默认七卡回归，再查看 TD 的资源与
时序报告；影响显示、音频、SDRAM、时钟或硬件接口时安排上板对照。不要把
“仿真通过”写成“硬件时序收敛”。完整七卡、特定模块测试以及板级现象分别记录。

尚未实现的增强验证包括厂商 SDRAM IP 等价模型、完整 TMDS 接收器和可听音频
golden；旧文档曾将这些规划写成已存在的测试结构，此处明确标为未来工作。
