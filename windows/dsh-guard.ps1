# dsh-guard.ps1 — Windows 桌面版的插件体检与三级启动恢复
#
# 为什么不在应用里做：web boot 只要有一个插件没激活，应用就停在 "Failed to load plugins"，
# 插件 ctx 都不存在，没有任何插件跑得起来。
#
# 为什么不做"看日志再救"：桌面版从快捷方式启动时没有控制台。但**我们可以自己启动它并
# 重定向输出**——宿主会打印 "dsh web: http://127.0.0.1:PORT/?token=..."，那就是端口。
# 拿到端口就能判断"到底起没起来"，进而做和 Linux 版一样的分级恢复。
#
# 三级阶梯（每级默认等 120 秒）：
#   1. 启动前体检：用桌面版自带的运行时 import 每个插件，导不进来的先停用；
#   2. 启动后等 120 秒：端口通了就算成功；没起来就干净启动（停用全部第三方插件）再等；
#   3. 还不行：校验安装目录与日志，弹窗告知「harness 可能彻底损坏，建议重装」。
#
# 用法：
#   .\dsh-guard.ps1 -Check                 只体检，不启动、不改任何文件
#   .\dsh-guard.ps1                        体检 → 停用坏插件 → 启动 → 等 120 秒
#   .\dsh-guard.ps1 -NoLaunch              只体检并停用坏插件，不启动
#   .\dsh-guard.ps1 -WaitSec 60            缩短等待
#   .\dsh-guard.ps1 -DshHome D:\x\.dsh     指定 DSH_HOME（默认 %USERPROFILE%\.dsh）
#   .\dsh-guard.ps1 -AppPath "C:\...\DeepSeek Harness.exe"
param(
  [string]$DshHome = (Join-Path $env:USERPROFILE ".dsh"),
  [string]$ProfileName = "web",
  [string]$AppPath = "",
  [switch]$Check,
  [switch]$NoLaunch,
  [int]$WaitSec = 120,
  [int]$GraceSec = 120,
  [string]$Runtime = ""
)

$ErrorActionPreference = "Stop"
$patch = Join-Path $DshHome "profiles\$ProfileName\cordis.patch.yml"
$nodeModules = Join-Path $DshHome "profiles\$ProfileName\node_modules"

function Find-App {
  if ($AppPath -ne "" -and (Test-Path $AppPath)) { return $AppPath }
  $candidates = @()
  if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA "Programs\DeepSeek Harness\DeepSeek Harness.exe") }
  if ($env:PROGRAMFILES) { $candidates += (Join-Path $env:PROGRAMFILES "DeepSeek Harness\DeepSeek Harness.exe") }
  $candidates += "C:\dshdesk\DeepSeek Harness.exe"
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  return ""
}

# patch 里列出的插件：同一行优先取 name（真正的包名），没有 name 的只是 id 覆盖
function Get-Plugins {
  if (-not (Test-Path $patch)) { return @() }
  $lines = Get-Content -LiteralPath $patch
  $out = @()
  $i = 0
  while ($i -lt $lines.Count) {
    if ($lines[$i] -notmatch '^(\s*)-(\s+)') { $i++; continue }
    $dash = ($lines[$i] -replace '^(\s*).*', '$1').Length
    $j = $i + 1
    while ($j -lt $lines.Count) {
      if ($lines[$j].Trim() -eq "") { $j++; continue }
      $indent = ($lines[$j] -replace '^(\s*).*', '$1').Length
      if ($indent -le $dash) { break }
      $j++
    }
    $name = $null
    $id = $null
    for ($k = $i; $k -lt $j; $k++) {
      $mn = [regex]::Match($lines[$k], '^\s*(?:-\s+)?name:\s*[''"]?([@A-Za-z0-9/_.-]+)')
      if ($mn.Success -and -not $name) { $name = $mn.Groups[1].Value }
      $mi = [regex]::Match($lines[$k], '^\s*(?:-\s+)?id:\s*[''"]?([@A-Za-z0-9/_.-]+)')
      if ($mi.Success -and -not $id) { $id = $mi.Groups[1].Value }
    }
    $key = if ($name) { $name } else { $id }
    if ($key -and -not ($out | Where-Object { $_.name -eq $key })) {
      $out += [pscustomobject]@{ name = $key; kind = $(if ($name) { "pkg" } else { "id" }) }
    }
    $i = $j
  }
  return $out
}

function Test-Disabled($name) {
  $lines = Get-Content -LiteralPath $patch
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -notmatch ('^\s*-\s*(?:id|name):\s*[''"]?' + [regex]::Escape($name) + '[''"]?\s*$')) { continue }
    $dash = ($lines[$i] -replace '^(\s*).*', '$1').Length
    for ($j = $i + 1; $j -lt $lines.Count; $j++) {
      if ($lines[$j].Trim() -eq "") { continue }
      $indent = ($lines[$j] -replace '^(\s*).*', '$1').Length
      if ($indent -le $dash) { break }
      if ($lines[$j] -match '^\s*disabled:\s*true\s*$') { return $true }
    }
  }
  return $false
}

function Disable-Plugin($name, [string]$snapshot = "") {
  $lines = Get-Content -LiteralPath $patch
  $out = @()
  $inserted = $false
  $i = 0
  while ($i -lt $lines.Count) {
    $m = [regex]::Match($lines[$i], '^(\s*)-(\s+)')
    if (-not $m.Success) { $out += $lines[$i]; $i++; continue }
    $dash = $m.Groups[1].Length
    $j = $i + 1
    while ($j -lt $lines.Count) {
      if ($lines[$j].Trim() -eq "") { $j++; continue }
      $indent = ($lines[$j] -replace '^(\s*).*', '$1').Length
      if ($indent -le $dash) { break }
      $j++
    }
    for ($k = $i; $k -lt $j; $k++) {
      $out += $lines[$k]
      $hit = [regex]::Match($lines[$k], '^(\s*)(-\s+)?(?:id|name):\s*[''"]?' + [regex]::Escape($name) + '[''"]?\s*$')
      if (-not $hit.Success -or $inserted) { continue }
      $indent = $hit.Groups[1].Length + $(if ($hit.Groups[2].Success) { $hit.Groups[2].Length } else { 0 })
      $rowHas = $false
      for ($q = $i; $q -lt $j; $q++) { if ($lines[$q] -match '^\s*disabled:\s*true\s*$') { $rowHas = $true } }
      if ($rowHas) { $inserted = $true; continue }
      $out += (' ' * $indent) + 'disabled: true'
      $inserted = $true
    }
    $i = $j
  }
  if (-not $inserted) { return $false }
  if (-not $snapshot) { $snapshot = Save-PatchSnapshot "disable-$name" }
  Set-Content -LiteralPath $patch -Value $out -Encoding UTF8
  return $true
}

# ── 改配置之前先留证：带时间戳的快照，而不是单份覆盖 ───────────────────────
# 固定文件名（$patch.bak-guard）在连着自愈两次时，第一次的原文就被覆盖掉了。
function Save-PatchSnapshot([string]$reason) {
  $root = Join-Path $DshHome "guard-snapshots"
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $dir = Join-Path $root "$stamp-$reason"
  $n = 1
  while (Test-Path $dir) { $dir = Join-Path $root "$stamp-$reason-$n"; $n++ }
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Copy-Item -LiteralPath $patch -Destination (Join-Path $dir "cordis.patch.yml") -Force
  Set-Content -LiteralPath (Join-Path $dir "AT") -Value (Get-Date -Format o) -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $dir "REASON") -Value $reason -Encoding UTF8
  $trash = Join-Path $root "trash"
  New-Item -ItemType Directory -Force -Path $trash | Out-Null
  $all = @(Get-ChildItem -Directory -LiteralPath $root |
    Where-Object { $_.Name -ne "trash" -and $_.Name -ne "last-good" } |
    Sort-Object Name)
  if ($all.Count -gt 5) {
    foreach ($old in ($all | Select-Object -First ($all.Count - 5))) {
      Move-Item -LiteralPath $old.FullName -Destination (Join-Path $trash $old.Name) -Force -ErrorAction SilentlyContinue
    }
  }
  return $dir
}

# 最后一次确认可用的配置镜像：出事后先看它。
function Save-GoodSnapshot {
  $dir = Join-Path (Join-Path $DshHome "guard-snapshots") "last-good"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Copy-Item -LiteralPath $patch -Destination (Join-Path $dir "cordis.patch.yml") -Force
  Set-Content -LiteralPath (Join-Path $dir "AT") -Value (Get-Date -Format o) -Encoding UTF8
}

function Get-Entry($dir) {
  $pkg = Join-Path $dir "package.json"
  if (-not (Test-Path $pkg)) { return $null }
  try { $j = Get-Content -LiteralPath $pkg -Raw | ConvertFrom-Json } catch { return $null }
  $e = $j.main
  if (-not $e -and $j.exports) {
    $dot = $j.exports.'.'
    if ($dot -is [string]) { $e = $dot }
    elseif ($dot) { $e = if ($dot.import) { $dot.import } elseif ($dot.default) { $dot.default } elseif ($dot.require) { $dot.require } else { $null } }
  }
  if (-not $e) { $e = "index.js" }
  return (Join-Path $dir $e)
}

function Test-Plugin($name, $runtime) {
  $dir = Join-Path $nodeModules $name
  if (-not (Test-Path $dir)) { return @{ name = $name; state = "missing"; detail = "未安装" } }
  $entry = Get-Entry $dir
  if (-not $entry -or -not (Test-Path $entry)) { return @{ name = $name; state = "noentry"; detail = "缺入口" } }
  $full = (Resolve-Path -LiteralPath $entry).Path
  if ($full -match '^[A-Za-z]:') { $url = "file:///" + ($full -replace '\\', '/') }
  else { $url = "file://" + ($full -replace '\\', '/') }
  $code = "import('$url').then(()=>process.exit(0)).catch(e=>{console.error(String(e&&e.message||e));process.exit(1)})"
  if ($runtime -eq "") { return @{ name = $name; state = "unknown"; detail = "找不到可用的 node/桌面版运行时" } }
  $old = $env:ELECTRON_RUN_AS_NODE
  $env:ELECTRON_RUN_AS_NODE = "1"
  try {
    $out = & $runtime -e $code 2>&1
    $ok = ($LASTEXITCODE -eq 0)
  } finally {
    $env:ELECTRON_RUN_AS_NODE = $old
  }
  if ($ok) { return @{ name = $name; state = "ok"; detail = "可加载" } }
  return @{ name = $name; state = "fail"; detail = ($out -join " ").Substring(0, [Math]::Min(160, ($out -join " ").Length)) }
}

# ── 启动与健康判定 ───────────────────────────────────────────────────────────
function Start-AppWithLog($exe, $log) {
  # 用 Start-Process 重定向：事件回调方式（add_OutputDataReceived）在多线程上跑，
  # PowerShell 没有 Runspace 会直接抛，所以改成写文件 + 轮询。
  $err = "$log.err"
  Remove-Item -LiteralPath $log, $err -ErrorAction SilentlyContinue
  $p = Start-Process -FilePath $exe -RedirectStandardOutput $log -RedirectStandardError $err -PassThru
  return $p
}

function Get-LogText($log) {
  $t = ""
  if (Test-Path $log) { $t += (Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue) }
  if (Test-Path "$log.err") { $t += (Get-Content -LiteralPath "$log.err" -Raw -ErrorAction SilentlyContinue) }
  return $t
}

function Get-ServedPort($log) {
  $text = Get-LogText $log
  $m = [regex]::Matches($text, 'dsh web: http://127\.0\.0\.1:(\d+)')
  if ($m.Count -eq 0) { return 0 }
  return [int]$m[$m.Count - 1].Groups[1].Value
}

function Test-PortUp([int]$port) {
  if ($port -le 0) { return $false }
  try { $null = Invoke-WebRequest -Uri "http://127.0.0.1:$port/" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop; return $true }
  catch { if ($_.Exception.Response) { return $true }; return $false }
}

function Wait-AppHealthy($proc, $log, [int]$sec) {
  $deadline = (Get-Date).AddSeconds($sec)
  while ((Get-Date) -lt $deadline) {
    if ((Get-LogText $log) -match 'did not activate|Failed to load plugins') {
      return @{ ok = $false; reason = "boot-failed" }
    }
    $port = Get-ServedPort $log
    if ($port -gt 0 -and (Test-PortUp $port)) { return @{ ok = $true; port = $port } }
    if ($proc.HasExited) { return @{ ok = $false; reason = "exited" } }
    Start-Sleep -Seconds 2
  }
  return @{ ok = $false; reason = "timeout"; port = (Get-ServedPort $log) }
}

# 「起来了」不等于「好了」：端口通了之后再守一段，期间进程没了或端口掉了都算失败。
function Test-AppSettled($proc, $log, [int]$sec) {
  $deadline = (Get-Date).AddSeconds($sec)
  while ((Get-Date) -lt $deadline) {
    if ((Get-LogText $log) -match 'did not activate|Failed to load plugins') {
      return @{ ok = $false; reason = "boot-failed" }
    }
    if ($proc.HasExited) { return @{ ok = $false; reason = "exited" } }
    $port = Get-ServedPort $log
    if ($port -le 0 -or -not (Test-PortUp $port)) { return @{ ok = $false; reason = "port-down" } }
    Start-Sleep -Seconds 2
  }
  return @{ ok = $true }
}

function Get-Blamed($log) {
  $text = Get-LogText $log
  # 两种语序都认：真日志里既有 "dsh-memory did not activate"，也有反向写法。
  $m = [regex]::Match($text, '([@A-Za-z0-9/_.-]+)\s+did not activate')
  if ($m.Success) { return $m.Groups[1].Value }
  $m = [regex]::Match($text, 'did not activate\s+([@A-Za-z0-9/_.-]+)')
  if ($m.Success) { return $m.Groups[1].Value }
  return ""
}

function Disable-AllThirdParty {
  $snap = Save-PatchSnapshot "clean-start"
  foreach ($row in Get-Plugins) {
    if ($row.kind -ne "pkg") { continue }
    if ($row.name.StartsWith("@")) { continue }
    if (-not (Test-Path (Join-Path $nodeModules $row.name))) { continue }
    if (Test-Disabled $row.name) { continue }
    Disable-Plugin $row.name $snap | Out-Null
    Write-Host "已停用：$($row.name)"
  }
}

# ── 主流程 ───────────────────────────────────────────────────────────────────
if (-not (Test-Path $patch)) {
  Write-Host "没有找到 profile：$patch"
  Write-Host "先启动一次 DSH，或用 -DshHome 指定它真正用的目录。"
  exit 1
}

$app = Find-App
$runtime = if ($Runtime -ne "") { $Runtime } elseif ($app -ne "") { $app } elseif (Get-Command node -ErrorAction SilentlyContinue) { (Get-Command node).Source } else { "" }

Write-Host "profile : $patch"
Write-Host "runtime : $(if ($app -ne '') { $app } else { $runtime })"

$bad = @()
foreach ($row in Get-Plugins) {
  $name = $row.name
  if ($row.kind -eq "id") { Write-Host ("engine  : {0,-28} id 覆盖（不是包）" -f $name); continue }
  if ($name.StartsWith("@")) { Write-Host ("engine  : {0,-28} core（在桌面版安装目录里）" -f $name); continue }
  if (Test-Disabled $name) { Write-Host ("engine  : {0,-28} disabled" -f $name); continue }
  $r = Test-Plugin $name $runtime
  Write-Host ("engine  : {0,-28} {1}  {2}" -f $name, $r.state, $r.detail)
  # fail=导入就抛；noentry=package.json 指的入口文件不存在；missing=patch 里有、盘上没有。
  # 后两种同样会让 boot 停在 "Failed to load plugins"，所以一样要停用。
  if ($r.state -in @("fail", "noentry", "missing")) { $bad += $name }
}

if ($Check) { exit 0 }

# 第一级：启动前停用导不进来的插件
if ($bad.Count -gt 0) {
  foreach ($name in $bad) { if (Disable-Plugin $name) { Write-Host "已停用：$name（改动前已快照）" } }
  if ($IsWindows -ne $false) {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [System.Windows.Forms.MessageBox]::Show(
      "这些插件无法被加载，已自动停用：`n`n" + ($bad -join "`n") + "`n`n如果这是刚更新的插件，去它的 Releases 下载新版。",
      "DSH 插件体检", "OK", "Warning") | Out-Null
  } else { Write-Host ("无法加载的插件：" + ($bad -join "、")) }
}

if ($NoLaunch -or $app -eq "") { exit 0 }

$log = Join-Path ([System.IO.Path]::GetTempPath()) "dsh-desktop-guard.log"

function Launch-And-Wait($label) {
  $p = Start-AppWithLog $app $log
  $h = Wait-AppHealthy $p $log $WaitSec
  if ($h.ok) {
    $settled = Test-AppSettled $p $log $GraceSec
    if (-not $settled.ok) {
      Write-Host ("{0}：端口通了，但宽限期里倒下了（{1}）" -f $label, $settled.reason)
      $h = @{ ok = $false; reason = "grace:" + $settled.reason; port = $h.port }
    }
  }
  Write-Host ("{0}：{1} {2}" -f $label, $h.ok, $(if ($h.ok) { "端口 " + $h.port } else { $h.reason }))
  return @{ proc = $p; health = $h }
}

# 第一轮：启动（导入坏掉的插件已在体检阶段停用）
$r = Launch-And-Wait "启动结果"
if ($r.health.ok) { Save-GoodSnapshot; exit 0 }
$blamed = Get-Blamed $log
try { $r.proc.Kill() } catch { }

# 第二轮：停用日志点名的插件，再等一轮
if ($blamed -and -not (Test-Disabled $blamed)) {
  Write-Host "日志点名：$blamed —— 停用它再试"
  if (Disable-Plugin $blamed) { Write-Host "已停用：$blamed（改动前已快照）" }
  $r = Launch-And-Wait "停用后启动结果"
  if ($r.health.ok) { Save-GoodSnapshot; exit 0 }
  try { $r.proc.Kill() } catch { }
} else {
  Write-Host "日志没有点名任何插件（或已停用），直接干净启动"
}

# 第三轮：干净启动（停用全部第三方插件）
Write-Host "尝试干净启动：停用全部第三方插件"
Disable-AllThirdParty
$r = Launch-And-Wait "干净启动结果"
if ($r.health.ok) { Save-GoodSnapshot; exit 0 }
try { $r.proc.Kill() } catch { }

# 第四轮：校验安装与日志，交给人
$diag = @("安装目录：" + $(if ($app) { $app } else { "找不到" }), "profile：" + $patch)
if ($app) {
  $verFile = Join-Path (Split-Path $app) "version"
  if (Test-Path $verFile) { $diag += "外壳版本：" + (Get-Content $verFile -Raw).Trim() }
}
$tail = ((Get-LogText $log) -split "`n" | Select-Object -Last 5) -join " / "
if ($tail) { $diag += "日志尾部：" + $tail }
Write-Host ($diag -join "`n")
if ($IsWindows -ne $false) {
  Add-Type -AssemblyName System.Windows.Forms | Out-Null
  [System.Windows.Forms.MessageBox]::Show(
    "停用插件、干净启动都没能让它起来，问题大概不在插件，而在 harness 本身。`n`n" + ($diag -join "`n") + "`n`n建议重新安装。",
    "DSH 可能彻底损坏", "OK", "Warning") | Out-Null
}
exit 1
