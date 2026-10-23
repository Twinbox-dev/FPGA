# 双板资源优化：2026-10-24

## 范围与复现基线

本轮继续在 `fix/multiview-resource-optimization` 工作，起点为用户已验收的 `4cbbe23`。视频、多窗口音频和转场讨论保存在 [后续方向](video_multiview_direction.md)，本轮不增加这些功能、不修改协议、布局和默认显示设置。

实验初期在 `boardtest/captures/resource_20261024/` 的独立工程内完成，每个候选冻结全部 `user_source`、主 `.al`、`syn_1/phy_1` 工程列表和设置，以及输入文件清单。显示候选由用户确认可验收后，其 bit/报告同步到正式 TD 输出并随本次提交保存；已撤回媒体候选仍只留在实验目录。

| 基线 | 显示板 | 媒体板 |
| --- | ---: | ---: |
| 门级 LUT | 14,393 | 14,679 |
| 布线后 LUT | 14,924 | 15,640 |
| 布线后 FF | 10,090 | 10,687 |
| 切片 / 9,800 | 8,613 | 8,746 |
| BRAM9K / BRAM32K | 35 / 11 | 20 / 2 |
| DSP / PLL | 18 / 4 | 5 / 3 |
| Setup / Hold WNS | −5.988 / −2.960 ns | −3.202 / −2.935 ns |

媒体基线在本轮独立工程重新执行综合及布局布线，门级、最终资源和全局时序与正式基线一致。以下区分门级和布线后数字，层次表的 `lut/ripple/le` 也不能直接当作最终 `#lut` 比较。

## 显示板：关闭默认启用的验收诊断硬件

当前正式顶层还直接例化两项调试逻辑：

- `display_frame_digest`：对真实 SDRAM 扫描做计数/摘要，按诊断请求回包。
- `display_test_cursor`：接收 `0x004B` 并覆盖窗口选择坐标，供无人值守焦点测试使用。

候选增加顶层参数 `DISPLAY_DIAGNOSTICS=0`，只在参数为 1 时综合这两项逻辑。参数为 0 时关闭诊断请求，并固定测试光标使能为 0，正式 GT911 光标和焦点照常工作。模块源码、历史诊断、仿真均保留。

这不涉及媒体板产品 D 源图快照、CV、字幕、OSD、频谱、音频、转场、多窗口或 GT911 滑动。正式控制报文不依赖这两项诊断。诊断默认关闭也允许综合器移除只服务诊断的选择逻辑。

| 指标 | 已验收基线 | 候选 | 变化 |
| --- | ---: | ---: | ---: |
| 门级 LUT | 14,393 | 13,872 | −521 |
| 门级 FF | 10,109 | 9,664 | −445 |
| 布线后 LUT | 14,924 | 14,402 | −522 |
| 布线后 FF | 10,090 | 9,659 | −431 |
| 切片 | 8,613 | 8,303 | −310 |
| BRAM9K / BRAM32K | 35 / 11 | 35 / 11 | 不变 |
| DSP / PLL | 18 / 4 | 18 / 4 | 不变 |
| Setup WNS | −5.988 ns | −5.699 ns | 改善 0.289 ns |
| Hold WNS | −2.960 ns | −3.054 ns | 恶化 0.094 ns |
| 视频域 Setup WNS | −4.260 ns | −4.074 ns | 改善 0.186 ns |

候选切片占用 84.72%，LUT 73.48%。总 setup/hold 仍有负裕量，不能把这项收益写成时序收敛。候选物理流程约 3 分 39 秒（布局约 1 分 20 秒、布线约 2 分 14 秒）；并行实验时的墙钟时间只记录，不作稳定性能保证。

已执行 `make -C boardtest view-control-path view-framepath display-mux-lifetime gt911-unit`：覆盖 PREPARE/状态、双/四窗独立 N/P、回环、busy 拒绝、触控/D 调度、真实异步 FIFO/黑窗扫描/排空、UDP 包归属，以及 GT911 I2C/手势/角色光标。定向仿真通过。

此外将冻结副本的 `DISPLAY_DIAGNOSTICS` 置 1 重新综合，确认两项诊断仍可展开：门级 14,404 LUT、10,109 FF。生成层次变化会使映射稍有波动，不能要求其网表与无 generate 的历史基线逐位相同。

候选的正式 bit、门级/布线报告和 `best_result` 已同步到显示板 TD 工程跟踪位置，与当前 RTL 成套保存。bit 下载至 cable0 SRAM 并完成 Web/PC 实测后，用户于 2026-10-24 确认总体功能可验收。自动验收收到 5 张图的完整 D 快照，逐像素与 BMP golden 一致；用户也确认双板产品实测可接受。

用户补充：多窗口偶尔切图会短暂出现黑屏，此时 D 读不出图；用户认为这是此前版本已有的现象，本轮暂不处理且不影响整体验收。该现象记录为已知行为，本提交不声称修复。

## 媒体板：WAV 解析器的两种候选

原 WAV 解析器把固定格式字段保存为 80-bit，然后与 PCM/24kHz/8-bit/mono 常量比较；同时用声明长度、DATA 已读长度和 SKIP 剩余长度三个 32-bit 寄存器。

### 候选 A：格式逐字节检查 + 共享剩余计数器

以一个累计匹配位替代仅用于常量比较的格式寄存器；在互斥的头解析/DATA/SKIP 阶段复用长度寄存器，原始样本总数仍由 `o_data_bytes` 保存。端口、有效拍、错误与重启输出保持一致。

| 指标 | 基线 | 候选 A |
| --- | ---: | ---: |
| 门级 LUT / FF | 14,679 / 10,667 | 14,564 / 10,524 |
| 布线后 LUT / FF | 15,640 / 10,687 | 15,528 / 10,548 |
| 切片 | 8,746 | 8,671 |
| BRAM9K / BRAM32K / DSP | 20 / 2 / 5 | 20 / 2 / 5 |
| 全局 Setup / Hold WNS | −3.202 / −2.935 ns | −3.271 / −3.042 ns |
| 50MHz 域 Setup WNS | +1.269 ns | +0.514 ns |
| 100MHz SD 域 Setup WNS | −2.578 ns | −3.080 ns |
| 物理流程 | 约 5 分 02 秒 | 约 7 分 34 秒 |

候选虽然节省 112 个最终 LUT 和 139 FF，但 50MHz 域裕量减少 0.755 ns，SD 域恶化 0.502 ns；布线还在两个拥塞点上长时间迭代。这些是整机重新布局后的观察，不能仅据此断言 WAV 逻辑直接导致 SD 路径变化。**该候选撤回，不交付到正式媒体板。**

候选 A 的仿真通过：

- `wav-reader-unit`：保留 `boardtest/vsrc/wav_reader.v` 不变，生成改名参考模块；逐拍比较全部端口。4,124 个独立 golden 用例、391,019 拍一致，含每个 fmt 字节全部 256 个取值、零/扩展/短 fmt、重复 fmt、非法格式、未知块、样本边界、超大声明长度、间断有效、截断/重启和随机复位。
- `media-sd-image-source`：原生 SD 引脚模型读取实卡镜像，六张 BMP 完成；IMG0/1/2/5 四份 PCM 分别与 golden 的 480,000/720,000/720,000/720,000 字节一致，累计 29,447 次扇区读取。IMG3/4 无配对 WAV。该测试是仿真，不代表本轮实卡测量吞吐。

### 候选 B：仅格式字段逐字节检查

保持原有三个长度计数器，只优化固定格式字段。相同逐拍测试通过；门级为 14,613 LUT、10,588 FF，相比基线减少 66 LUT、79 FF。完整 SD/FAT/六图/四 WAV 回归亦通过。

最终布线后为 15,638 LUT、10,609 FF、8,859 切片：仅减少 2 LUT，却增加 113 切片；setup/hold 为 −4.256/−3.188 ns，setup 比基线恶化 1.054 ns。物理流程约 4 分 13 秒。**该候选同样撤回。** 这两次实验说明门级数字不能代替整机布线结果。

本轮媒体板生产 WAV 已恢复为起点原文件，整个 `board_media` 正式源码/bit/报告保持基线。新增测试保留，供后续结构优化回归使用；两个实验的输入快照、日志和候选 bit 留在独立输出目录，未执行下载。

## 隔离实验入口

```powershell
python boardtest/diagnostics/prepare_resource_experiment.py --board media --name media_trial
python boardtest/diagnostics/prepare_resource_experiment.py --board display --name display_trial
# 仅在冻结副本中恢复扫描摘要/测试坐标；不改产品源文件：
python boardtest/diagnostics/prepare_resource_experiment.py --board display --name display_diag --display-diagnostics
```

默认输出在 `boardtest/captures/resource_experiments/<name>/`；可用 `--output-root` 指定 captures 下其他父目录。名字已存在则拒绝覆盖。每份 `manifest.json` 保存基线提交和实际冻结输入文件指纹，方便避免“测试 bit 找不到对应源码”。当前未验收中间实验留在忽略目录；一旦成为需复现的正式板测版本，按 [提交规则](repository_commit_policy.md) 成套归档。

在输出的 `<board>/td_project/<project>_Runs/syn_1` 工作目录执行：

```powershell
$taskCli = 'C:\Program Files\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin\td_commands_prompt.exe'
@('source {C:/Program Files/Anlogic/TD_6.2.1_Engineer_6.2.168.116/doc/scripts/DefaultFlow.tcl}', 'exit') | & $taskCli
```

确认本轮 `opt_gate` 完成且无 ERROR 后，在对应 `phy_1` 执行同一命令。不要只看退出码，不要把未重综合的旧网表当成新源码结果。字体 `font.mem` 路径继续由源码目录解析，冻结整个 `user_source` 能保留对应资源。CLI/SRAM 规则仍见 [TD 指南](td_cli_programming.md)。

## 下一步与更大候选

- 当前选中显示板关闭诊断的候选，媒体板保持原稳定版。下一步先验证图像、布局、CV、叠加、转场、音频和真实 GT911。用户负责上电，CLI SRAM 下载及自动检查由开发端执行；不烧录已撤回的 WAV 实验。
- 媒体板完整 Ethernet 约 5,382 LE，其内加密 UDP/IP 栈约 3,323 LE；FAT32 约 2,161 LE。大规模回收要从这些模块的存储/协议结构寻找，不能把本轮小候选说成已经完成激进优化。
- 当前 IP 顶层仅暴露 ARP 重试次数/间隔、地址与设备参数，没有现成可调的 ARP 缓存深度。重试参数不是缓存容量开关，不应为省资源改掉网络可靠性。
- 若重新实现媒体网络，必须保留 PC 动态 MAC 学习、ARP、ping、控制/字幕、PC D 与显示正式数据的路由，不能直接把显示板单固定对端的精简栈复制过去。
- FAT 文件元数据改成同步 BRAM 需核对查找延迟与配对行为；不能只加 RAM 属性，也不能因固定目录样例通过就缩短合法文件大小或删掉碎片簇链支持。

现有源码、测试和正式已验收产物在提交前仍应逐项核对；本记录不构成向 main 合并或推送的授权。
