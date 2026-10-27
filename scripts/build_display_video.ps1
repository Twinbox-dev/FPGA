[CmdletBinding()]
param([ValidateSet('baseline', 'area')][string]$Strategy = 'baseline')

$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskRuns = Join-Path $taskRoot 'board_display\td_project\lab_ex5_i2s_v1.0_Runs'
$taskCli = 'C:\Program Files\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin\td_commands_prompt.exe'
$taskFlow = 'C:/Program Files/Anlogic/TD_6.2.1_Engineer_6.2.168.116/doc/scripts/DefaultFlow.tcl'
$taskStamp = Get-Date -Format yyyyMMdd_HHmmss
$taskOutput = Join-Path $taskRoot "boardtest\captures\video_integration\build_$taskStamp"
New-Item -ItemType Directory -Path $taskOutput -Force | Out-Null

# Baseline uses the stable tag's default strategy. Area mode is explicit and
# requires the matching GUI strategy to have been saved in the .al project.
$taskProjectText = Get-Content (Join-Path $taskRoot 'board_display\td_project\lab_ex5_i2s_v1.0.al') -Raw
if (($Strategy -eq 'baseline') -and ($taskProjectText -match '<map_mode>area_prior</map_mode>')) {
    throw 'Restore the stable default project strategy before a baseline build'
}
if (($Strategy -eq 'area') -and ($taskProjectText -notmatch '<map_mode>area_prior</map_mode>')) {
    throw 'Save the matching area strategy in the GUI project before an area build'
}
foreach ($taskStage in @('syn_1', 'phy_1')) {
    $taskCfg = Join-Path $taskRuns "$taskStage\settings.cfg"
    $taskName = if ($taskStage -eq 'syn_1') { 'synWildParams' } else { 'phyWildParams' }
    $taskText = Get-Content -LiteralPath $taskCfg -Raw
    $taskText = [regex]::Replace($taskText, '(?s)\r?\n# BEGIN VIDEO AREA OVERRIDES.*?# END VIDEO AREA OVERRIDES\r?\n?', '')
    $taskBlock = "`n# BEGIN VIDEO AREA OVERRIDES`nif {![info exists $taskName]} {set $taskName {}}`nlappend $taskName gate opt_area high gate pack_effort high gate map_mode area_prior`n# END VIDEO AREA OVERRIDES`n"
    if ($taskStage -eq 'phy_1') {
        $taskBlock = $taskBlock.Replace('# END VIDEO AREA OVERRIDES', "lappend $taskName place pr_strategy 2 place effort high place seed 3`n# END VIDEO AREA OVERRIDES")
    }
    if ($Strategy -eq 'baseline') { $taskBlock = '' }
    [IO.File]::WriteAllText($taskCfg, $taskText + $taskBlock, [Text.UTF8Encoding]::new($false))
}

$taskFiles = @(Get-ChildItem (Join-Path $taskRoot 'board_display\user_source') -Recurse -File)
$taskFiles += Get-Item (Join-Path $taskRoot 'board_display\td_project\lab_ex5_i2s_v1.0.al')
foreach ($taskStage in @('syn_1', 'phy_1')) {
    $taskFiles += Get-Item (Join-Path $taskRuns "$taskStage\settings.cfg")
    $taskFiles += Get-Item (Join-Path $taskRuns "$taskStage\lab_ex5_i2s_v1.0.prj")
}
$taskFiles += Get-Item $PSCommandPath
$taskProfilePath = Join-Path $taskRoot 'scripts\direct_video_profile.json'
$taskFiles += Get-Item $taskProfilePath
$taskPcProfile = Get-Content -LiteralPath $taskProfilePath -Raw | ConvertFrom-Json
$taskTopText = Get-Content (Join-Path $taskRoot 'board_display\user_source\hdl_source\top_tf_hdmi_audio.v') -Raw
$taskWidthMatch = [regex]::Match($taskTopText, 'parameter DIRECT_VIDEO_WIDTH = (\d+)')
$taskHeightMatch = [regex]::Match($taskTopText, 'parameter DIRECT_VIDEO_HEIGHT = (\d+)')
$taskCvEnabled = [int]([regex]::Match($taskTopText, 'parameter PRODUCT_CV_ENABLED = ([01])').Groups[1].Value)
$taskSpectrumEnabled = [int]([regex]::Match($taskTopText, 'parameter PRODUCT_SPECTRUM_ENABLED = ([01])').Groups[1].Value)
if (-not $taskWidthMatch.Success -or -not $taskHeightMatch.Success -or
    [int]$taskPcProfile.width -ne [int]$taskWidthMatch.Groups[1].Value -or
    [int]$taskPcProfile.height -ne [int]$taskHeightMatch.Groups[1].Value) {
    throw 'PC video dimensions differ from display RTL; update both before building'
}
if ([bool]$taskPcProfile.cv_enabled -ne [bool]$taskCvEnabled -or [bool]$taskPcProfile.spectrum_enabled -ne [bool]$taskSpectrumEnabled) {
    throw 'PC capability profile differs from display RTL; update both before building'
}
$taskSources = @($taskFiles | Sort-Object FullName -Unique | ForEach-Object {
    [PSCustomObject]@{
        path = $_.FullName.Substring($taskRoot.Length + 1).Replace('\', '/')
        sha256 = (Get-FileHash -LiteralPath $_.FullName).Hash
    }
})
$taskSources | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $taskOutput 'inputs.json') -Encoding utf8

foreach ($taskStage in @('syn_1', 'phy_1')) {
    $taskLog = Join-Path $taskOutput "$taskStage.log"
    Push-Location (Join-Path $taskRuns $taskStage)
    try {
        @("source {$taskFlow}", 'exit') | & $taskCli > $taskLog 2>&1
        $taskExit = $LASTEXITCODE
    } finally { Pop-Location }
    $taskResult = Get-Content -LiteralPath $taskLog -Raw
    if ($taskExit -ne 0 -or $taskResult -match '(?im)\bERROR:|\bError occurred|\bFailed to') {
        throw "TD $taskStage failed; inspect $taskLog"
    }
    Write-Output "$taskStage completed: $taskLog"
}

foreach ($taskSource in $taskSources) {
    if ((Get-FileHash -LiteralPath (Join-Path $taskRoot $taskSource.path)).Hash -ne $taskSource.sha256) {
        throw "Source/config changed during build: $($taskSource.path)"
    }
}
$taskBit = Join-Path $taskRuns 'phy_1\lab_ex5_i2s_v1.0.bit'
if (-not (Test-Path -LiteralPath $taskBit)) { throw 'Bit generation did not produce an output' }
foreach ($taskMarker in @('.opt_place.begin.f', '.opt_route.begin.f', '.bitgen.begin.f')) {
    if ((Get-Item (Join-Path $taskRuns "phy_1\$taskMarker")).LastWriteTimeUtc -gt (Get-Item $taskBit).LastWriteTimeUtc) {
        throw 'Stale bit: stage-start marker is newer than bit; refusing manifest publication'
    }
}
$taskDiagMatch = [regex]::Match((Get-Content (Join-Path $taskRoot 'board_display\user_source\hdl_source\top_tf_hdmi_audio.v') -Raw), 'parameter VIDEO_LINK_DIAGNOSTICS = ([01])')
if (-not $taskDiagMatch.Success) { throw 'Cannot identify diagnostic profile' }
$taskManifest = [PSCustomObject]@{
    built_at = (Get-Date).ToString('o')
    product_baseline = 'dual-V3-beta'
    cleanroom_reference = 'ba1f949'
    strategy = $Strategy
    bit = 'board_display/td_project/lab_ex5_i2s_v1.0_Runs/phy_1/lab_ex5_i2s_v1.0.bit'
    bit_sha256 = (Get-FileHash -LiteralPath $taskBit).Hash
    profile = @{ width=[int]$taskPcProfile.width; height=[int]$taskPcProfile.height; window=[int]$taskPcProfile.window; head_rows=[int]$taskPcProfile.head_rows; audio='24k_u8_mono'; statistics=0; link_diagnostics=[int]$taskDiagMatch.Groups[1].Value; cv_enabled=[bool]$taskCvEnabled; spectrum_enabled=[bool]$taskSpectrumEnabled }
    gate_overrides = @(if ($Strategy -eq 'area') { 'opt_area=high'; 'pack_effort=high'; 'map_mode=area_prior' })
    place_overrides = @(if ($Strategy -eq 'area') { 'pr_strategy=2'; 'effort=high'; 'seed=3' })
    sdk_flow_sha256 = (Get-FileHash -LiteralPath $taskFlow).Hash
    sources = $taskSources
}
$taskManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $taskRoot 'board_display\td_project\video_build_manifest.json') -Encoding utf8
Get-Content (Join-Path $taskRuns 'phy_1\lab_ex5_i2s_v1.0_phy.area') -First 31
Get-Content (Join-Path $taskRuns 'phy_1\lab_ex5_i2s_v1.0_phy.ts')
Write-Output 'Video candidate built. Programming and board acceptance remain separate steps.'
