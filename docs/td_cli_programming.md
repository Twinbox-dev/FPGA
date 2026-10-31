# 重点：TD CLI 综合、布局布线与 SRAM 下载

本仓库的 Tang Dynasty 工程可以从命令行启动综合、布局布线和 JTAG SRAM 下载。
这为后续将“综合 → 布局布线 → 下载 → 板级/PC 验证”串成自动流程提供了基础。

## 命令入口与依据

TD 安装目录中的 `td_commands_prompt.exe` 提供内置 Tcl 命令帮助：

- 在 TD 命令提示环境执行 `help download`，命令列表包含 `download` 及
  `-mode <string>`、`-bit <string>`、`-cable <integer>` 等参数。
- 本机的 `doc/SWUG/SWUG105_TCL_Command_User_Guide.pdf` 可检索文本没有给出
  `download` 的完整下载调用示例；**命令形式以 CLI 内置帮助和实际命令执行为依据**。
- 本机 BitWizard 手册 `doc/SWUG/SWUG110_BitWizard_User_Guide.pdf` 第 4.3.1 节
  “Program SRAM”（印刷页 18）说明 SRAM 下载写入配置 RAM，掉电丢失；第 4.3.3 节
  “Program Flash”（印刷页 19）说明 Flash 下载掉电保留。

TD CLI 可执行文件和 flow 脚本：

- CLI：`C:\Program Files\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin\td_commands_prompt.exe`
- Flow：`C:\Program Files\Anlogic\TD_6.2.1_Engineer_6.2.168.116\doc\scripts\DefaultFlow.tcl`

工程生成的每个 `syn_1/run.bat`、`phy_1/run.bat` 都会从对应运行目录启动
`td_commands_prompt.exe` 并传入 `DefaultFlow.tcl`。启动时的当前目录很重要：
TD 从当前 `settings.cfg` 读取本轮工程名、顶层、起止步骤、约束和父网表目录。

## 综合与布局布线

显示板工程目录：

`C:\Users\23506\Desktop\anlogic\board_display\td_project\lab_ex5_i2s_v1.0_Runs`

媒体板工程目录：

`C:\Users\23506\Desktop\anlogic\board_media\td_project\media_net_Runs`

显示板和媒体板的 `settings.cfg` 当前均将 `syn_1` 配置为 `run_type syn`，
从 `read_design` 到 `opt_gate`；将 `phy_1` 配置为 `run_type phy`，
从 `opt_place` 到 `bitgen`，父工程为 `../syn_1`。因此源码变更后必须先
跑综合，再跑布局布线；单独跑 `phy_1` 会使用父目录现有网表，不能证明新源码已综合。

以下 PowerShell 示例对显示板先综合再布局布线。媒体板使用时，只需将
`$runRoot` 改为上面的媒体板工程目录：

```powershell
$tdRoot = "C:\Program Files\Anlogic\TD_6.2.1_Engineer_6.2.168.116"
$tdCli = Join-Path $tdRoot "bin\td_commands_prompt.exe"
$runRoot = "C:\Users\23506\Desktop\anlogic\board_display\td_project\lab_ex5_i2s_v1.0_Runs"

$tdFlow = 'C:/Program Files/Anlogic/TD_6.2.1_Engineer_6.2.168.116/doc/scripts/DefaultFlow.tcl'
foreach ($taskStage in @('syn_1', 'phy_1')) {
    Push-Location (Join-Path $runRoot $taskStage)
    @("source {$tdFlow}", 'exit') | & $tdCli
    $taskExitCode = $LASTEXITCODE
    Pop-Location
    if ($taskExitCode -ne 0) { throw "TD stage $taskStage failed: $taskExitCode" }
}
```

这是主仓库 TD 工程实际调用的 CLI 与 flow。工程生成的 `run.bat` 会向 CLI 输入
`source {C:/.../DefaultFlow.tcl}` 和 `exit`；不要把 Tcl 路径直接作为 CLI 参数传入。
直接调用 `$tdCli $defaultFlow` 会停在 `td >` 并报 `wrong # args: source ...`，并不会运行综合。
检查结束状态时查看本轮日志、`flow.status`、最新时序/资源报告和 bit 文件时间，
不要只看目录中是否存在旧的成功标记。

## JTAG SRAM 下载

### 快速执行

从仓库根目录选择目标板运行；无需打开 TD GUI，也不会弹 UAC：

```powershell
.\scripts\program_sram.ps1 -Board display
.\scripts\program_sram.ps1 -Board media
```

默认路径还会比较 bit 与 `.opt_place.begin.f`、`.opt_route.begin.f`、`.bitgen.begin.f`
的 UTC 时间：任一最近运行标记比 bit 新，就拒绝下载。TD 布线失败后经常保留上一次成功的
同名 bit，文件存在并不等于本轮构建成功。拒绝陈旧 bit 与 USB 打开失败是两类不同问题。
明确选择已知稳定版或独立诊断构建时可用 `-CandidateBit <绝对路径>`，并核对打印的 SHA；
该参数允许有意执行旧版 A/B，不改变 cable 映射或 SRAM 下载命令。

脚本用当前普通用户令牌启动隐藏的 `cmd.exe`，把工作目录设为 TD 安装目录的 `bin`，
再将 `download` 命令直接输入 `td_commands_prompt.exe`。完整日志写入忽略目录
`boardtest/captures/sram_download/`。显示板为 cable 0，媒体板为 cable 1：

| 下载线 | 板卡 | 本轮 bit 文件 |
| --- | --- | --- |
| cable 0 | 显示板 | `board_display/td_project/lab_ex5_i2s_v1.0_Runs/phy_1/lab_ex5_i2s_v1.0.bit` |
| cable 1 | 媒体板 | `board_media/td_project/media_net_Runs/phy_1/media_net.bit` |

脚本发送的默认速度命令与此前成功的 CLI 日志一致，不显式指定下载速度：

```tcl
download -mode jtag -bit C:/Users/23506/Desktop/anlogic/board_display/td_project/lab_ex5_i2s_v1.0_Runs/phy_1/lab_ex5_i2s_v1.0.bit -cable 0
download -mode jtag -bit C:/Users/23506/Desktop/anlogic/board_media/td_project/media_net_Runs/phy_1/media_net.bit -cable 1
```

另一份成功 GUI 日志显式指定了速度 7，TD 原样记录的相对路径命令为：

```tcl
download -bit ..\..\..\..\Users\23506\Desktop\anlogic\board_display\td_project\lab_ex5_i2s_v1.0_Runs\phy_1\lab_ex5_i2s_v1.0.bit -mode jtag -spd 7 -cable 0
download -bit ..\..\..\..\Users\23506\Desktop\anlogic\board_media\td_project\media_net_Runs\phy_1\media_net.bit -mode jtag -spd 7 -cable 1
```

该相对路径以 TD 安装目录的 `bin` 为当前目录；本地脚本使用等价的绝对路径，避免依赖
调用方当前目录。两种形式均有成功记录：不指定 `-spd` 的旧 CLI 日志内部调用
`program ... -spd 8 -p`；指定 `-spd 7` 的 GUI 日志内部调用 `program ... -spd 7 -p`。
所以 `-spd 7` 是可选速度设置，不是必填参数。GUI 成功日志包含
`PRG-2014 : Chip validation success` 与 `GUI-1001 : Downloading succeeded!`。

TD CLI 命令也可通过 Tcl 脚本直接执行。通用形式为：

```tcl
download -mode jtag -bit C:/path/to/current_project.bit -cable <integer>
```

如需显式指定下载速度，可加入 `-spd <integer>`；不要把可选速度参数误写成必需项。

脚本每次从本轮 `phy_1` 读取 bit，并打印路径、SHA-256、目标 cable、完整命令和日志位置。
直接命令中的 bit 路径使用正斜杠。脚本固定 TD `bin` 工作目录及直接标准输入方式，
以复用已成功的调用条件；其他组合的失败不能单独证明工作目录或输入方式就是 USB 故障原因。
CLI 遇到“couldn't read file”时仍可能以退出码 0 结束，因此下载验收还须检查日志里
出现器件验证成功（`Chip validation success`），且有对应命令的
`finish command "download ..."`，同时没有 `ERROR`、USB 打开失败或器件验证失败。
不能仅依据 `$LASTEXITCODE` 或 `finish command` 判断已烧录；失败命令也会打印结束行。

成功日志显示该命令会检查器件 ID，随后生成 JTAG burst 数据并调用
`program -mode svf -p` 完成下载。没有调用 `program_spi` 或 Program Flash；
这是配置 SRAM 下载，掉电后需重新配置。未显式提供 `-cable` 时，本机使用 cable 0；
连接多个下载线时可按 CLI 帮助指定 `-cable <integer>`。设备 ID 只能识别器件型号，
不能识别它在项目中承担显示板还是媒体板的角色，下载前应确认 JTAG 线接到目标板。

每次新的阶段性板级验证，在阶段记录中同时保存：bit 文件 SHA-256、上述对应的
`download` 完整命令、cable 与板卡映射、TD 日志路径，以及 `Chip validation success`
和命令结束行。命令结束但缺少成功标记时，状态记录为下载失败，不开始该 bit 的功能验收。

### 2026-10-22 自动下载排查与成功记录

用户提供的历史日志已证明下列默认速度形式曾由命令行成功下载显示板 SRAM：TD 输出
`PRG-2014 : Chip validation success: EG4S20BG256`，随后执行
`program -cable 0 -mode svf -spd 8 -p` 并正常结束。另一份 GUI 日志使用显式
`-spd 7`，也成功下载显示板和媒体板。因此两种命令参数形式均有成功依据。

本次自动化重试复用了成功日志中的默认速度命令及正确 bit 路径；TD 能输出完整的
`RUN-1002 : start command "download -mode jtag -bit ... -cable 0"`，但之后反复出现
`PRG-9505 ERROR: USB device open error`，最终为
`PRG-9525 ERROR: Chip validation failed`。尽管 CLI 仍打印 `RUN-1003 : finish command
"download ..."` 且退出码为 0，这次并未下载成功。错误发生在打开 USB JTAG 设备阶段，
不是 Tcl 参数解析或 bit 文件校验阶段；不得把 finish 行或退出码记录成成功。

当日测试过 Low Integrity 沙箱、普通 Medium Integrity 和 High Integrity；改变当前目录、
直接输入命令或经 Tcl `source` 包装也都曾遇到 USB open error。**不能据此断言工作目录、
`source` 或普通用户权限是唯一原因。** Windows 始终枚举到两只 `Anlogic usb cable v0.1`
（VID `0547`、PID `1002`）。已实际成功的固定组合是 **Medium Integrity、TD 安装目录
`bin` 为当前目录、直接将 `download` 命令输入 CLI**，脚本保持这组条件，无需管理员令牌。
后续普通 Medium 进程还曾成功独占打开两个 Windows USB 接口，而 TD 同时仍报错；
High Integrity 下载也未解决。TD 在 `bin` 中可能打印
`create logfile ... failed`（普通用户对安装目录无写权限），但不影响下载；脚本把标准输出
保存到可写的忽略目录并以器件验证和两条成功结束行为准。自动化环境的普通 Low Integrity
沙箱仍无法打开设备，调用脚本时须使用 Codex 的非沙箱/Medium Integrity 执行通道，但无需
弹 UAC 窗口。

成功的显示板记录：2026-10-22 14:14，cable 0，命令为
`download -mode jtag -bit C:/Users/23506/Desktop/anlogic/board_display/td_project/lab_ex5_i2s_v1.0_Runs/phy_1/lab_ex5_i2s_v1.0.bit -cable 0`。
日志包含 `PRG-2014 : Chip validation success: EG4S20BG256`、
`finish command "program -cable 0 -mode svf -spd 8 -p"` 和 `finish command "download ..."`。
本次 bit SHA-256：`79B8BBDD817A55CAD6E0C58D626069470B81B28C19B8DDAEF9C780C1B18BEA5D`。
随后用仓库脚本 `scripts/program_sram.ps1 -Board display` 在 14:16 再次成功，日志在
`boardtest/captures/sram_download/program_display_20261022_141606.log`。14:20 又以 Medium
Integrity、不请求 UAC、从 TD `bin` 直接输入同一命令成功复验，日志在
`boardtest/captures/sram_download/display_no_uac_medium_td_bin.log`。14:22 由仓库脚本
`scripts/program_sram.ps1 -Board display` 再次无 UAC 成功，日志在
`boardtest/captures/sram_download/program_display_20261022_142208.log`。这确认当前自动化
流程能以普通用户权限将显示板 SRAM 下载跑通。

成功的媒体板记录：2026-10-22 14:24，cable 1，命令为
`download -mode jtag -bit C:/Users/23506/Desktop/anlogic/board_media/td_project/media_net_Runs/phy_1/media_net.bit -cable 1`。
日志包含 `PRG-2014 : Chip validation success: EG4S20BG256`、
`finish command "program -cable 1 -mode svf -spd 8 -p"` 和下载结束行。
bit SHA-256：`0D058538C7531A1CE608821F9E756CE81AF3ED6D62A43F498A50F3CE9C1073DC`；日志在
`boardtest/captures/sram_download/program_media_20261022_142406.log`。至此，两板均已由仓库
脚本在 Medium Integrity、普通用户权限、无 UAC 提示的方式下载成功。

同一工作方式在 15:31、15:34、15:35 的后续重新下载中又出现 `PRG-9505 USB device open error`
和 `PRG-9525 Chip validation failed`，分别涉及 media cable 1、media cable 1、display cable 0；
完整日志是 `program_media_20261022_153143.log`、`program_media_20261022_153442.log`、
`program_display_20261022_153531.log`。三次日志都回显了正确的直接 `download -mode jtag -bit ... -cable N`
命令，但没有器件验证成功，因此不能算重烧成功。15:51 的 High Integrity 备用启动弹出 UAC
后被取消，TD CLI 未启动、没有下载动作。结论：**无 UAC CLI 方式已在两板上实证成功，但 USB 设备
打开在后续运行中会间歇失败**；每次都必须检查本次日志，不能仅凭脚本退出码或上一次成功推断当前
板卡已下载。发生 `PRG-9505` 时保留当前板上 SRAM 状态，记录日志并稍后重试；不要把失败行当作成功。

失败尝试原始日志保存在忽略目录 `boardtest/captures/variable_frame_stage1/`。失败日志里即使
出现 `finish command "download ..."` 且 CLI 退出码为 0，也必须判为失败；只有成功标志、
内部 `program` 完成和 `download` 完成同时出现时才可验收。

## 后续自动化

### 2026-10-27：系统未枚举下载器的失败记录

本次仍使用正常用户的非沙箱进程执行 `scripts/program_sram.ps1 -Board display`，
没有请求 UAC，也没有修改下载命令。日志 `program_display_20261027_184322.log`
显示 `PRG-9505 USB device open error` 和 `PRG-9525 Chip validation failed`，
没有芯片校验成功或内部 program 成功结束，因此新候选没有写入 FPGA。

进一步检查发现：`Get-PnpDevice -PresentOnly` 中没有 VID `0547`、PID `1002`；
不带 `-PresentOnly` 只能看到状态为 `Unknown` 的历史 `Anlogic usb cable v0.1`。
这与“下载器在线但程序打不开”的情况不同，不能仅靠修改 Tcl 参数恢复。
先恢复实际 USB 连接和板卡供电，再使用原脚本重试；不要改驱动、全局权限或编程模式。

```powershell
Get-PnpDevice -PresentOnly |
    Where-Object { $_.InstanceId -match 'VID_0547.*PID_1002' } |
    Select-Object Status, FriendlyName, InstanceId
```

当时系统内的 `jtagserver.exe` 经服务路径核实为
`D:\App\IntelFPGA\SoCEDS\qprogrammer\bin64\jtagserver.exe`，属于 Altera JTAG Server，
没有将它误当作 Anlogic 下载服务结束。检查占用时必须核对进程归属。

本仓库两侧工程的综合和布局布线都由 TD `DefaultFlow.tcl` 的项目设置驱动；
SRAM 下载也已找到可执行的 CLI 命令。下一步可将上述流程封装成脚本：每阶段检查
返回码、报告时间和新 bit 时间，随后启动对应的板级/PC 验证入口。JTAG 连接和板卡
供电仍是实体操作；CLI 下载不等于功能验收或时序收敛。

## 2026-10-22 重连恢复后的再次实证（恢复上下文时先读）

**可复用的脚本就是 `C:\Users\23506\Desktop\anlogic\scripts\program_sram.ps1`。**
脚本执行成功已有两轮实证，遇到 USB 错误后应优先核查设备状态，不要重写下载命令。
在 Codex 中需要使用可访问 USB 的非沙箱执行通道；这是执行环境权限，不等于 Windows
管理员权限，不需要 `Start-Process -Verb RunAs`。普通 PowerShell 可直接执行：

```powershell
& 'C:\Users\23506\Desktop\anlogic\scripts\program_sram.ps1' -Board display
& 'C:\Users\23506\Desktop\anlogic\scripts\program_sram.ps1' -Board media
```

本次 17:02 同一脚本报 `PRG-9505`。用户随后断电、重新连接；17:05 未修改脚本、未改变
`download -mode jtag -bit ... -cable N` 命令、未请求 UAC，两块板都立即下载成功。
17:22 显示板修正版再次通过同一脚本无 UAC 下载成功。因此这段经历的准确结论是：
**命令和脚本有效，USB/JTAG 连接状态曾异常，重连后恢复；具体底层原因未证实。**

| 时间 | 板卡 | bit SHA-256 | 本机完整日志（均在 `boardtest/captures/sram_download/`） |
| --- | --- | --- | --- |
| 17:05 | 显示板 cable 0 | `B7CFE6DB7EAD6A957B4C0E4CF68559B2945518E328B1A8EBB969880B36B4A2D3` | `program_display_20261022_170541.log` |
| 17:05 | 媒体板 cable 1 | `F0CC7D6AF1473E6B6F7F8DCF0ABFEC0A3C6EDE1879EB7F89F33352240FE905CA` | `program_media_20261022_170549.log` |
| 17:22 | 显示板 cable 0 | `3189B343BC71B13DE73675E191317747B846548ABAD1268FF7FA0127E31647B4` | `program_display_20261022_172242.log` |

这些 SHA 是当时文件的身份，不要求以后重新综合仍相同。三份日志均含 `PRG-2014`、内部
`program -cable N -mode svf -spd 8 -p` 完成及外层 `download` 完成，且无 `ERROR`。
调用程序虽可能返回 0，但只要出现 USB open error 或 Chip validation failed，本次仍失败；
脚本已将这种情况转为 PowerShell 错误。SRAM 下载仍然仅保持到下次断电。

### 出现 USB open error 时

1. 保存本次脚本日志，核对 cable 0/1、bit 路径和 SHA。不要仅因曾成功就把新失败记成成功。
2. 在同一 TD CLI 普通权限环境可用 `read_device_id -cable 0` 或 `read_device_id -cable 1`
   只读核对 JTAG。成功输出 `EG4S20BG256` 只能证明器件可读，不能区分两块同型号板的角色。
3. 如果命令确实相同、没有其他程序正在下载，且 USB 连续打不开，停止反复改参数和盲重试。
   本次已验证的恢复操作是用户断电并重新连接，之后原脚本恢复。不要擅自重装驱动、修改
   全局权限或将 SRAM 改为 Flash 编程。
4. `connect_cable -current` 曾打印 `Current download will using allink cable`；重连后相同默认
   模式可以成功，因此该提示本身不能证明选错驱动。不要把没有验证的推测写成恢复步骤。
   无参数 `connect_cable` 会报 `host name is empty`，不是本工程所需的下载前置命令。

### 独立诊断构建的 bit

默认两条命令只下载各自产品工程 `phy_1` 下的 bit。需要下载由 `boardtest/diagnostics/`
生成的隔离构建时，显式传入候选路径；cable 仍由 `-Board` 固定选择，其他调用方式相同：

```powershell
.\scripts\program_sram.ps1 -Board display -CandidateBit '.\boardtest\captures\display_digest_stage1\phy_1\lab_ex5_i2s_v1.0.bit'
```

诊断完成后重新运行不带 `-CandidateBit` 的显示板命令，即恢复产品 bit。保存诊断 bit 的
SHA、对应源清单、报告和自动验收 JSON；临时诊断工程和原始抓包可以放忽略目录；被确认有复现价值的构建按 [产物规则](repository_commit_policy.md) 保存源覆盖、bit 和说明（源码放 `boardtest/diagnostics/`，正式构建随发布标签归档），不能只存在 captures。正式工程是否包含诊断模块须以当次源码/源列表和归档说明为准。该可选参数仅改变待下载文件，不改变目标 cable、不切换编程模式或权限。

> 注意：主线已不再跟踪 `*_Runs/` 目录。首次在干净检出的仓库上构建前，目标路径尚不存在，需要在 TD GUI 中打开对应 `.al` 工程完成一次综合/布局布线以生成运行目录；正式 bit 与报告可从发布标签 `dual-V4.0` 直接取用。

## 两板重新配置顺序（2026-10-23 实测）

先下载显示板 cable0，再下载媒体板 cable1。用户仅重新综合并下载显示板后无图，继续重新综合/下载媒体板后恢复；同轮核对表明 GUI 和 CLI 都使用正式 `top_tf_hdmi_audio.v`，其源码未变，显示资源/WNS 也一致。现象支持两端应用状态需重新同步：显示板重配置会清空 SDRAM/布局，媒体板可能仍保留旧图已提交状态。独立重配置自动恢复尚未专项验收；本次实证恢复动作是重新下载媒体板，不必因此改下载命令。

只需要重配时可复用已验证且配套的媒体 bit；“恢复动作涉及重下载”不意味着每次必须重新综合。待用户授权时再改复位/重连接机制。

## 2026-10-25 多窗口转场候选：CLI 构建与双板 SRAM 下载

本次以当前工作区源码执行显示板综合、布局布线、bitgen，并将显示板与现有媒体板 bit 分别写入 SRAM。整个流程使用 TD 6.2.1 Engineer 6.2.168.116。以下是已实测的命令和结果，便于复现本轮构建。

### TD CLI 构建调用

工程生成的 `syn_1/run.bat` / `phy_1/run.bat` 在本机实测失败：脚本未给 `C:/Program Files/.../td_commands_prompt.exe` 路径加引号，`cmd.exe /c run.bat` 报 `'C:/Program' is not recognized`，没有启动综合。应在每个阶段目录作为当前目录，向 TD CLI 的标准输入传入 Tcl `source` 和 `exit`：

```powershell
$tdRoot = 'C:\Program Files\Anlogic\TD_6.2.1_Engineer_6.2.168.116'
$tdCli = Join-Path $tdRoot 'bin\td_commands_prompt.exe'
$tdFlow = 'C:/Program Files/Anlogic/TD_6.2.1_Engineer_6.2.168.116/doc/scripts/DefaultFlow.tcl'
$runRoot = 'C:\Users\23506\Desktop\anlogic\board_display\td_project\lab_ex5_i2s_v1.0_Runs'

Push-Location (Join-Path $runRoot 'syn_1')
@("source {$tdFlow}", 'exit') | & $tdCli
Pop-Location

Push-Location (Join-Path $runRoot 'phy_1')
@("source {$tdFlow}", 'exit') | & $tdCli
Pop-Location
```

`settings.cfg` 决定各阶段：`syn_1` 从 `read_design` 到 `opt_gate`；`phy_1` 从 `opt_place` 到 `bitgen`，并从 `../syn_1` 导入门级数据库。确认成功时检查 `syn_1/.opt_gate.end.f`、`syn_1/flow.status`、`phy_1/.bitgen.end.f`、`phy_1/route.qor` 和最新 `.bit` 时间戳；不要仅依据进程退出码。

### 本轮显示板构建结果

- 工程：`board_display/td_project/lab_ex5_i2s_v1.0_Runs`
- `syn_1`：约 1 分 27 秒；门级数据库成功生成。
- `phy_1`：约 4 分 12 秒；place、route、bitgen 均完成，bit 时间为 2026-10-25 18:19:51（本地时间）。
- 最终资源：LUT 14,753/19,600（75.27%）；寄存器 9,693/19,600；slice 8,393/9,800（85.64%）；BRAM9K 35/64；BRAM32K 11/16；DSP 18/29；PLL 4/4。
- `route.qor` 最终 setup WNS −5.969 ns、TNS −3.206862 ms、2,366 条 setup 违例；hold WNS −3.188 ns、TNS −78.524 μs、52 条 hold 违例。bitgen 成功不代表这些时序违例消失；板级功能仍需实际验收。
- 显示 bit：`board_display/td_project/lab_ex5_i2s_v1.0_Runs/phy_1/lab_ex5_i2s_v1.0.bit`，SHA-256 `7B5914B5F26D59EC70D0357BED5A088FE5EB5F7FCDB93BE8ACC799A2A1F91E52`。

### 双板 SRAM 下载

从仓库根目录分别执行：

```powershell
.\scripts\program_sram.ps1 -Board display
.\scripts\program_sram.ps1 -Board media
```

`display` 固定使用 cable 0，`media` 固定使用 cable 1；脚本使用 TD CLI 的 `download -mode jtag -bit <绝对路径> -cable N`，通过 `PRG-2014 : Chip validation success`、内部 `program -cable N -mode svf -spd 8 -p` 完成及 `finish command "download ..."` 判定成功。两者均为 SRAM 下载，没有写入 Flash，也没有 UAC 提示。

本轮首次在受限执行环境运行显示板脚本时，Windows 能枚举到两个 `Anlogic usb cable v0.1`（VID `0547`、PID `1002`），但 TD 报 `USB device open error` / `Chip validation failed`，该次判为失败。随后在可访问 USB JTAG 的非沙箱执行环境中，以同一普通用户、同一脚本和同一命令重试成功。TD 仍打印 `create logfile ... failed`（安装目录不可写），但工作区捕获日志正常写入，且下载完整成功；该提示本轮未阻止烧录。

- 显示板 cable 0 成功日志：`boardtest/captures/sram_download/program_display_20261025_182129.log`。bit SHA-256：`7B5914B5F26D59EC70D0357BED5A088FE5EB5F7FCDB93BE8ACC799A2A1F91E52`。
- 媒体板 cable 1 成功日志：`boardtest/captures/sram_download/program_media_20261025_182403.log`。本轮使用仓库已有媒体 bit，SHA-256：`4323E011C0E3941D43D7B77E7631E03DC100853324D8AD716ACC9E976BAC9663`；媒体板 RTL 未在本轮修改。

本记录证明两次 CLI SRAM 下载完成；尚未记录 HDMI 或音频的板级功能验收结果。

## 2026-10-25 音频跨布局保持显示板 bit

在多窗口音频保持阶段，显示板完成综合、布局布线和 bitgen。最后一次显示板资源为 14,810 LUT、8,450 slices、35 BRAM9K、11 BRAM32K、18 DSP、4 PLL；最终 setup/hold WNS 分别为 −5.858 ns / −3.188 ns。 bitgen 成功生成 `board_display/td_project/lab_ex5_i2s_v1.0_Runs/phy_1/lab_ex5_i2s_v1.0.bit`，SHA-256 为 `4E9B4AFDB457983581EAB04DF07FE95D5C644785668F842C048539BDE7EF38C9`。

按 `scripts/program_sram.ps1 -Board display` 下载至 cable 0 成功，日志：`boardtest/captures/sram_download/program_display_20261025_191914.log`。日志包含 `PRG-2014 : Chip validation success: EG4S20BG256`、`program -cable 0 -mode svf -spd 8 -p` 成功结束和完整 `download` 完成。此下载只写 SRAM。随后按用户要求同步重烧媒体板现有 bit 到 cable 1，日志：`boardtest/captures/sram_download/program_media_20261025_192034.log`，同样有 `PRG-2014`、内部 `program -cable 1 -mode svf -spd 8 -p` 和完整 `download` 成功记录。媒体板源码和 bit 内容未变。用户已确认 HDMI/听感符合音频跨布局保持预期。


### 2026-10-25 display SRAM download confirmation（显示板 SRAM 下载复核）

- 新显示板 bit：`board_display/td_project/lab_ex5_i2s_v1.0_Runs/phy_1/lab_ex5_i2s_v1.0.bit`；目标 cable 0。仓库脚本命令：`& 'C:\Users\23506\Desktop\anlogic\scripts\program_sram.ps1' -Board display`。
- 受限沙箱内运行同一脚本时出现 `PRG-9505 ERROR: USB device open error`，随后 `PRG-9525 ERROR: Chip validation failed`；这是进程打开 USB JTAG 设备失败，不能据此判定 bit 无效。
- 使用非沙箱普通用户进程、未请求 UAC，原样重跑同一脚本和同一 bit 后成功：`PRG-2014 : Chip validation success: EG4S20BG256`，`program -cable 0 -mode svf -spd 8 -p` 完成，`download ... -cable 0` 完成，脚本报告 `SRAM download validated`。下载模式为 JTAG SRAM，不写 Flash。
- 本次成功日志：`boardtest/captures/sram_download/program_display_20261025_224522.log`；沙箱失败日志：`boardtest/captures/sram_download/program_display_20261025_224405.log`。同轮未对 cable 1 或媒体板下载。


### 2026-10-25 media subtitle pacing build

The 4 ms subtitle packet-gap build was downloaded to media cable 1 using `& 'C:\Users\23506\Desktop\anlogic\scripts\program_sram.ps1' -Board media`. `PRG-2014 : Chip validation success: EG4S20BG256`, `program -cable 1 -mode svf -spd 8 -p` completed, the `download ... -cable 1` command finished, and the script reported `SRAM download validated`. No UAC was requested and Flash was not written. Log: `boardtest/captures/sram_download/program_media_20261025_235033.log`. This records the download only; it is not a board-level subtitle pass.

### 2026-10-26 subtitle diagnosis rebuild and API test

The 4 ms candidate still failed with `FPGA_ERR=2`, so the media packet gap was restored to 1 ms. The display and media boards were freshly synthesized and routed, then downloaded to SRAM through `scripts/program_sram.ps1`; neither Flash was written.

| Board | Bit | Cable | Final resources | Final setup / hold WNS | Download log |
| --- | --- | ---: | --- | --- | --- |
| Display | `board_display/td_project/lab_ex5_i2s_v1.0_Runs/phy_1/lab_ex5_i2s_v1.0.bit` | 0 | 15,320 LUT; 35 BRAM9K; 11 BRAM32K; 18 DSP; 8,692 slices | -6.538 ns / -2.935 ns | `boardtest/captures/sram_download/program_display_20261026_004211.log` |
| Media | `board_media/td_project/media_net_Runs/phy_1/media_net.bit` | 1 | 13,961 LUT; 19 BRAM9K; 2 BRAM32K; 5 DSP; 7,757 slices | -3.402 ns / -3.188 ns | `boardtest/captures/sram_download/program_media_20261026_004244.log` |

The display returns a compact END rejection reason in the existing `0x0041` ACK value; the media board forwards it in the existing V1 PC subtitle ACK. `DISPLAY_REJECT=0x85` means END checksum-field mismatch, `0x86` means missing DATA, and `DISPLAY_VALUE=0xNN` means the display returned success with a mismatched value/length. These diagnostic codes were covered by `make media-control media-subtitle-roundtrip`; the media roundtrip also verifies successful 13-character commit, three retries, diagnostic propagation, 1 ms packet spacing and PC checksum rejection. PC checks `test_subtitle.py` and `python -m unittest test_console_protocol.py -v` passed.

An end-to-end backend API test called `/api/eth/connect`, then `/api/subtitle` twice with `HELLO WORLD` (11 ASCII characters). Both calls returned HTTP 200 with `{"ok":true,"length":11,"acknowledged":true}`. Thus the previous `FPGA_ERR=2` did not reproduce on the rebuilt pair; the 1 ms interval is retained. This API test used the real UDP link to the FPGA, not a simulated ACK.
