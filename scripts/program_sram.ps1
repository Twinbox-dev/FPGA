[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('display', 'media')]
    [string]$Board,
    # Optional isolated diagnostic build; the target cable still follows Board.
    [string]$CandidateBit
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$tdBin = 'C:\Program Files\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin'
$tdCli = Join-Path $tdBin 'td_commands_prompt.exe'
$captureRoot = Join-Path $repoRoot 'boardtest\captures\sram_download'

switch ($Board) {
    'display' {
        $cable = 0
        $bitPath = Join-Path $repoRoot 'board_display\td_project\lab_ex5_i2s_v1.0_Runs\phy_1\lab_ex5_i2s_v1.0.bit'
    }
    'media' {
        $cable = 1
        $bitPath = Join-Path $repoRoot 'board_media\td_project\media_net_Runs\phy_1\media_net.bit'
    }
}

if ($CandidateBit) {
    $bitPath = (Resolve-Path -LiteralPath $CandidateBit -ErrorAction Stop).Path
}

if (-not (Test-Path -LiteralPath $tdCli -PathType Leaf)) {
    throw "TD CLI not found: $tdCli"
}
if (-not (Test-Path -LiteralPath $bitPath -PathType Leaf)) {
    throw "Bit file not found: $bitPath"
}

New-Item -ItemType Directory -Force -Path $captureRoot | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$batchPath = Join-Path $captureRoot "program_${Board}_${stamp}.bat"
$logPath = Join-Path $captureRoot "program_${Board}_${stamp}.log"
$bitForTcl = $bitPath.Replace('\', '/')
$downloadCommand = "download -mode jtag -bit $bitForTcl -cable $cable"

@"
@echo off
(
  echo $downloadCommand
  echo exit
) | "$tdCli" > "$logPath" 2>&1
"@ | Set-Content -LiteralPath $batchPath -Encoding ascii

$bitHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $bitPath).Hash
Write-Output "Board: $Board (cable $cable)"
Write-Output "Bit: $bitPath"
Write-Output "SHA-256: $bitHash"
Write-Output "Command: $downloadCommand"
Write-Output 'Starting TD CLI from its bin directory without requesting UAC elevation.'

# Low-integrity sandbox processes cannot open the JTAG USB interface. A normal
# medium-integrity user process works when launched from TD's bin directory.
$cmdArguments = "/c `"$batchPath`""
$process = Start-Process -FilePath $env:ComSpec -WindowStyle Hidden `
    -WorkingDirectory $tdBin -ArgumentList $cmdArguments -PassThru -Wait

if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
    throw "TD produced no log; download result is unknown. Expected log: $logPath"
}
$logText = Get-Content -LiteralPath $logPath -Raw
Write-Output $logText

$hasChipValidation = $logText -match 'PRG-2014\s*:\s*Chip validation success'
$hasProgramFinish = $logText -match "finish command `"program -cable $cable -mode svf -spd [0-9]+ -p`""
$hasDownloadFinish = $logText -match 'finish command "download '
$hasFailure = $logText -match '(?i)ERROR|USB device open error|Chip validation failed'

if (-not ($hasChipValidation -and $hasProgramFinish -and $hasDownloadFinish) -or $hasFailure) {
    throw "SRAM download failed validation. Review log: $logPath"
}

Write-Output "SRAM download validated. TD process exit code: $($process.ExitCode)"
Write-Output "Log: $logPath"
