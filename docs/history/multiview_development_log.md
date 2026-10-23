# 多窗口开发与资源优化历史（2026-10-22—23）

本文件保存原交接文档的阶段现场、失败候选、资源测量和诊断证据。各节的“当前”“下一步”“恢复入口”仅指当时状态，不构成后续执行或提交授权。

当前行为、完整 CV 复接和最终板测结果见 [可变尺寸与多窗口实现](../native_frame_multiview_handoff.md)；当前资源快照见 [板卡状态](../board_status.md)。历史诊断 bit 的用途及限制见 [诊断参考构建](../../boardtest/reference_builds/multiview_diag_cv_bypass_20261023/README.md)。不要用某个旧候选的资源或功能结论覆盖后来的正式构建。

## 19. 执行现场与后续恢复入口（2026-10-22）

本轮基线仍为 `main@459574b`，截至本记录没有新增提交、没有推送。允许本地提交最多三次；
每次须对应真正完成的任务点。原计划的可变尺寸单图、多窗口、仲裁审计均继续有效。

### 19.1 可变尺寸单图已经实施的内容

- 媒体板 `media_frame_format` 改为源尺寸 RGB565 连续打包，奇数像素末字高 16 位为零。
- `media_image_tx` 发送 16-byte BEGIN，携带原始尺寸／字数，现阶段 layout/window/generation 为零。
- 显示板 `media_protocol_rx` 校验新 BEGIN；新增 `media_frame_pad` 在显示侧生成居中黑边。
- 显示板保存源尺寸、OSD 增加十进制宽高。PC D 解析、HTTP 帧头及画布已支持变长源尺寸。
- 单图正式包及音频保留既有结果握手，D 仍为媒体侧重读源图，不能当显示侧 SDRAM 验收。

已用仿真复现并修复两处新增链路缺陷：

1. 补黑可在 BEGIN 后立即产生字，而 `frame_fifo_write` ACK 时异步写 FIFO 仍处于复位。
   旧 always-ready 仿真模型隐藏了丢字；真实握手模型稳定停在 `460797/460800`。
   修复是在 `frame_read_write` 导出写域 `write_ready`，等待 FIFO 复位同步释放、保留 31 字
   流水余量（占用低于 480），并让 `media_transaction_writer` 按此信号弹 FIFO／补字。
2. `stream_is_audio` 是上一包 DATA 的类型，WAV 之后保持为 1，直到新图首个 DATA。
   直接用它选择补黑输出会在 BEGIN 与首 DATA 之间丢掉生成的黑字。新增 WAV→窄图用例
   稳定失败，现改由 `frame_active || image_out_valid` 在整幅图生成期间拥有图像输出路径。

定向仿真已通过协议、奇数尺寸/1×1/截断填黑、真实帧 FIFO、OSD、整帧回复、WAV 残留类型等。
`tb_media_pair_504.sv` 已升级为实际生产异步 FIFO 与 SDRAM 请求引擎，不再使用 always-ready
存储替身；当前又增加真实 IMG0 BMP 和变化像素，逐个检查所有 App 写字和垂直翻转地址。
执行 `make media-pair-bmp0 media-pair-504`；完整 1280×720 加原有 100 μs 包间隔需约 205 ms
模拟时间，不能再沿用原 192 ms 看门狗。

### 19.2 早期板级证据与排查现场（已由 19.4 收口）

媒体板产品 bit：`F0CC7D6AF1473E6B6F7F8DCF0ABFEC0A3C6EDE1879EB7F89F33352240FE905CA`。
显示板产品 bit：`3189B343BC71B13DE73675E191317747B846548ABAD1268FF7FA0127E31647B4`。
两板均已由 `scripts/program_sram.ps1` 普通 Medium 权限、无 UAC、只写 SRAM 成功下载。
烧录命令、记录与 USB 重连恢复事实见 `td_cli_programming.md`，不要重新猜命令。

六张图均已切换成功，媒体侧 D 与 golden 逐字节一致、seq 缺口 0：
`IMG1/IMG2/IMG0=1280×720`，`IMG3=504×720`，`IMG4=571×720`，`IMG5=640×480`。
这些尺寸读取自 BMP 文件头；实卡镜像与实卡仍应分开，文件身份由实际 D 字节匹配确认。

为满足“显示端实际验证”，在 `boardtest/diagnostics/` 新增临时被动扫描摘要工具：

- `display_frame_digest.v` 监听 SDRAM 视频返回，不主动发起 SDRAM 请求；排除音频，统计
  460800 个视频字、32-bit 累加和和顺序摘要 `h=(h*33)^word`（按 32 bit 截断）。
- `prepare_display_digest.py` 在忽略目录 `boardtest/captures/display_digest_stage1/` 派生
  独立 TD 工程，复制顶层/以太网文件并修正 include/ROM 路径，**不修改产品源或产品 bit**。
- 临时查询包为 `AA BB CC DD 00 47 00 00`，发送至显示板 `.2:1`；诊断回复直达 PC `.1:4`，
  产品回复仍去媒体板 `.3:1`。用 `check_display_digest.py` 通过 Flask N/S/D 驱动并对照
  独立 BMP 居中填黑 golden。需要 Flask :5000 正在运行；可自行 CLI 启动 `app.py`。
- unit：`make display-digest`；下载隔离 bit：`program_sram.ps1 -Board display -CandidateBit ...`。
  诊断结束后运行不带候选路径的 `-Board display` 恢复产品 bit；不要把临时探针接入正式源列表。

当前板上显示板为诊断 bit `E6DEC06CC057504E607BECC017A853139C107D9C841BC4DD2129CC8A931AE6AB`；
媒体板 18:21 已重新下载上述 F0CC 产品 bit，FAT=0x08，网络恢复。诊断期间曾媒体板不回 ping，
重下载后恢复，不应把该次离线误判成显示探针协议失败。

**当前实际扫描验收尚未全部通过，故不要提交第一阶段：** IMG2、IMG3、IMG4、IMG5 的全帧
count/sum/order 均匹配；IMG0 的实际扫描稳定为 sum=`640c162a`、hash=`07818cb2`，golden 应为
sum=`640c26ce`、hash=`0d0dee96`。12 次扫描和 P→N 重载后仍是相同差异，不是网页缓存或媒体 D
比对错误。已用现有媒体 MAC X 探针在正式 IMG0 装载后、D 之前抓到实际 END_IMAGE：
目标 `.2`，frame_id=16，正式发送累加和为正确的 `640c26ce`。因此需继续审计显示端输入 RAM／
补黑／写 FIFO／SDRAM 读写，不能仅凭 D 正确就交付，也不要未经验证归因于时序。

原始证据在忽略目录 `boardtest/captures/variable_frame_stage1/`，包括
`img0_formal_end.bin`、`real_pixels_pair.log`、`sticky_audio_before.log` 与 `sticky_audio_after.log`。
实际扫描验收主脚本已输出四张 PASS，IMG0 失败；尚未有完整六张成功 JSON。

### 19.3 多窗口独立模块准备（未集成产品）

几何、双线性缩小、槽位扫描寻址、槽位写寻址均已写入工作区，尚未加入正式 TD 源列表。
`make view-geometry view-bilinear view-scan-address view-write-address` 通过。
几何用一个 32-cycle 串行除法器复用三次运算；缩小器用两行 RAM、RGB565 Q8 分离插值、
保留中间小数、最后统一舍入。9 个连续图像用例不复位，覆盖全图缩小、窄图、单像素轴、奇数
尾字、截断和反压。读地址用例遍历 460800 字；多窗突发剩余量不跨 320 字窗口行。
独立综合几何与缩小器为 1277 LUT / 581 FF / 8 BRAM9K / 9 DSP，不能当整机增量或验收。
布局协议、窗口管理、读写集成及网页互锁仍待实施。

已在该模块冻结的数学约定：

- 目标尺寸等比例向下取整，至少 1 像素，不放大；左右 640×720、四格 640×360。
- 左边距 floor；由于源流自底向上，底边距取 ceil，使 HDMI 上边距仍为 floor。
- 双线性采样坐标采用 Q16、首末端点对齐；目标轴大于 1 时 step=floor((src−1)×65536/(dst−1))。
  缩小器将最后一个目的坐标显式钳到源末端，避免累计截断漂移。
- 目标轴仅 1 像素时取源中心 `(src−1)/2`，保持 Q16 分数。

继续顺序：收口上面的实际 SDRAM 差异 → 恢复产品 bit、文档与第一阶段本地提交 → 缩小器及
双图/四图/按窗黑屏更新 → 权威状态、前端互锁及仲裁审计 → 第二次（必要时第三次）本地提交。
保持全部既有仿真，不推送，不因阶段验证的问题自行停止整个已授权任务。

### 19.4 第一阶段验收完成（2026-10-22 20:04）

早期摘要失配之后，又以定向仿真复现并修复两处整包生命周期问题：

1. 显示 `media_tx_mux` 在应用末字后直接暴露下一请求长度；UDP 栈此时仍可能使用旧包字段。
   `tb_media_tx_mux_lifetime` 在修复前得到 11、应为 16。现于首个有效字节锁存长度，保持到
   下一次真实 grant。owner 同样保持；隔离诊断工程的回复目的地也跟随 owner 保持。
2. 媒体 `media_udp_route` 用实时控制类型选目的地，排队 SET 可把正在发 PC D 的 DATA
   重定向显示板。扩展原 route 用例复现，现按真实 grant 锁存媒体/控制拥有者及目的地址。
   控制包长度在 ACK 后首有效拍锁存；媒体长度在 grant 锁存。源包格式没有因此改变。

修复后隔离诊断 bit SHA：
`481062F006425CECFA0C8624CA74315FA593104324E562440CF6419F334A7EAB`。
连续 7 次切图覆盖全部 6 张 BMP：IMG2→IMG3→IMG4→IMG5→IMG0→IMG1→IMG2。
每次媒体 D 原始字节与独立 golden 全同、缺口零；显示端四个边界均统计完整 460800 字：
UDP 补黑输出、生产写 FIFO 输入、实际 Appwrite、实际 SDRAM 视频扫描。
所有边界的 32-bit 累加和及 `h=(h*33)^word` 顺序摘要均匹配各自独立 golden；
顺序摘要用于定位，不等同逐字节读回或密码学证明。
证据：`boardtest/captures/variable_frame_stage1/route_fixed_acceptance.json`（忽略目录）。

真实 native SD/FAT 源仿真另遍历 6 BMP / 4 配对 WAV，并逐字节检查四份 PCM：
IMG1/2/5 各 720000 样本，IMG0 为 480000；另外两张为静音事务。
源级日志为 `full_sd_pcm.log`。实板本轮提交握手和静音事务成功；HDMI 观感、OSD 字形及听感
仍须人工确认，自动摘要覆盖的是像素存储/扫描通路。没有把 D 正确作为 SDRAM 正确的替代证据。

随后重新综合正式显示工程，恢复无探针产品 bit，并对 IMG3、IMG4 再作切图提交和 D 冒烟检查。
正式源码列表不包含诊断模块。正式 bit：

| 板卡 | SHA-256 | LUT / FF | BRAM9K / BRAM32K / DSP | setup / hold WNS |
| --- | --- | --- | --- | --- |
| 显示 | `2D916C8F41450BACB573F8B921743E766E567EB6BD41ACABEFA7FFD6F3C7B087` | 14990 / 10636 | 37 / 13 / 12 | −5.699 / −3.056 ns |
| 媒体 | `602F7C8E37E94F90FDE1F2E5D40BC687E20635EC17376867DBAAFE0FEC9E52BE` | 14739 / 9734 | 23 / 2 / 5 | −3.978 / −2.867 ns |

CLI 均由 `program_sram.ps1` 成功写入对应 cable 的 SRAM，无 UAC。
已知厂商 IP 时序违例仍在；没有宣称本轮收敛时序。
下一步：第一阶段本地提交后继续多窗口集成与完整仲裁测试；不要误认为整个计划已完成。

### 19.5 第二阶段正在集成（从这里继续，不能当已上板完成）

第一阶段现已本地提交为 `2c930d0`，没有推送；剩余最多两次阶段提交。
两板当前 SRAM 仍为 19.4 的正式单图产品 bit。后续多窗口修改尚未下载、不得声称实板通过。

已接入工作区的生产 RTL：

- 显示：`view_image_pipeline`（双线性 + 动态窗口补黑）；`view_session_manager` 管准备、
  首次整页暂存、黑窗原地更新、重试及提交；`view_video_config` 在输入 VS 安装配置。
  `frame_fifo_read/write` 增加 `VIEW_ENABLE`：产品启用、历史独立测试保持默认旧接口行为。
  读引擎按槽位映射、无效窗生成黑字，多窗突发不跨 320 字行；新 epoch 只在旧突发返回排空、
  S_ACK 清 FIFO 后确认。写引擎按窗翻转，音频继续原来的顺序写。
- manager 在 UDP 域；配置 mailbox 的 epoch 经 video VS 安装后再由实际读引擎回传，
  回传前绝不发原地写准备 ACK。原始宽高保留作焦点 OSD；CV 之后/UI 之前再次遮黑无效窗。
- 多窗 writer 只回“图像写完”内部事件，不装载 WAV；manager 生成 RESULT=3/2。单图仍沿用
  原 writer 的 WAV/转场逻辑，最终 2 经过 manager 的新配置/排空确认后发出。
  `media_audio_playback` 保留 pair_off 期间的新源启动待办，解决返回单图的提交前静音窗口。
- 媒体：`media_view_scheduler` 先准备再启动源读取，编排整页多图及按窗 N/P；
  `media_image_tx.EXTERNAL_SCHEDULE=1` 只执行明确 job，原独立用例默认旧调度；多窗不发音频包。
  `media_packet_arbiter` 在正式数据与视图控制/PC 状态之间整包仲裁，目的地保持到下一拥有者。
- `media_control_core` 增加布局键 ASCII 6/7/8；忙时拒绝图像/D/布局。UART 小队列为每条命令
  记录“到达时是否忙”，防止忙时命令等到空闲才生效。USB `uart_link.TX_BYTES=17` 支持 A7+16
  字节状态，`media_usb_view_tx` 避免与旧 8 字节 ACK 的寄存 ready/request 竞争；蓝牙仍为 8 字节。

当前新增的控制字节约定（需在正式协议文档补齐）：

- 0x0049：V1 大端包头、8-byte body：seq/action/layout/preferred-window/gen:u16LE/reserved:u16=0。
  action 0=布局或当前图、1=N、2=P、3=取消、4=PC D 保留、5=D 完成释放。
  preferred FF=按当前光标，FE=使用本地触摸命令发生时锁定窗口，否则 0–3。
- 0x004A：8-byte body：seq/result/window/layout/gen:u16LE/base-index/valid-mask。
  result 0=准备完成，1=忙，2=非法，3=代次过期。首次进入多窗 window=0，后续依序装入。
- 本地触摸 N/P 用 V1 `0x6E/0x70` 私有小写命令转发，媒体再按 FE 准备；公开 N/P 仍为大写。
- 0x0048：16-byte body：seq/gen:u16LE/layout/busy/focus/mask/indices[4]/width:u16LE/height:u16LE/result。
  媒体转发 PC V1 type=0003、LEN=16；USB 为 A7 + body。48 长度 1 或原 42 状态查询均触发新状态。

已经通过的定向仿真：

- `view-framepath`：真实生产异步 FIFO，三种模式全部 App 地址/数据与视频字验证；隐藏窗黑字；
  多窗突发不跨 320 字行。尚需补充“旧突发进行中切换 epoch”的专门压力用例。
- `view-session`：准备/排空屏障、整页原子提交、按窗失败重试、非法切换/过时代次、本地焦点锁定、D 保留。
- `view-control-path`：两板真实 PREPARE/STATUS/RESULT 序列化/解析，源/写完成为有界行为模型；
  覆盖开机、双图/四图、独立 N/P、回环、忙时不排队、触摸锁定、D 焦点选择。它不是像素整机验收。
- `view-image-pipeline`：与 `view-bilinear` 共用独立四角 golden，以 `PIPELINE=1` 加入完整窗口补黑，
  9 组连续源图、奇数尾字/单像素轴/截断/源和目标反压，所有输出字逐像素正确。
- `view-usb`：真实 TX 串行解码，8/17/8 字节完整性及 control ready 已授予时新 VIEW 竞争。
- 返回单图音频源在 pair_off 时提交的用例通过；Web `test_view_status.py`、原 D 和 JS 渲染用例通过。

Web 已加入布局按钮、权威 VIEW_STATUS、忙时灰显与 S 恢复；HTTP 成功/旧 ACK 不解锁。
仍需真实浏览器交互检查及板级联调，特别是 FPGA 状态与前端锁定/恢复一致性。

首轮综合（当前源码之后又有 USB 等修补，故这些网表不能直接作为最终 bit）：
显示 17120 LUT / 12473 FF / 45 BRAM9K / 13 BRAM32K / 21 DSP；媒体 14607 LUT / 10578 FF。
布局布线尚未进行。TD `.al` 与 syn `.prj` 已登记 9 个显示 view 模块、媒体 scheduler/packet arbiter；
**新加的 `media_usb_view_tx.v` 还必须登记到媒体 `.al`/syn `.prj` 后再重新综合。**

接下来：补齐 USB 以及新端口的工程/历史测试接线 → 新调度器执行多图无音频的定向仿真，
真实突发中隐藏排空/设置与 DATA 交错/忙时命令标记测试 → 两板重新综合及 P&R → 下载并用
隔离显示扫描探针对照独立多窗 golden；同时验证 D 焦点与返回单图音频提交。
保留原有测试；未完成实板验收前不作第二阶段提交。不因当前模块通过就结束整个任务。


### 19.6 第二阶段实板调试现场（2026-10-23 01:40，优先读本节）

19.5 是较早快照；以下覆盖其中“尚未下载/工程列表未补齐”等旧状态。
第一阶段已提交 2c930d0，第二阶段仍未通过实板验收、未提交。

- 双线性串行共享 RGB/轴计算、原生 DSP 输入/输出寄存器、几何除法器收窄、
  manager 元数据按 bank 存 BRAM、协议 RX 去重复清零/共用包校验累计器均已实现并通过定向仿真。
  新增 display_levels_rgb 用闲置 DSP 精确复现原亮度/对比度公式，65536 组合逐值相同。
  当前正式显示候选完整 P&R 成功：16911 LUT、12046 FF、47 BRAM9K、13 BRAM32K、18 DSP，
  4829/4900 MSlice；setup -7.791ns / hold -2.935ns。不是已验收产品。
- 资源瓶颈是 MSlice 打包（98.6%），不能只看 LUT 比例；全四边界诊断构建仍超限 5094 MSlice。
  正在用隔离 CV bypass + Appwrite/scan 两边界探针减小诊断体积，生产 CV 源码不删除。
- 当前 cable0 是隔离 scan-only / CV bypass / test-cursor bit
  2C2DC610BA219A9C9C0A436A701E15F1297D89F6E92BACEA9012FCE363BFD55E。
  私有 004B 只在诊断复制顶层里注入 manager 焦点，不进入生产源列表。
- 用户实见撕裂。实际 SDRAM scan 已证明有像素差异：IMG1 连续 8 帧固定为
  count=460800, sum=fb062ffd, hash=589e3bbb；golden 为 c5022484 / 80940754。
  新装 IMG2、IMG3 也不符，但各自源 D 与 BMP 完全一致、缺口零。
  因此不可宣称“只有 HDMI 观感”或仅凭源 D 判定显示正确。
  先比 Appwrite 与 scan，再决定上游像素/写地址/读地址哪条路继续定位。
- 当前 cable1 仍为 00:33 成功的 FCB697539CBA681FF49F588C7B2ADEE5273F8929ABC0FF2C8EF05FA88BFFD3CC。
  它包含 view 调度，但不含最新多窗 500us 包间隔/RESULT3 不提交等小修。
  最新媒体源已有这些修复；P&R 在 hold 修补后剩两条冲突网失败，同名旧 bit 并未删除。
  不能将该旧 bit 当成新源码产物。正在按 TD 有效参数 route effort high 重跑。
- program_sram.ps1 已增加默认产物新鲜度检查：bit 比 place/route/bitgen 任一 begin 标记旧就拒绝，
  防止 TD 退出码 0、旧 bit 残留造成误烧。显式 CandidateBit 用于已知 A/B/隔离诊断。
  无 UAC，仍需宿主非沙箱 USB 访问；cable0 显示、cable1 媒体，SRAM only。
- /api/status.view 权威状态、USB A7、前端布局和忙互锁、两板 TD 源列表都已补齐。
  app 已重启加载工作区；网络显式源地址 192.168.137.1 的两板 ping 可通。
  中途 IMG4 装载失败，页面通过 S 回到 idle/result1；还需一并收口。

定向 view-framepath 已补“旧目标窗突发进行中隐藏”，证明 ACK 前旧返回排空；
现有测试仍是存储行为模型，不能替代上述真实 SDRAM scan 失败。
下一步先修实际像素差异，再全覆盖双窗/四窗/独立切图/D/返回单图音频，恢复无探针产品 bit，
最后更新协议文档及验收记录再做第二阶段提交。最多还可用两次提交，不推送。


### 19.7 用户暂停板级供电，转为优先资源重构（2026-10-23，当前执行入口）

用户确认将关闭两块板子，授权更积极地离线开发资源优化；资源占用回落后再重新上电，
继续撕裂 debug 和多窗口功能验收。**现在不再 ping/下载/运行实板脚本，也不请求用户协助。**
继续仿真、CLI 综合/P&R、记录资源与时序；候选不得标成实板稳定，不自行提交半成品。
仍留在 main，不推送。完整功能计划没有取消；先优化，再回到像素/仲裁验收。

版本状态：main 最新提交仍是阶段一 2c930d0；所有第二阶段 RTL、前端、测试、报告都在工作区。
阶段一已验收内容不能整体回退。保留全部历史仿真。阶段提交总上限仍按原约定最多三次。

断电前最后明确下载：

- cable0 显示：scan-only/CV bypass/test-cursor 隔离诊断 bit
  2C2DC610BA219A9C9C0A436A701E15F1297D89F6E92BACEA9012FCE363BFD55E，
  不等于最新产品 bit。真实单图 SDRAM scan 不匹配：IMG1/IMG2/IMG3 均出现稳定摘要差异；
  源 D 与对应 BMP 全同。IMG4 的一次装载失败后回 idle/result1。用户目视撕裂待修。
- cable1 媒体：最新正式候选 426E8623CD1D2F9FEE2413405B1F11769E1014B724F66991EE648585D721C223，
  01:50 通过 program_sram.ps1 写入 SRAM。包含多窗 500us 包间隔、RESULT3 不作为提交、
  关闭 MAC_CAPTURE；15544 LUT / 10689 FF / 20 BRAM9K / 2 BRAM32K / 5 DSP。
  默认布线曾重复残余两条冲突；本次使用 TD 有效参数 place pr_strategy 2、route effort high 完成。
  此 bit 下载后还没有全功能板测；断电后 SRAM 丢失，恢复时必须明确选择将要验证的候选。

资源重构进度：

1. 显示 packet 元数据 union 已实现并通过协议、1280/504 两种整帧、图音及多窗口握手仿真。
   原 packet_frame_id/sequence/index/flags/total/sample/checksum 等互斥字段现共用128-bit wire body；
   实际源尺寸上界/坏长度/坏校验等保护保留。
2. 试过 TX 移位回复，但门级 LUT/FF 均没有收益，已仅撤回该候选，恢复原 packet TX；
   不要把这次实验写成已保留的优化。带 union+TX 实验的产品候选 P&R 成功，约4784 MSlice，
   只是过渡量化结果，当前源码已经继续改变。
3. 正在实现更实质的缓存合并：写事务留在 UDP 125MHz 域，移除中间 frame/audio async FIFO，
   复用 frame_read_write 最后的 UDP->SDRAM FIFO；音频消费仍保留 sd_card_clk。
   media_transaction_writer 新参数 DIRECT_STREAM=1（生产顶层启用，历史默认0）；
   frame_read_write 新参数 STREAM_CLOCK=1 和 stream_clk（顶层 eth_app_clk）。
   legacy write_clk 仍作音频 FIFO 消费时钟；write_ready 只跟新 producer_clk。
   writer 对 mem 写 ACK 新加两拍同步；完成/转场继续原来的 toggle CDC。
   当前代码刚落盘，**还没跑新 DIRECT_STREAM 仿真、没综合此重构**。必须先验证再保留。
4. 两个1280x16缩小行 RAM 的属性已试改 bram_32k，候选未量化；预期是2 BRAM32K换8 BRAM9K，
   不是保证结果，实际报告确认；若形成新短板/无收益可单独撤回。
5. display_levels_rgb 的3个DSP精确增益替代、串行 bilinear 原生DSP输入/输出寄存器及其定向测试
   是较早已验证仿真/综合的工作区内容，仍保留；不是另开分支或提交。

缓存合并尚需检查：

- 新参数默认0保持历史接口行为；所有 frame_read_write 历史实例已补 stream_clk=0。
- 当前生产 writer.write_clk=eth_app_clk，frame_read_write.stream_clk=eth_app_clk，
  frame_read_write.write_clk 仍为 sd_card_clk。检查两个路径确实只跨一次域。
- 顶层 auto_play_w 已随 writer 改为 eth_app_clk 域采 frame_commit_pulse；消费者原已有同步。
- 隔离 digest 构建器 producer_clk 原硬写 sd_card_clk；DIRECT_STREAM 后必须随真实 writer 改，
  否则8ns write_en 会被100MHz误采，导致假失配。板测恢复前修改诊断构建器。
- 仿真需新增125MHz直连写事务的图像、PCM、反压、截断补黑、切换收尾用例；
  再用真实生产 FIFO 验证独立音频消费时钟和 mem100MHz 读写。
- 检查当前仍后台运行的 TD 构建；它们来自变更前网表，只能作对比，不能误烧当最新源码。
  日志 view_display_union_shift_phy.log、view_write_scan_strategy2_phy.log 等在 ignored captures 内。
  禁止仅凭旧同名 bit/TD exit0 报成功；program_sram 的新鲜度保护必须保留。

继续顺序：完成 DIRECT_STREAM 等价仿真 → 重新综合量化资源/相关时钟路径 → 单独检查其他重复
缓存/宽寄存器/共享运算候选，逐项保留有证据的收益 → 更新离线候选清单 → 用户重新上电后
先实际 SDRAM 边界定位撕裂，再完成双窗/四窗/独立切图/音频与前端验收。


### 19.8 单级生产写 FIFO 仿真完成，综合进行中（2026-10-23）

在两板关闭期间完成新的 DIRECT_STREAM 候选：显示协议解析、图像缩放/补黑和事务 writer
同在 UDP 125MHz 域；移除 writer 内两条 512×32 async BRAM FIFO，复用 `frame_read_write`
最终 FIFO 作为唯一 producer→SDRAM CDC。writer 的 `write_req_ack` 加两拍同步；
SDRAM FIFO 写域改为显式 `stream_clk=eth_app_clk`；音频 read FIFO/播放域继续 `sd_card_clk`。
顶层 `auto_play_w` 也留在 UDP 域，因为 `frame_commit_pulse` 现在本来就在该域。
历史验证默认参数 `DIRECT_STREAM=0` / `STREAM_CLOCK=0` 保持旧结构。

以下直接模式 Verilator 验收全部通过，日志 `boardtest/captures/variable_frame_stage1/direct_stream_tests.log`：

- writer 图像与5样本 PCM，先图像完成、再 PCM、提交字段与第一/第二音频字节顺序。
- 实际 parser→pad→writer→display TX，图像成功/拒绝及音频 checksum reason 回路。
- 504×720 小图居中补黑、完整460800字输出、RESULT0/RESULT2、DPI式全量图写模型。
- `frame_read_write` 真异步写/读 FIFO：UDP125写时钟、独立音频消费者时钟、mem100读写；
  完整单图/双图/四图扫描、隐藏窗读排空、黑字生成、地址/data检查及突发边界均通过。
- 以上是 Verilator 行为模型检查，仍不能证明厂商 SDRAM IP 的板上访问和 HDMI 显示正确。

显示板全量当前源码 SYN/P&R 正在运行（尚未结束）。该候选还加入行缓存从 BRAM9K 移到 BRAM32K，
故以最后成功 gate/phy 报告比较 BRAM9K / BRAM32K / LUT / MSlice 和时序。过渡之前的显示正式
P&R是16911 LUT、12046 FF、47 BRAM9K、13 BRAM32K、18 DSP、4829/4900 MSlice，
WNS−7.791ns/hold−2.935ns；这不是新 DIRECT_STREAM 候选的结果。

移位式 `media_display_tx` 已放弃并恢复原实现（量化没收益）。保留了共用包字段寄存器，
协议回归及 full-frame 1280/504 和普通视图握手测试均通过；最终是否保留看这一轮综合的
component/hierarchy结果，不能只用单独字段计数推断节省。


### 19.9 直连写入 SYN/P&R 量化中（2026-10-23 02:40）

此前 19.7/19.8 的“DIRECT_STREAM 还没有跑仿真”文字已过期，以本节为准。
此方案已完成以下离线仿真：writer图像+PCM、parser/pad/拒绝与audio checksum reason、
504×720补黑整帧、1280×720全帧、真实读写FIFO三种布局全画面扫描。
1280与504均写460800字，图像结果先0接受后2提交；真实memory-model读回逐字一致。
`direct_stream_tests.log`及`direct_1280.log`留在captures忽略目录。

最新全量显示SYN：16247 LUT / 11863 FF / 39 BRAM9K / 11 BRAM32K / 18 DSP。
相对之前完整多窗口正式候选P&R (16911 LUT /12046 FF /47 BRAM9K /13 BRAM32K /18DSP)：
LUT少664、FF少183，BRAM9K少8，BRAM32K少2。层级writer从约723 LUT降到63 LUT左右。
行缓存BRAM32K迁移和两条512×32 bridge FIFO移除都已包含。

布局完成报4804/4900 MSlice（之前4829/4900）；当前换布局后有一条网络布线冲突，正在routing/ECO。
布线早期timing更新setup WNS约−6.03 ns、hold−2.935 ns；之前完整候选final为−7.791/−2.935 ns。
最终route没结束前MSlice/WNS/bit SHA都还未确认。该方案尚未烧录实板，不能作为正式稳定候选。
实时状态/日志：`boardtest/captures/variable_frame_stage1/view_direct_stream_phy.log`（ignored）。
用户已经关掉两板，所以本阶段完成后只继续离线仿真/综合，不进行下载。

如果普通布局持续残留网络冲突，下一轮考虑从同一最新gate网表重新布局，设置已从TD参数查询确认有效的
`place pr_strategy 2`（并按需 route effort high），比较能否路由成功；不要改RTL来掩盖放置冲突。
若替代布局不能route，再保留SYN/功能仿真结论，不能报告“完整P&R通过”。
当前工作区仍有直接candidate未提交变更；撕裂的实板扫描失败仍是板重新上电后的优先定位点。


### 19.10 首轮完整路由报告与第二种布局（2026-10-23 02:40）

SYN/P&R 的首轮 DIRECT_STREAM 候选完成综合和布局，但默认 `pr_strategy=1` 末尾 route/eco 留有一条
原语理位置冲突：`u_gt911_trackpad/cursor_mailbox_x_b_n` 与 `u_spectrum_dft/mux67_syn_2863`
在 `(x12y46_local3)`。TD 报错为 `RUN-8102 Incremental route failed`，所以该次没有生成新的
完整 PR 数据库/时序终态或可下载 bit；旧同名 bit 与旧 final_timing 不得用于新 candidate。
路由前布局面积4804 MSlice，SYN LUT16247/FF11863/BRAM9K39/BRAM32K11/DSP18；
P&R中间setup WNS -6.025ns (route pre-ECO)。它不是最终路径收敛数字。

第二次完整流程正对同一最新门级网表尝试 `place pr_strategy 2` 与 route high effort，日志：
`boardtest/captures/variable_frame_stage1/view_direct_stream_strategy2_phy.log`。
如果完成，记录其真实资源、setup/hold WNS、route违例、bit时间/SHA和 CLI exit检查；
若路由仍失败，保留可复现证据并把该候选留在工作区待进一步离线布局研究，板不重新上电。


### 19.11 Strategy 2 复跑结果（2026-10-23 03:01）

同一最新 gate 网表以 `place pr_strategy 2` 重新完整放置/路由后仍在固定同一位置失败：
`(x12y46_local3)` 上的 `u_gt911_trackpad/cursor_mailbox_x_b_n` 与
`u_spectrum_dft/mux67_syn_2863` 冲突；TD 最终报 `RUN-8102 Incremental route failed`，
没有 bitgen，也没有新的产品 bit。流程在 setup timing 上约 -6.025ns、hold -2.935ns，但不等于最终route timing。
布局仍4808 MSlice。重建 P&R 中间文件覆盖了 layout candidate 的 place DB；
working source/gate area 16247 LUT / 11863FF /39BRAM9K /11BRAM32K/18DSP 保留。
下一次使用确认有效的 `place pr_strategy 3`，route 完再判断是否能消除同一局部布线冲突。
若3也失败，结束反复切换 P&R 参数，转入 RTL fanout/register placement 资源优化或保留此前完整P&R版本，
并明确报告没有可交付的新 bit；不要继续盲目烧板。


### 19.12 Strategy 3 P&R conclusion and route-local RTL candidate (2026-10-23 03:17)

第三轮 `place pr_strategy 3` 完整走到 bitgen，消除了Route error，但最终 setup WNS=-10.351ns、hold=-3.200ns，
相对之前正式候选 -7.791/-2.935ns 明显变差，故不能作为保留的资源优化设置，也没有实板通过。
这轮仅证明同一个RTL换布局能route，未烧写，现成同名bit SHA为诊断构建，不可用于板级。
相同 gate area仍16247 LUT/11863FF/39 BRAM9K/11 BRAM32K/18DSP、布局4808MSlice；
最终routing策略不能仅拿这组物理时序不合格的candidate当可交付。

Strategy1/2冲突准确位置仍为 `(x12y46_local3)`，网是
`u_gt911_trackpad/cursor_mailbox_x_b_n` 和 `u_spectrum_dft/mux67_syn_2863`；不是像素算法或 SDRAM地址冲突。
离线考虑的下一项 RTL 只把GT911的稳定坐标邮箱副本拆成独立显示/manager分支，减少跨模块共扇出，
保持 mailbox 更新时点/值和现有同步协议；它不是功能精简。如实现需增加寄存器，先保持output bus严格等价，
Verilator验证原 GT911游标/滑动行为、启动、ACK间稳定，再只尝试一次完整P&R。
倘若路径代价或拥塞更差就回滚该小项；不要再连续试不受限的 place 参数。
两板仍断电，候选不得下载或称稳定。优先保持新综合改善和未提交功能的完整性。


### 19.13 Bilinear phase decode pipelined: full P&R candidate (2026-10-23 03:40)

Timing report implicated the path from `view_scale_geometry.dest_height` through the current 15-state FSM
branch mux and Y interpolation inputs. `view_bilinear_shrink` now registers the upcoming arithmetic `operation`
on transitions into READ1 / HORIZONTAL1 / VERTICAL / next-channel HORIZONTAL; the DSP operand/fraction mux
uses this 2-bit registered phase instead of recomputing from FSM state each channel. The per-pixel formula,
rounding, row order, frame-control latency, ready/backpressure protocol, and arithmetic results are unchanged.

Verilator `make view-bilinear view-image-pipeline` passed: all 9 consecutive full-source goldens, including
1280×720→640×360, 571×720, 504×720, no-resize, narrow/degenerate axes, truncation, source/sink backpressure,
and complete pad pipeline, are exact RGB565. Log is
`boardtest/captures/variable_frame_stage1/bilinear_phase_mux_tests.log`.

Current unboardtested product candidate completed strategy-1 full SYN/P&R and bitgen:

- SYN `#lut` 16313, FF 11864, BRAM9K 39, BRAM32K 11, DSP 18.
- Routed `#lut` 16864, FF 11824, BRAM9K 39, BRAM32K 11, DSP18; placement 4784/4900 MSlice.
- Setup WNS -6.130ns, hold WNS -3.042ns. Compared with previous full multiview product candidate 16911 LUT,
  4829 MSlice, -7.791/-2.935ns: LUT -47 after placement, MSlice -45, setup improves 1.661ns, hold -0.107ns.
- Candidate bit SHA256 `31431CC6D8C15B7EEE3692243A5144E9DC80118B48462F72278443EA737BB7C2`.
  It was generated into the run folder and has **not been downloaded**; two boards remain off.
- Critical setup endpoint moved from `mix_b` to FSM `state_reg[0]`, slack -6.057ns; the two scaling coordinate paths
  are next at -5.658/-5.573ns. Further optimization, if it proves worth the risk, should pipeline frame-invariant
  geometry or separate the destination-window control, not alter SDRAM pixel addresses based on speculation.

The third P&R strategy bit from 19.12 remains a timing-poor -10.351ns candidate and was superseded by this default
strategy-1 image; only the new SHA above represents the latest successfully routed+bit-generated source snapshot.
Until board scan checks pass after power is restored, no candidate is product-verified or committed.


### 19.14 Interpolator operand phase register P&R complete (2026-10-23 03:40)

Following the routed strategy-1 candidate that used the shared frame writer but still had the old FSM decode
on every RGB operation, `view_bilinear_shrink` now registers `operation` at READ1/STORE transitions.
This breaks the state decode from geometry/destination-height into the multiplier operand select.

- `make view-bilinear view-image-pipeline` passed all exact RGB565 goldens, 9 backpressure/degenerate/truncated cases.
- Full strategy-1 SYN/P&R/bitgen completed without routing conflicts.
- Latest candidate bit SHA256: `31431CC6D8C15B7EEE3692243A5144E9DC80118B48462F72278443EA737BB7C2`.
- SYN area: 16313 LUT-equivalent, 11864 FF, BRAM9K39/BRAM32K11, DSP18.
  Routed area: 16864 LUT-equivalent, 11824 FF, BRAM9K39/BRAM32K11, DSP18, 4784/4900 MSlice.
- Final setup/hold WNS: -6.130ns / -3.042ns. Compared with pre-phase-reg full product P&R,
  setup improves 1.661ns and MSlice reduces45; hold worsens0.107ns.
  P&R is complete; the candidate has not been downloaded because the boards are off.

This makes the workspace's newest bit technically route-complete, but it does not close the user-visible image-torn
issue. The existing actual SDRAM scan failure must be reproduced and fixed after power returns. Do not download this
bit during the optimization-only/offline phase.


### 19.15 Resource-optimization checkpoint (2026-10-23)

The current workspace was saved on branch `fix/multiview-resource-optimization`, based on
`dual-V2.1` / commit `2c930d0`. This is a development checkpoint, not a board-verified release.
The boards remain powered off.

The current checked-in TD P&R reports show:

| Board | LUT | FF | BRAM9K | BRAM32K | DSP | Final setup / hold WNS |
|---|---:|---:|---:|---:|---:|---:|
| Display / cable0 | 16,803 / 19,600 (85.73%) | 11,830 / 19,600 | 39 / 64 | 11 / 16 | 18 / 29 | -6.130 ns / -3.042 ns |
| Media / cable1 | 15,544 / 19,600 (79.31%) | 10,689 / 19,600 | 20 / 64 | 2 / 16 | 5 / 29 | -3.947 ns / -3.188 ns |

These values are per-board and are not combined. The display candidate bit SHA256 is
`31431CC6D8C15B7EEE3692243A5144E9DC80118B48462F72278443EA737BB7C2`; the media candidate bit SHA256 is
`426E8623CD1D2F9FEE2413405B1F11769E1014B724F66991EE648585D721C223`. Neither is board-verified.

The checkpoint’s focused verification passed: geometry and bilinear RGB565 goldens, full image pipeline,
scan/write address bounds, real asynchronous frame FIFOs, black-window drain, session manager, media/display
control path, USB view status, image jobs, command admission, and direct-stream image/audio write tests. The
web-console `VIEW_STATUS` parser/API test also passed with the local Windows Python environment. WSL was
initially blocked by the ordinary sandbox and the same Verilator run passed after using the already authorized
local execution route. Existing Verilator missing-pin warnings in legacy FIFO models remain informational.

Next, reduce resource use on this branch one RTL candidate at a time. Preserve the current reports and source
as the baseline, compare exact per-board LUT/FF/BRAM/DSP and setup/hold after each synthesis/P&R, and keep a
candidate only when the functional tests remain green. No programming is part of the offline optimization step.


### 19.16 Display-only resource pass 1: fixed-topology UDP/ARP stack

User-approved scope for this optimization branch:

- Only optimize the display board; do not increase media-board use.
- Target at least 2,000–3,000 fewer display LUTs through a combination of local RTL,
  redundant-path cleanup, architecture changes, and feature tradeoffs.
- Preserve Ethernet application control. The user permits dropping ping only when the
  resource return is substantial. D snapshot is handled on the media board and cannot
  save display-board resources. Other product features remain preserved unless the user
  later approves a specific cut.

The display board's encrypted vendor UDP/IP stack was replaced in this candidate with
`display_udp_lite`: fixed local/media IP and MAC addresses, ARP reply, IPv4/UDP RX/TX, and
the existing TEMAC client byte-stream interface. ICMP echo is omitted; the media board
is unchanged and retains its vendor stack and ping behavior. The display application
still receives media packets on UDP port 1 and returns display results/status to the
fixed media peer on UDP port 1. The receive path accepts IPv4 IHL=5, unfragmented UDP to
the configured local port, checks the IPv4 header checksum, and forwards application
payload for the existing media protocol length/checksum validation. The transmit path
uses a zero IPv4 UDP checksum, which [RFC 768](https://www.rfc-editor.org/rfc/rfc768.html)
permits, although [RFC 8085](https://www.rfc-editor.org/rfc/rfc8085.html) recommends using
the checksum. This candidate relies on TEMAC frame CRC plus the existing image-data
checksum; small control messages rely on the frame CRC.

The candidate passed `make -C boardtest display-udp-lite`, including ARP request/reply,
IPv4 checksum, UDP port filtering, malformed checksum rejection, ICMP omission, the
real `media_tx_mux` handshake, TEMAC active-low backpressure, 1,020-byte maximum media UDP
payload exactness, and the maximum 24-byte display response. The full display design
completed TD SYN/P&R/bitgen; it has not been downloaded or board-verified.

| Display resource | Checkpoint `d2b4566` | UDP-lite candidate | Change |
|---|---:|---:|---:|
| Gate LUT | 16,228 | 14,438 | -1,790 |
| Final P&R LUT | 16,803 | 14,998 | -1,805 |
| FF (P&R report) | 11,830 | 10,134 | -1,696 |
| BRAM9K | 39 | 37 | -2 |
| BRAM32K | 11 | 11 | 0 |
| DSP | 18 | 18 | 0 |
| Final setup WNS | -6.130 ns | -5.699 ns | +0.431 ns |
| Final hold WNS | -3.042 ns | -3.054 ns | -0.012 ns |

The encrypted stack's hierarchy row was 3,174 LE; the replacement row is 1,190 LE.
The display TD source lists no longer include the unused encrypted stack file; the media
board project and source remain untouched. The top-level gate LUT drop is smaller than
the hierarchy difference because TD reports count and pack logic differently. Final
setup improves by 0.431 ns and hold worsens by 0.012 ns. Candidate bit SHA-256:
`A2D9C8F3762038F78BFC982909465EAD421A264781094293C8783658C34C28B3`.
Do not download it during the offline optimization phase.

Remaining target after pass 1: about 195–1,195 LUTs to reach the requested 2,000–3,000
display LUT reduction. Pass 2 will continue with display-local RTL sharing and removal
of genuinely redundant logic; do not cut the other listed product features unless the
user approves them.


### 19.17 Display-only resource pass 2: disable unused EDID read trigger

The display output is fixed at 1280×720 / VIC 4. The top level does not consume the
HDMI transmitter wrapper's `O_edid_read_valid` or `O_edid_read_data`, and the timing
generator is not selected from monitor data. The startup pulse that initiated an EDID
read was therefore removed and `I_edid_read_trig` is tied low. The HDMI DDC pins and
transmitter wrapper remain connected; the change only disables the source-side EDID
read transaction. It does not change the generated video timing, pixel stream, audio,
or application control path. Monitors that depend on source EDID polling for mode
selection may behave differently; the current design always sends its fixed 720p mode.

TD completed SYN, placement, routing, timing analysis, and bit generation. The run
reports `route_flow.status` as complete. The final routed report still has the design's
existing negative setup/hold slack; relative to the preceding UDP-lite candidate, the
global setup WNS changed from -5.699 ns to -5.964 ns (-0.265 ns), and hold WNS changed
from -3.054 ns to -3.066 ns (-0.012 ns). Both changes are within the branch's 0.3 ns
candidate threshold, but this does not make the design timing-clean or board-verified.

| Display resource | UDP-lite baseline | EDID-read-disabled candidate | Change |
|---|---:|---:|---:|
| Gate LUT | 14,438 | 14,242 | -196 |
| Final P&R LUT | 14,998 | 14,775 | -223 |
| FF (P&R report) | 10,134 | 9,925 | -209 |
| BRAM9K | 37 | 35 | -2 |
| BRAM32K | 11 | 11 | 0 |
| DSP | 18 | 18 | 0 |
| Final setup WNS | -5.699 ns | -5.964 ns | -0.265 ns |
| Final hold WNS | -3.054 ns | -3.066 ns | -0.012 ns |

Relative to checkpoint `d2b4566`, the combined display reduction is 1,986 gate LUT and
2,028 final P&R LUT; BRAM9K is down by four. Candidate bit SHA-256:
`4DF6DFF66A5948C1C2BFE6070AF79A5E4E2875751BCB72CF165BAC8944911088`.
This candidate has not been downloaded or board-verified. Its source and TD reports are
saved in this optimization branch for offline review; no media-board source was changed.


### 19.18 Display-only resource pass 3: specialize ARP for the fixed media peer

The display board only exchanges application traffic with the fixed media board
(`192.168.137.3`, MAC `02:00:00:00:00:03`). The earlier UDP-lite implementation retained
the requester MAC/IP and multiple ARP header fields so it could construct a reply for
any host. The application does not use that generality. The receive parser now tracks
only match flags for the supported Ethernet/IPv4 ARP request, the fixed media sender,
and this board's target IP. The reply is emitted from the configured local MAC/IP to
the fixed media MAC/IP. Requests from another sender are ignored. This is a deliberate
fixed-topology boundary: direct ARP access to the display board from arbitrary PCs is
not supported; PC application traffic continues through the media board. UDP command,
image, result, and status payload handling is unchanged.

`make -C boardtest display-udp-lite` passed after the change. It verifies the fixed-peer
ARP reply, rejection of another host's ARP request, IPv4 checksum and UDP destination
port filtering, exact delivery of the maximum 1,020-byte media payload, malformed-frame
rejection, UDP response bytes, Ethernet padding, and the active-low TEMAC handshake.
The full TD SYN, placement, routing, final timing report, and bit generation completed.
This is still an offline candidate and has not been downloaded or board-verified.

| Display resource | EDID-disabled baseline | Fixed-peer ARP candidate | Change |
|---|---:|---:|---:|
| Gate LUT | 14,242 | 13,971 | -271 |
| Final P&R LUT | 14,775 | 14,473 | -302 |
| FF (P&R report) | 9,925 | 9,672 | -253 |
| BRAM9K | 35 | 35 | 0 |
| BRAM32K | 11 | 11 | 0 |
| DSP | 18 | 18 | 0 |
| Final setup WNS | -5.964 ns | -5.786 ns | +0.178 ns |
| Final hold WNS | -3.066 ns | -2.935 ns | +0.131 ns |

Relative to checkpoint `d2b4566`, the cumulative display reduction is 2,257 gate LUT and
2,330 final P&R LUT; BRAM9K is down by four. Candidate bit SHA-256:
`F35C80302C4E7F5A27590734D54C21487FA2D1E2E43565F4588D194E1E029AE9`.
The final routed design still has pre-existing negative setup and hold slack, so the
improved delta is not a timing-closure claim. No media-board RTL or behavior changed.
