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
$defaultFlow = Join-Path $tdRoot "doc\scripts\DefaultFlow.tcl"
$runRoot = "C:\Users\23506\Desktop\anlogic\board_display\td_project\lab_ex5_i2s_v1.0_Runs"

Push-Location (Join-Path $runRoot "syn_1")
& $tdCli $defaultFlow
$synExitCode = $LASTEXITCODE
Pop-Location
if ($synExitCode -ne 0) { throw "TD synthesis failed: $synExitCode" }

Push-Location (Join-Path $runRoot "phy_1")
& $tdCli $defaultFlow
$phyExitCode = $LASTEXITCODE
Pop-Location
if ($phyExitCode -ne 0) { throw "TD place/route or bitgen failed: $phyExitCode" }
```

这是主仓库 TD 工程实际调用的 CLI 与 flow；现有 `run.bat` 也调用同一个 TD flow。
检查结束状态时查看本轮日志、`flow.status`、最新时序/资源报告和 bit 文件时间，
不要只看目录中是否存在旧的成功标记。

## JTAG SRAM 下载

TD 命令行通过 Tcl 脚本执行下载。将下面的命令放入一个 `.tcl` 文件：

```tcl
download -mode jtag -bit "C:/path/to/current_project.bit"
```

以显示板 bit 为例，文件路径使用本轮 `phy_1` 输出的
`lab_ex5_i2s_v1.0.bit`；媒体板则使用其本轮 `media_net.bit`。
将 Tcl 文件交给同一个 TD 命令提示程序：

```powershell
& $tdCli "C:/path/to/program_sram.tcl"
```

传给 CLI 的 Tcl 脚本路径也应使用正斜杠。若路径来自 Windows 文件 API，先用
`.Replace('\', '/')` 转换；原始反斜杠可能被 Tcl 当成转义符，导致脚本路径解析错误。
CLI 遇到“couldn't read file”时仍可能以退出码 0 结束，因此下载验收还须检查日志里
器件验证成功，以及 `finish command "program ..."` 和 `finish command "download ..."`，
不能仅依据 `$LASTEXITCODE` 判断已烧录。

本机实际执行该命令时，TD 检查了器件 ID，随后生成 JTAG burst 数据并调用
`program -mode svf -p` 完成下载。没有调用 `program_spi` 或 Program Flash；
这是配置 SRAM 下载，掉电后需重新配置。未显式提供 `-cable` 时，本机使用 cable 0；
连接多个下载线时可按 CLI 帮助指定 `-cable <integer>`。设备 ID 只能识别器件型号，
不能识别它在项目中承担显示板还是媒体板的角色，下载前应确认 JTAG 线接到目标板。

## 后续自动化

本仓库两侧工程的综合和布局布线都由 TD `DefaultFlow.tcl` 的项目设置驱动；
SRAM 下载也已找到可执行的 CLI 命令。下一步可将上述流程封装成脚本：每阶段检查
返回码、报告时间和新 bit 时间，随后启动对应的板级/PC 验证入口。JTAG 连接和板卡
供电仍是实体操作；CLI 下载不等于功能验收或时序收敛。
