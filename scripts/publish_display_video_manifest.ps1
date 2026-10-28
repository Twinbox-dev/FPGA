[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InputsJson,
    [Parameter(Mandatory=$true)][string]$RouteLog
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$inputPath=(Resolve-Path $InputsJson).Path
$routePath=(Resolve-Path $RouteLog).Path
$inputs=@(Get-Content -LiteralPath $inputPath -Raw | ConvertFrom-Json)
foreach($item in $inputs){
    $path=Join-Path $root $item.path
    if((Get-FileHash -LiteralPath $path).Hash -ne $item.sha256){throw "Input changed: $($item.path)"}
}
$route=Get-Content -LiteralPath $routePath -Raw
if($route -match '(?im)\bERROR:|\bError occurred|\bFailed to|RUN-8102 ERROR') {throw 'P&R evidence contains an error'}
$runs=Join-Path $root 'board_display\td_project\lab_ex5_i2s_v1.0_Runs'
$phy=Join-Path $runs 'phy_1'
$bit=Join-Path $phy 'lab_ex5_i2s_v1.0.bit'
foreach($marker in @('.opt_place.begin.f','.opt_route.begin.f','.bitgen.begin.f')){
    if((Get-Item (Join-Path $phy $marker)).LastWriteTimeUtc -gt (Get-Item $bit).LastWriteTimeUtc){throw "Stale bit after $marker"}
}
$sourceAl=Get-Content (Join-Path $root 'board_display\td_project\lab_ex5_i2s_v1.0.al') -Raw
$seedMatch=[regex]::Match($sourceAl,'(?s)<Run Name="phy_1".*?<seed>(\d+)</seed>')
if(-not $seedMatch.Success){throw 'No saved physical placement seed in project'}
$profile=Get-Content (Join-Path $root 'scripts\direct_video_profile.json') -Raw | ConvertFrom-Json
$flow='C:\Program Files\Anlogic\TD_6.2.1_Engineer_6.2.168.116\doc\scripts\DefaultFlow.tcl'
$manifest=[PSCustomObject]@{
    built_at=(Get-Item $bit).LastWriteTime.ToString('o')
    product_baseline='dual-V3-beta';cleanroom_reference='ba1f949';strategy='area'
    bit='board_display/td_project/lab_ex5_i2s_v1.0_Runs/phy_1/lab_ex5_i2s_v1.0.bit'
    bit_sha256=(Get-FileHash -LiteralPath $bit).Hash
    profile=@{width=[int]$profile.width;height=[int]$profile.height;window=[int]$profile.window;head_rows=[int]$profile.head_rows;audio='24k_u8_mono';statistics=0;link_diagnostics=0;cv_enabled=[bool]$profile.cv_enabled;cv_neighborhood_enabled=[bool]$profile.cv_neighborhood_enabled;spectrum_enabled=[bool]$profile.spectrum_enabled}
    gate_overrides=@('opt_area=high','pack_effort=high','map_mode=area_prior')
    place_overrides=@('pr_strategy=2','effort=high',"seed=$($seedMatch.Groups[1].Value)")
    sdk_flow_sha256=(Get-FileHash -LiteralPath $flow).Hash
    sources=$inputs
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $root 'board_display\td_project\video_build_manifest.json')
Write-Output "Published source/bit manifest for $($manifest.built_at)"
