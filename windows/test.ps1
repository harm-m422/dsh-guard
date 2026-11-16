# dsh-guard Windows 版的测试。
#
# 在 Linux 上也能跑（pwsh 7 + python3 提供真端口），但**它不能代替 Windows 实测**：
# Start-Process 重定向、桌面版 exe 的路径探测、GUI 弹窗，这些只有真 Windows 能验。
# 这里覆盖的是逻辑层：快照轮转、宽限期、停用幂等、-Check。
#
#   pwsh -NoProfile -File test.ps1
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$guard = Join-Path $here "dsh-guard.ps1"
$results = @()

function Check([string]$name, [bool]$ok, [string]$detail = "") {
  $script:results += [pscustomobject]@{ ok = $ok; name = $name; detail = $detail }
}

function New-Sandbox {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("wguard-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
  $homeDir = Join-Path $root ".dsh"
  $profileDir = Join-Path $homeDir "profiles/web"
  New-Item -ItemType Directory -Force -Path (Join-Path $profileDir "node_modules") | Out-Null
  return [pscustomobject]@{ root = $root; home = $homeDir; profile = $profileDir; patch = (Join-Path $profileDir "cordis.patch.yml") }
}

function Add-Plugin($box, [string]$name, [bool]$broken = $false) {
  $dir = Join-Path $box.profile "node_modules/$name"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Set-Content -LiteralPath (Join-Path $dir "package.json") -Value ('{"name":"' + $name + '","version":"1.0.0","main":"index.js"}') -Encoding UTF8
  if (-not $broken) { Set-Content -LiteralPath (Join-Path $dir "index.js") -Value "export default {}" -Encoding UTF8 }
}

function Set-Patch($box, [string]$text) { Set-Content -LiteralPath $box.patch -Value $text -Encoding UTF8 }

function Run-Guard($box, [string[]]$extra = @()) {
  $out = & pwsh -NoProfile -File $guard -DshHome $box.home @extra 2>&1 | Out-String
  return [pscustomobject]@{ code = $LASTEXITCODE; out = $out }
}

function Get-Snapshots($box) {
  $dir = Join-Path $box.home "guard-snapshots"
  if (-not (Test-Path $dir)) { return @() }
  return @(Get-ChildItem -Directory -LiteralPath $dir | Where-Object { $_.Name -notin @("trash", "last-good") } | Sort-Object Name)
}

$patchBase = @"
# 用户自己的注释，必须原样保留
- id: ui-settings-general
  name: "@deepseek-ai/dsh-client-ui-settings-general"
- insert:
    - id: demo-plugin
      name: demo-plugin
"@

# ── 1. 体检 ─────────────────────────────────────────────────────────────────
$box = New-Sandbox
Add-Plugin $box "demo-plugin"
Set-Patch $box $patchBase
$r = Run-Guard $box @("-Check")
Check "体检：能加载的插件报 ok" ($r.out -match "ok") $r.out.Trim().Split("`n")[-1]

$box = New-Sandbox
Add-Plugin $box "demo-plugin" $true
Set-Patch $box $patchBase
$r = Run-Guard $box @("-Check")
Check "体检：缺入口要点出来" ($r.out -match "noentry") $r.out.Trim().Split("`n")[-1]

# ── 2. 快照（A） ────────────────────────────────────────────────────────────
$box = New-Sandbox
Add-Plugin $box "demo-plugin" $true
Set-Patch $box $patchBase
$r = Run-Guard $box @("-NoLaunch")
$text = Get-Content -LiteralPath $box.patch -Raw
$snaps = Get-Snapshots $box
Check "快照：停用坏插件时落一份" ($snaps.Count -eq 1) ("$($snaps.Count) 份")
$first = if ($snaps.Count -gt 0) { $snaps[0].Name } else { "" }
$firstText = if ($first) { Get-Content -LiteralPath (Join-Path $box.profile "..\..\guard-snapshots\$first\cordis.patch.yml") -Raw -ErrorAction SilentlyContinue } else { "" }
Check "快照：存的是改动前的原文" ($firstText -match "demo-plugin" -and -not ($firstText -match "disabled:\s*true")) "ok"
Check "快照：不再写固定 .bak-guard" (-not (Test-Path "$($box.patch).bak-guard")) ""

# 第二次：把 patch 恢复成"启用"再跑一次，第一次的快照必须还在
Add-Plugin $box "demo-plugin" $true
Set-Patch $box $patchBase
$r = Run-Guard $box @("-NoLaunch")
$snaps2 = Get-Snapshots $box
$still = if ($first) { Get-Content -LiteralPath (Join-Path $box.home "guard-snapshots/$first/cordis.patch.yml") -Raw -ErrorAction SilentlyContinue } else { "" }
Check "快照：连着两次得到两份" ($snaps2.Count -ge 2) ("$($snaps2.Count) 份")
Check "快照：第一份没被覆盖（A 的核心）" ($still -eq $firstText) $(if ($still -eq $firstText) { "同一份字节" } else { "被覆盖" })

# ── 3. 宽限期（B） ──────────────────────────────────────────────────────────
function New-FakeApp([string]$path, [int]$port, [bool]$crash) {
  $serve = if ($crash) { "timeout 1 python3 -m http.server $port --bind 127.0.0.1 >/dev/null 2>&1" } else { "python3 -m http.server $port --bind 127.0.0.1 >/dev/null 2>&1" }
  $body = "#!/usr/bin/env bash" + "`n" + "echo 'dsh web: http://127.0.0.1:$port/?token=x'" + "`n" + $serve + "`n"
  Set-Content -LiteralPath $path -Value $body -Encoding UTF8 -NoNewline
  & chmod +x $path
}

function Get-FreePort {
  for ($i = 0; $i -lt 40; $i++) {
    $port = Get-Random -Minimum 41000 -Maximum 46000
    $busy = & bash -c "ss -ltnH 'sport = :$port' 2>/dev/null | grep -q LISTEN" 2>$null
    if ($LASTEXITCODE -ne 0) { return $port }
  }
  return 44999
}

# 只有 @core 行：体检不会去 import 任何东西
$quietPatch = @"
- id: ui-settings-general
  name: "@deepseek-ai/dsh-client-ui-settings-general"
"@

$box = New-Sandbox
Set-Patch $box $quietPatch
$port = Get-FreePort
$fake = Join-Path $box.root "fake-crash.sh"
New-FakeApp $fake $port $true
$r = Run-Guard $box @("-AppPath", $fake, "-WaitSec", "6", "-GraceSec", "4", "-Runtime", "python3")
$good = Test-Path (Join-Path $box.home "guard-snapshots/last-good/cordis.patch.yml")
Check "宽限期：起来又崩的不算成功" ($r.code -ne 0) ("退出码 " + $r.code)
Check "宽限期：不写 last-good" (-not $good) $(if ($good) { "写了（错）" } else { "没写" })
& bash -c "pkill -f 'http.server $port' 2>/dev/null" 2>$null | Out-Null

$box = New-Sandbox
Set-Patch $box $quietPatch
$port = Get-FreePort
$fake = Join-Path $box.root "fake-stable.sh"
New-FakeApp $fake $port $false
$r = Run-Guard $box @("-AppPath", $fake, "-WaitSec", "8", "-GraceSec", "3", "-Runtime", "python3")
$good = Join-Path $box.home "guard-snapshots/last-good/cordis.patch.yml"
Check "宽限期：稳定服务才算好" ($r.code -eq 0) ("退出码 " + $r.code)
Check "宽限期：好的那份进 last-good" (Test-Path $good) $good
& bash -c "pkill -f 'http.server $port' 2>/dev/null" 2>$null | Out-Null

# ── 汇总 ────────────────────────────────────────────────────────────────────
$failed = @($results | Where-Object { -not $_.ok })
foreach ($one in $results) {
  $mark = if ($one.ok) { "ok   " } else { "FAIL " }
  $suffix = if ($one.detail) { "   [" + $one.detail + "]" } else { "" }
  Write-Host ($mark + $one.name + $suffix)
}
Write-Host ""
Write-Host ("{0}/{1} passed" -f ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
