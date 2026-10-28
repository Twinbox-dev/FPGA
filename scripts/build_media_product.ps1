[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$runRoot = Join-Path $root 'board_media\td_project\media_net_Runs'
$project = Join-Path $root 'board_media\td_project\media_net.al'
$cli = 'C:\Program Files\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin\td_commands_prompt.exe'
$flow = 'C:/Program Files/Anlogic/TD_6.2.1_Engineer_6.2.168.116/doc/scripts/DefaultFlow.tcl'
$out = Join-Path $root ('boardtest\captures\media_build_' + (Get-Date -Format yyyyMMdd_HHmmss))
New-Item -ItemType Directory -Force -Path $out | Out-Null
if ((Get-Content $project -Raw) -notmatch '<seed>3</seed>') { throw 'Media project must use placement seed 3' }
$cfg = Join-Path $runRoot 'phy_1\settings.cfg'
$configText = Get-Content $cfg -Raw
if ($configText -notmatch 'lappend phyWildParams place seed 3') {
    if ($configText -match 'place\s+seed\s+\d+') { throw 'Conflicting media CLI placement seed' }
    $configText += "`n# Match the media_net.al placement seed for CLI builds.`nif {![info exists phyWildParams]} {set phyWildParams {}}`nlappend phyWildParams place seed 3`n"
    [IO.File]::WriteAllText($cfg, $configText, [Text.UTF8Encoding]::new($false))
}
$inputs = @(Get-ChildItem (Join-Path $root 'board_media\user_source') -File -Recurse)
$inputs += Get-Item $project
foreach ($stage in @('syn_1', 'phy_1')) {
    $inputs += Get-Item (Join-Path $runRoot "$stage\settings.cfg")
    $inputs += Get-Item (Join-Path $runRoot "$stage\media_net.prj")
}
$hashes = @($inputs | Sort-Object FullName -Unique | ForEach-Object {
    [PSCustomObject]@{path=$_.FullName.Substring($root.Length+1).Replace('\','/'); sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}
})
foreach ($stage in @('syn_1', 'phy_1')) {
    $log = Join-Path $out "$stage.log"
    Push-Location (Join-Path $runRoot $stage)
    try { @("source {$flow}", 'exit') | & $cli > $log 2>&1; $result = $LASTEXITCODE }
    finally { Pop-Location }
    if ($result -ne 0 -or (Get-Content $log -Raw) -match '(?im)\bERROR:|\bError occurred|\bFailed to') { throw "Media $stage failed: $log" }
    Write-Output "Media $stage complete: $log"
}
foreach ($item in $hashes) {
    if ((Get-FileHash -LiteralPath (Join-Path $root $item.path)).Hash -ne $item.sha256) { throw "Input changed: $($item.path)" }
}
$bit = Join-Path $runRoot 'phy_1\media_net.bit'
foreach ($marker in @('.opt_place.begin.f', '.opt_route.begin.f', '.bitgen.begin.f')) {
    if ((Get-Item (Join-Path $runRoot "phy_1\$marker")).LastWriteTimeUtc -gt (Get-Item $bit).LastWriteTimeUtc) { throw 'Stale media bit' }
}
$manifest = [PSCustomObject]@{
    built_at=(Get-Date).ToString('o'); placement_seed=3;
    bit='board_media/td_project/media_net_Runs/phy_1/media_net.bit';
    bit_sha256=(Get-FileHash -LiteralPath $bit).Hash;
    sdk_flow_sha256=(Get-FileHash -LiteralPath $flow).Hash; sources=$hashes
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $root 'board_media\td_project\media_build_manifest.json')
Get-Content (Join-Path $runRoot 'phy_1\media_net_phy.area') -First 32
Get-Content (Join-Path $runRoot 'phy_1\media_net_phy.ts')
