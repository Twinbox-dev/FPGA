# 可变尺寸图像传输与固定多窗口：需求及架构交接

更新日期：2026-10-22。

**执行恢复入口：先读第 19 节的实际进度与现场。本轮已开始实施，尚未完成三个任务；遇到阶段问题继续定位，不要把提问或上下文压缩当作停止授权。**

本文冻结本轮用户已经确认的需求，整理实际源码、架构约束、验证与交付边界，供下一模型拟定执行计划并实施。本文不是功能完成报告，也不代替后续对具体协议和状态机的设计。

**最新决定优先：多窗口更新目标窗口时，先让该窗口变黑，再原地写入其槽位，成功后恢复显示。此决定替代此前“每窗活动／备用槽，保留旧图直到新图完成”的提案。** 单图双缓冲及转场不因此改变。

## 1. 开发基线与授权

- 仓库：`C:/Users/23506/Desktop/anlogic`。
- 当前分支：`main`。
- 基线提交：`459574b9b260002ff1cc31a3d9ef94ee9bfe6f69`，标题为“双板 V2 前端与 HC-08 命令文档”。
- 稳定标签：`dual-V2`。
- 本文落盘前工作区干净；当前没有实施本轮 RTL 或前后端功能。
- 用户将在后续启动执行前给两板上电，agent 自行仿真、CLI 综合、布局布线、SRAM 下载、脚本测试和调试。
- 显示板为 `cable0`，媒体板为 `cable1`。下载仅写 SRAM，不写 Flash。
- 本轮允许直接在 `main` 提交，不推送，不另开开发分支。
- 某个任务点真正完成、验证通过后才提交；总提交数不超过三次。
- 不依赖用户夜间看 HDMI、听音频、按按钮或观察数码管协助调试。
- 既有仿真代码全部保留；日常先跑相关定向测试，避免每次微调都全量回归。

## 2. 本轮任务与范围

### 2.1 任务一：可变尺寸传输、显示板补黑、分辨率 OSD

将固定传输完整 `1280×720` 图像改为传输源图实际尺寸的 RGB565 像素：

- 媒体板发送源宽高和实际像素数据，不再发送为居中显示生成的黑边。
- 显示板负责居中、补黑，HDMI 输出仍为 `1280×720`。
- **此阶段完全不考虑缩放。**
- 单图的方向、位置、黑边、配对 WAV 和转场行为与稳定版一致。
- 保存源图原始宽高，加入现有亮度／对比度／音量 OSD。
- 分辨率显示的是源文件尺寸，不是窗口尺寸或缩小后的尺寸。

### 2.2 任务二：固定多窗口、双线性缩小、交互限制

| 模式 | 屏幕划分 | 进入时的内容 |
| --- | --- | --- |
| 单图 | 全屏 1280×720 | 当前图片，保留原尺寸居中和黑边 |
| 双图 | 左右各 640×720 | 当前图及后续一张 BMP |
| 四图 | 四格各 640×360 | 当前图及后续三张 BMP |

- 固定布局，不做任意拖动、自由排列或任意窗口大小。
- 后续图片按既有 BMP 播放列表循环，WAV 不计入图片序列。
- 多窗口不播放音频，不读取、传送配对 WAV 内容。
- 不自动关闭频谱、字幕、OSD、光标等功能；需要关闭时由用户操作。
- 每个窗口独立保存图片索引，切图只改变鼠标所在窗口。
- 允许不同窗口显示同一张图片。
- 多窗口切图采用“目标窗口黑屏加载、原地更新”，详见第 6 节。
- 缩小采用双线性采样，等比例、居中补黑，不放大、不拉伸、不裁剪。
- 多窗口只直接切，不播放交叉溶解或柔边滑动。
- 单图保留既有音频、全部转场和其他功能。
- 双图和四图不能直接互切，必须先返回单图，详见第 7 节。

### 2.3 任务三：仲裁审计及必要修复

详细理清并验证：切图来源、目标窗口、控制入口、SD 与 D、UDP 包发送、SDRAM 读写与刷新、音频和转场读取、布局切换以及跨时钟提交。

审计应有源码、仿真或板级数据证据。不能只凭“暂时没有卡住”判定正确。遇到问题先比较稳定基线与新增逻辑，不能先把行为错误归因于厂商 IP 或历史时序违例。

### 2.4 本轮不做

- 视频播放、视频文件格式、帧率、视频来源和音画同步。
- 任何放大。
- 单独的“图片缩放”产品选项或媒体板侧缩放器。
- 每个窗口分别设置 CV。
- 与本任务无关的大规模资源重构。

缩小集中在显示板，作为多窗口渲染能力。未来视频如何复用留待以后讨论，不为视频预先扩展架构。

## 3. 已确认的窗口交互

### 3.1 独立图片索引与目标锁定

例如双图起初显示 IMG1、IMG2，鼠标在右窗时下一张后变为 IMG1、IMG3；左窗保持不变。每窗分别沿播放列表前后移动，允许重复图片。

网页、USB 串口、蓝牙、物理按键、GT911 切图及自动轮播都遵循同一目标选择规则。自动轮播只更新鼠标所在窗口，轮播周期和开关沿用既有配置。

目标窗口在一次操作被接受时锁定，加载过程中移动光标不能改变这次操作。鼠标位置在显示板，播放列表和读卡在媒体板，板间控制必须明确传递窗口身份，不能默认窗口 0 或中途重新使用变化后的鼠标位置。

对媒体板收到的外部切图，如何获取显示板的权威目标快照，需要在执行计划中确定。GT911 本地事件可直接锁定当时目标。无需持续传送全部光标坐标。

### 3.2 返回单图

- 返回鼠标所在窗口当前已提交图片。
- 重读该图片及配对 WAV，按单图规则提交并恢复播放。
- 多窗口静音不把用户音量配置改成 0；返回单图使用原音量档位。
- 切换布局时的“当前图”以接受命令时锁定的已提交图片为基准。
- 加载失败窗口如何用上次已提交索引重载恢复，需要在计划中明确，不能把未成功写完的请求索引当作已显示索引。

### 3.3 窗口编号及光标边界

建议协议从 0 编号、界面从 1 显示：

- 单图：0。
- 双图：0 左、1 右。
- 四图：0 左上、1 右上、2 左下、3 右下。

使用光标逻辑坐标，不使用角色贴图覆盖范围。明确并测试 `x=640` 属于右侧、`y=360` 属于下侧。

## 4. 图像效果、转场和叠加顺序

用户最后再次确认：**CV 图像效果统一作用于整屏，不按窗口分别改变。**

- 原图、灰度、二值化、Sobel、锐化、雪花共享一个全屏设置。
- 亮度、对比度也保持整屏统一。
- Sobel 和锐化自然会处理窗口交界处的邻域，不额外对每窗做独立边界处理。
- 字幕、OSD、频谱、光标沿用既有叠加顺序，不因多窗口复制模块。

现有源码顺序为：

```text
SDRAM 图像读取／未来的窗口拼接扫描
→ 单图转场混合（多窗口旁路）
→ RGB565 展开
→ 全屏 CV
→ 全屏亮度／对比度
→ 频谱
→ 字幕与 OSD
→ 光标
→ HDMI
```

UI 叠加位于 CV 后，不被灰度或卷积处理。

切图转场与 CV 是两类功能：单图保留直接切／交叉溶解／柔边滑动；多窗口只直接切。不必覆盖用户保存的单图转场配置，返回单图后继续使用。

加载窗口的基础图像要求为黑色，字幕、OSD、光标和用户未关闭的频谱仍可叠加。应检查加载屏蔽与 CV／亮度流水的对齐，避免亮度偏置、旧卷积缓存或未对齐的有效标志把加载区显示成旧图、杂点或半新半旧画面。

## 5. 缩小与黑边

用户最终选择：**双线性缩小**。此前“最近邻首版”的建议已被覆盖，不能默默替换为最近邻。

几何规则：

```text
s = min(1, 窗口宽 / 源宽, 窗口高 / 源高)
```

- 大图等比例缩小到窗口可容纳的最大尺寸。
- 小于窗口的图片保持原尺寸，绝不放大。
- 不拉伸、不裁剪，在窗口内居中，其余填黑。
- 整数目标尺寸、居中余数、坐标映射、定点权重、舍入和边界钳位必须在执行计划中冻结，RTL 和 golden 使用同一定义。
- 没有发生缩小的图片应保留原始 RGB565 值。

| 原始尺寸 | 双图中的图像尺寸 | 四宫格中的图像尺寸 |
| --- | --- | --- |
| 1280×720 | 640×360 | 640×360 |
| 640×480 | 640×480 | 480×360 |
| 320×240 | 320×240 | 320×240 |

双线性在显示板写入窗口槽时执行，不在每次刷新时重复计算。槽中保存处理后的窗口图像及黑边，原始分辨率另存为元数据。

行缓存优先评估 BRAM9K。两行 1280×16 像素本体为 40,960 bit，实际资源数取决于 TD 映射，另计 FIFO 和流水。显示板 BRAM32K 接近满载，但 BRAM9K 并未耗尽。DSP 有余量不代表整个缩小器一定放得下，还要验证 LUT、时序与处理节拍。

## 6. 最新窗口更新方式：黑屏加载、单槽原地更新

### 6.1 用户最新决定及其代价

每窗只需一个持久显示槽，更新过程允许该窗变黑。它替代此前每窗双缓冲、加载期间保留旧图的方案。

推荐状态顺序：

```text
锁定目标窗口和请求图片
→ 在帧边界隐藏该窗口
→ 确认该窗口的旧读请求和返回数据排空
→ 安全覆盖该窗口槽位
→ 接收校验、缩小补黑、SDRAM 写入全部完成
→ 在帧边界恢复显示并提交索引／原始尺寸
```

- 其他窗口的槽位、内容和已提交索引无需改动。
- 不为每次单窗更新复制整个屏幕。
- 不需要每窗独立的备用整图槽，也不需要给新图增加一块全屏暂存区。
- 重试期间该窗口继续保持黑色。
- 最终失败时旧像素已经可能被覆盖，不能承诺恢复旧图；该窗保持黑色，并报告可恢复的错误状态。
- 保留上次已提交索引与本次请求索引的区别，供重试、继续切图或回单图重载。
- 不能收到 BEGIN 就把新索引、原始尺寸标为已经显示。

### 6.2 仅把 RGB 输出遮黑还不够

必须保证开始原地写入前，不再有读取该目标槽的在途请求。隐藏后的扫描可合成黑像素并跳过该槽的 SDRAM 读取，保持整屏像素数量与时序连续。

即使 RGB 已经被遮黑，若旧读请求仍在执行，直接覆写仍会产生额外读写冲突、返回归属问题和后续 FIFO 污染。要用明确的隐藏／排空确认，不能凭固定延时猜测已经安全。

### 6.3 与此前原子提交约定的关系

- 多窗口单窗切图：允许旧图先消失；只保证黑窗恢复为完整新图时原子提交，不显示半成品。
- 单图：仍保留旧双缓冲和转场，不套用黑窗原地更新。
- 进入双图／四图：此前“全部窗口准备完成后再切换整个布局”的约定保留，可在另一块全屏图像区准备。
- 返回单图：可在空闲整图缓冲装载目标单图和配对音频，完成后切换。

## 7. 布局互锁及网页忙状态

### 7.1 合法布局转换

```text
单图 ↔ 左右双图
单图 ↔ 四宫格
双图 ↔ 四宫格：不允许直接转换
```

用户明确要求：双图时四宫格按钮禁用，四宫格时双图按钮禁用；返回单图后两个入口恢复可用。当前布局按钮也可禁用，避免重复装载同一布局。

### 7.2 板侧也要执行相同约束

网页禁用不能代替 FPGA 的合法性检查。USB 串口、HC-08、按键、轮播、GT911 或直接调用后端接口都可能绕过网页。

- 不合法布局转换明确拒绝，不读卡、不隐藏窗口、不修改布局或索引。
- 操作忙时，图像／布局／D 等互相冲突的请求必须统一接受或拒绝，规则有界且可报告。
- 不为非法转换保留额外准备、迁移和回滚分支。
- 控制入口仍复用统一控制核心，不分别维护互相矛盾的布局状态机。

### 7.3 忙时禁用与真正完成

用户提出：类似下一张等长操作，可以让网页控制区暂时变灰，等待完成后恢复，减少重复请求。

执行计划需明确具体禁用控件范围。至少图像更新、布局、D 等冲突入口应互锁；连接恢复、日志和状态同步必须保持可用，不能把错误恢复入口也锁死。

解锁依据必须是实际事务成功、失败或经过状态查询确认的空闲，不能使用以下信号替代装载完成：

- HTTP `/api/cmd` 返回 `ok`；
- 命令已经发到媒体板；
- 初始 V1 `5A` 命令 ACK。

**源码核查：V2 当前 `sendKey()` 仅发送 HTTP 请求和按钮动画，没有等待图片提交的整页锁。`setLink()` 主要按连接状态启用按钮。媒体板 N/P 命令目前在产生切图脉冲后即可进入 ACK 路径，图像事务另行执行。不能把“ACK”三个字一概理解为新图已显示。**

新增 busy／完成／布局／窗口状态应有机器可解析字段；避免只靠中文日志正则实现可靠互锁。重连或刷新页面要查询实际板态，不能按浏览器本地旧值恢复按钮。超时后重新查询状态并显示错误，不得无条件假定任务成功，也不得永久禁用。

已有自动轮播、其他控制入口触发的装载，同样应反映在网页忙状态中。

## 8. 现有代码与数据事实

### 8.1 媒体板

```text
原生 SD → FAT32 → BMP 解码
→ media_frame_format 生成 1280×720 黑边帧
→ media_image_tx → Ethernet
```

- `bmp_dec` 已提供源宽高和像素，支持既有非零且最大 1280×720 的未压缩 24-bit BMP。
- 解码器处理 BMP 行对齐填充，按文件自底向上的原始行序输出。
- 媒体板把 RGB888 量化成 RGB565。
- `media_frame_format` 当前负责 FIFO、居中、补黑和两像素打包。
- `media_image_tx` 多处使用固定 `FRAME_WORDS=460800`。
- 本轮复用现有文件读取与解码，不重写 SD、FAT32、BMP 或 WAV。

### 8.2 显示板

- `media_protocol_rx` 与 `media_transaction_writer` 当前按固定全屏长度接收、排空、写入、等待完成。
- 不能只改 BEGIN 检查，遗漏写长度、失败收尾、FIFO 排空及完成判据。
- 现有图像上下翻转在 SDRAM 写入层完成；音频必须顺序写，不能套用图像翻转。
- 增加动态源尺寸后，要保证只翻转一次，并依据正确的源图／目标槽行数寻址。
- 当前 GT911 光标存在，但顶层没有把 `gt911_trackpad` 的 `cursor_x/cursor_y` 输出接给布局控制；需要接入正确的权威坐标／跨域快照。

### 8.3 D 的真实来源与本轮约定

**网页 D 不是显示板 SDRAM 的真实回读。** 当前是媒体板从 SD 重读已提交图片，再向 PC 发送正式图像事务。显示板原独立 SDRAM 读回探针已经移除。

本轮多窗口 D：

- 获取鼠标所在窗口对应的源图。
- 继续媒体板 SD 重读，不新增生产用显示板回读硬件。
- 不包含显示端双线性缩小、CV、亮度、字幕或其他叠加。
- 网页标明来源窗口、源尺寸，保留 BMP 比较能力。
- 支持可变源尺寸，不能把源图称为实际 HDMI 全屏抓取。
- 目标窗正在装载或最终失败无有效画面时，D 的忙／无效响应要明确，不能伪造当前显示成功。

D 全对只能验证源图和对应网络事务，不能证明显示板缩小、槽位写入或拼接扫描正确。

## 9. 协议与控制接口约束

现有正式图像事务：`READY → BEGIN → DATA… → END → RESULT`。

最低要求：

- BEGIN 携带源宽高和实际数据长度；多窗口还须明确目标窗口及布局上下文。
- 按宽高验证像素数和数据长度，不能接受尺寸与字数矛盾的事务。
- RGB565 两像素一字，先出现像素位于低 16 位。
- 奇数宽高、奇数像素总数及末字填充规则在计划中冻结并测试。
- 统一行序，只翻转一次。
- 保留顺序号、累计校验、失败重试和提交确认，不增加压缩或复杂重传体系。
- 现有数据每片最多 253 个 32 位字；非末尾 DATA 包间隔 100 μs，END 前等待 1 ms。不能未经验证删减这些排空余量。
- 正式媒体包 TYPE/LEN 小端；V1 控制包及显示设置包 TYPE/LEN 大端，不能混用。
- BEGIN 字段排版、结果含义、忙与完成状态需要在计划中明确，并同步 RTL、PC 模型、后端与文档。
- 当前状态借用了高位传递 CV 模式，新增字段不能覆盖这些位。
- 两板可配套升级，不要求新旧 bit 任意混搭；不兼容报文应明确拒绝，不能错误解释后写 SDRAM。

目前 `6/7/8` 未占用，建议作为统一布局命令：

| 字符 | CMD ~CMD | 布局 |
| --- | --- | --- |
| `6` | `36 C9` | 单图 |
| `7` | `37 C8` | 左右双图 |
| `8` | `38 C7` | 四宫格 |

网页三个按钮与 USB 串口、蓝牙、以太网走同一命令语义。不要重新加入页面全局键盘监听。

## 10. SDRAM 槽位与模式转换

### 10.1 真实基线布局

SDRAM 共 2,097,152 个 32 位字，8 MiB。

| 区域 | 起始字地址 | 长度 | 用途 |
| --- | ---: | ---: | --- |
| BUF0 | 0 | 460,800 | 图像 A |
| BUF1 | 460,800 | 460,800 | 图像 B |
| BUF2 | 921,600 | 587,776 | 音频 A |
| BUF3 | 1,509,376 | 587,776 | 音频 B |

bank 在本需求中指逻辑图像槽，不要求每窗占用 SDRAM 芯片的独立物理 bank。

### 10.2 黑窗原地更新后的容量

| 模式 | 每个窗口槽位 | 活动窗口合计 |
| --- | ---: | ---: |
| 单图 | 460,800 字 | 460,800 字，另保留现有单图备用缓冲 |
| 双图 | 230,400 字 | 460,800 字 |
| 四图 | 115,200 字 | 460,800 字 |

一套多窗口槽只占一块现有全屏图像区，另一块图像区可以保留给单图／布局转换准备。相比前稿的每窗双缓冲，减少了活动指针组合、备用槽管理和布局迁移难度。

推荐在计划中评估：进入双图／四图时在单图非活动区准备全部窗口，然后统一提交；同一多窗口布局下固定使用这块区域，单窗只原地覆盖；返回单图在另一整图区装载。这样避免各窗活动槽分散在 BUF0／BUF1 后难以找到完整后台区。

具体基址与行映射仍需结合现有读写控制器验证后写入执行计划。不要沿用旧评估文档把 BUF2 当图像区的描述，也不要为了四窗保存四份完整 1280×720 原图。

### 10.3 读写边界仍需验证

双图／四图每窗行宽为 640 像素，即 320 个 32 位字；320 不整除现有某些 128 字突发。

必须验证窗口行尾、窗口间地址跳转、尾突发、返回归属、FIFO 预取和帧边界。不能让突发越界读到另一窗，也不能在数据未排空时切换拥有者。

黑窗更新省去了并行保留旧图，但不会自动解决 SDRAM 刷新、跨行突发、读写仲裁或拼接扫描。

## 11. OSD 与前后端

- 保留亮度、对比度、音量及三种 OSD 显隐模式。
- 增加原始分辨率；多窗口跟随当前鼠标窗口，可附窗口编号。
- 成功写入并恢复显示时同步提交图片索引与原始尺寸；加载／失败不能冒充有效新画面。
- 复用现有字体 ROM，不复制字库。
- 不改动字幕和 CV 的时序相对关系。
- 前端增加布局状态、所选窗口、忙／失败反馈及布局按钮互锁。
- 后端接口和 RTL 同样检查非法布局转换、忙状态；不能仅靠浏览器禁用。
- 源图 D 支持可变宽高，预览和 BMP 对照不能继续硬编码 460,800 字。
- 忙状态不能由日志文字或短暂按钮动画推断，须与实际操作结果对应。

## 12. 仲裁及失败恢复审计

### 12.1 统一命令来源

- USB、HC-08、以太网、按键、轮播、GT911 的一次操作只能触发一次切图。
- 保留此前修复过的防重复入口：N/P 不能同时从原始命令与转换后脉冲再次进入发送器。
- 锁定目标窗口、方向、请求图片、来源和所属布局。
- 用一个统一 busy／合法转换规则拒绝冲突请求，避免无界队列。
- 网页禁用只是辅助，直接发送命令也必须遵守。
- 状态和故障恢复通路不能被长图像事务永久占住。

### 12.2 SD、音频与 D

- 图片、WAV、D 重读串行拥有文件读取链路。
- D 调度优先级低于显示更新，不能永久挡住真实切图。
- 多窗口跳过 WAV 内容；如果复用零样本音频事务作为握手，不能等待未发送的 PCM，也不能提前修改尚未提交布局的音频状态。
- 单图音频保持原提交／转场结束后切换规则；多窗口静音不改音量或频谱配置。

### 12.3 网络包拥有权

- 以完整 UDP 包为仲裁边界，控制包不能插进 DATA 包中间。
- request、ack、valid、ready、完成事件属于同一包拥有者。
- END 在最后 DATA 真正发完后发送。
- 迟到 ACK、重复 RESULT、超时重试不能重复推进索引或错误恢复窗口有效位。
- 初始命令 ACK 与实际图像／布局提交必须区分。

### 12.4 布局初次装载

防止“显示板等全部窗口齐备才回最终确认，媒体板却等第一张的最终确认才发第二张”的死锁。

必须区分单窗数据准备完成和整套布局生效。加载失败时保留原布局，不能留在无法退出的 pending 状态。

### 12.5 SDRAM 与黑窗写入

- 保留 `Sdr_busy`、`Sdr_init_ref_vld` 等历史修复中的忙／刷新门控。
- 写目标槽前，先完成隐藏和旧读请求排空。
- 无效窗口输出确定的黑像素，整屏像素数和时序不变。
- 显示读不能被连续写或其他读取饿死。
- 不得写到其他窗口或当前单图活动区。
- 多窗口不误触发转场读取；单图转场、音频和图像写仍共同正常工作。
- 返回数据未排空不能切换归属标签。
- 地址、长度和计数不溢出；短尾不挂起，不越界。
- 窗口失败后保留无效状态，可重试或回单图，不宣称仍保留旧像素。

### 12.6 跨时钟域

审查 ETH、文件处理、SDRAM、视频域之间的宽高、索引、布局、目标窗、隐藏确认、写完成和恢复显示事件。

多位元数据使用稳定保持加握手等一致性机制；不能逐位同步后默认属于同一事务。窗口有效位改变须与帧级预取快照匹配，避免半帧使用旧状态、半帧使用新状态。

## 13. 当前资源基线

以下来自仓库最新保存的布局布线报告，非历史单板数据。

| 资源 | 显示板 | 媒体板 |
| --- | ---: | ---: |
| LUT | 14,339 / 19,600 | 14,436 / 19,600 |
| FF | 10,227 / 19,600 | 9,635 / 19,600 |
| BRAM9K | 37 / 64 | 23 / 64 |
| BRAM32K | 13 / 16 | 2 / 16 |
| DSP | 10 / 29 | 2 / 29 |
| PLL | 4 / 4 | 3 / 4 |
| Setup WNS | −5.699 ns | −3.607 ns |
| Hold WNS | −3.188 ns | −3.056 ns |

- 显示板剩 27 块 BRAM9K、3 块 BRAM32K，不是所有 BRAM 都满。
- 显示板无空闲 PLL，使用现有时钟。
- 双线性最终以实际 LUT、RAM 映射、DSP、时序和吞吐为准；不能静默降成最近邻。
- 本轮是功能开发，不套用过去资源优化候选必须省 64 LUT 的门槛。
- 记录真实资源增量和具体时钟路径，不将全局负 WNS 直接等同于新问题根因。

## 14. 验证要求

### 14.1 可变帧与单图回归

- 以实卡和镜像／golden 对照，覆盖现有六张图片、四个配对 WAV。
- 源尺寸、像素数、RGB565 和校验和正确，小图不再携带黑边。
- 显示端补黑结果与旧单图逐像素一致，方向正确。
- OSD 源尺寸正确，D 和 BMP 比较正常。
- 单图音频、转场、CV、字幕和各入口回归。
- 定向覆盖奇数宽高、奇数总像素、1 像素图及末字填充。

### 14.2 多窗口

- 单图→双图→单图→四图→单图，重复验证模式往返。
- 初始当前图及后续 BMP 正确，列表末尾回环正确。
- 每窗独立前后切图；鼠标边界、重复图片、目标锁定和自动轮播正确。
- 目标窗加载时黑屏，其他窗口像素和索引不变。
- 新图恢复显示前，校验和实际 SDRAM 写入都完成。
- 双线性与 golden 对比，覆盖等比例缩小、小图不放大、黑边和边缘样本。
- 错误／重试时目标窗保持黑色，之后可继续操作，不卡死。
- 返回单图为所选图片，WAV 和保存的音量恢复。
- 多窗直接切；单图全部转场仍正常。
- CV 全屏统一，频谱、字幕、OSD、光标的配置未被布局偷偷改掉。

### 14.3 布局和忙互锁

- 双图时四宫格不可点，四宫格时双图不可点；返回单图后恢复。
- 通过原始 UDP、UART、蓝牙模拟、后端接口绕过 UI 发送非法布局命令，板侧明确拒绝且无副作用。
- busy 时重复操作不会进入多重装载或写错窗口。
- 初始 ACK／HTTP 成功不会提前解除装载锁。
- 成功、失败、超时、断线／重连、刷新页面和外部命令触发都能恢复正确控件状态。
- 状态、日志和必要的恢复入口可用，不会因等待完成永久全灰。

### 14.4 错误与并发

- 丢包、重包、错序号、错帧号、错字数、错校验、提前／迟到 END。
- 丢最终结果、重复结果、重试和各阶段复位。
- 切图、轮播、D、布局及其他控制的竞争。
- 刷新、busy、返回延迟、FIFO 临界条件和窗口行尾。
- 隐藏与旧读排空的握手；失败不能恢复有效位。

### 14.5 实板证据的边界

两板 CLI 下载后，脚本验证真实事务、状态、D 源图及 PCM。但媒体板 D 不经过显示板，不能据此宣称显示缩小或扫描正确。

需要时建立临时诊断构建，检查显示板实际槽位或扫描数据。诊断构建／抓包放忽略目录，最终清理临时硬件，不把大量调试计数器堆进产品版本。

最终报告区分 RTL／模型、真实媒体输出、真实显示存储／扫描及用户醒来后的 HDMI／声音主观确认。无法取得的关键证据应如实说明，不以 ACK 代替像素验证。

## 15. 自动执行与提交

CLI 依据：[TD CLI 文档](td_cli_programming.md)。

- 源码改变后先 `syn_1/run.bat`，再 `phy_1/run.bat`，工作目录正确。
- 核对本轮日志、报告、bit 时间和 SHA，不以目录里有旧 bit 作为成功。
- SRAM 下载：显示板 `-cable 0`，媒体板 `-cable 1`。
- 下载后等待网络／SD 初始化，不因首次 ping 超时立即判失败。
- 新 RTL 同步 TD 源文件列表，避免 black box。
- 协调 app 和测试程序的 UDP 监听，避免端口竞争造成假丢包。
- Verilator 在 WSL 运行；Windows 不假设存在 Verilator。
- 保留稳定的 100 MHz SDRAM 和当前原生 SD 配置。
- 每阶段先跑相关定向测试，完成后才跑必要的组合回归，避免无关全量压测。

按真正完成的任务点组织至多三次本地提交：

1. 可变尺寸协议、显示端补黑、分辨率 OSD 及对应验证。
2. 固定多窗口、双线性、黑窗更新、布局／忙互锁及对应验证。
3. 仲裁审计发现的必要修复和验证记录；若已在第二阶段充分完成，不为凑次数拆提交。

提交简短标题，正文使用简短 `-` 条目。包含对应源码、测试、文档及已验证 bit／报告；不推送。未完成阶段保留现场，不把部分成果标成该任务完成。

## 16. 交给下一模型明确的工程细节

以下在拟执行计划时结合源码定案，不代表用户需求尚未确定：

- BEGIN 扩展、目标窗／布局身份、忙／完成结果与状态扩展格式。
- 像素 packing、奇数尺寸、尾字、checksum 和行序。
- 双线性坐标、权重、精度、舍入、钳位和行缓存组织。
- 黑窗时的读请求排空、确定黑像素生成及 CV 流水对齐。
- 槽位基址、逐窗扫描及 320 字行宽对应的突发方案。
- 单图与多窗的切换屏障、初次多窗准备／整布局提交确认。
- 所有入口的一致 busy 规则、D 竞争、重试和错误恢复。
- 网页具体禁用范围、状态同步和超时重查；不能依赖初始 ACK 解锁。
- 板级显示数据的自动验证方法与临时诊断清理。
- 各阶段完成标准与本地提交边界。

协议和状态机继续从简，优先利用新的产品约束删掉不允许的操作路径。前端互锁不能当作唯一正确性保证，板侧仍要保留最小必要的合法性／拥有权检查。

## 17. 参考资料与历史描述纠正

- [现有媒体协议](media_link_protocol.md)：字节序、事务与 D 的真实来源。
- [CLI 综合与 SRAM 下载](td_cli_programming.md)。
- [验证入口](verification.md)。
- [多分辨率修复复盘](multires_fix_postmortem.md)：打包、地址与仲裁教训。
- [CV 探索及稳定修复](display_cv_effects_exploration.md)：以末尾 2026-10-22 稳定修复记录为准。

注意：

- 仓库两份历史多窗口评估文档存在不同缓存布局和原型建议，不能直接当当前事实。
- 当前真实顶层是两块图像区、两块音频区；旧文档的三图像／单音频设想不是当前实现。
- CV 文档前半早期“尚未上板”已被末尾稳定版记录覆盖。
- 某些旧记录把 D 成功描述成覆盖显示板 SDRAM 读写，与当前实际路径不符，不能沿用该验收结论。
- 本文中的最新用户决定优先于历史探索建议和前稿每窗双缓冲提案。

## 18. 最新需求变更摘要（2026-10-22 本次落盘）

1. 多窗口单窗切图允许先黑屏，安全隐藏／排空后原地覆写，不再要求保留旧图和每窗双缓冲。
2. 重试／失败期间窗口保持黑色；成功恢复显示仍需完整验证与帧边界提交。
3. 双图和四图禁止直接互切，必须先回单图；网页和 FPGA 同时执行约束。
4. 增加装载期间网页禁用的设计要求，实际禁用范围在计划中冻结；解锁依据真实完成／失败状态。
5. V2 当前并没有可靠的装载全页锁，初始切图 ACK 也不等于显示完成，需要新增而非假设已经具备。
6. CV 图像效果始终全屏统一；多窗口只改变布局和选图，不做逐窗 CV。

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
