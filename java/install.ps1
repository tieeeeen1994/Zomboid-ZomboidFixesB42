# Zomboid Fixes B42, Java part: installer for Windows (the game, or a dedicated server). Close the game first.
#   powershell -ExecutionPolicy Bypass -File install.ps1               install or update
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall    remove
#   ... -Dir "D:\Games\ProjectZomboid"                                 a game folder it does not find by itself
# It copies zfix-agent.jar and launch.cmd from this folder to <game>\ZomboidFixesB42\ (java.ini only when there is none,
# so your choices stay), adds -javaagent:ZomboidFixesB42/zfix-agent.jar to ProjectZomboid64.json (right after
# PZ Optimization's agent when it is installed) and to the server start files, and prints the Steam launch option.
# Steam's Verify integrity and game updates rewrite ProjectZomboid64.json: run it again after them.
param([switch]$Uninstall, [string]$Dir)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ours = '-javaagent:ZomboidFixesB42/zfix-agent.jar'
$pzopt = '-javaagent:pzopt/agent/pzopt-agent.jar'

# The Workshop folder sits in the Steam library that holds the game: ...\steamapps\workshop\content\108600\<id>\...
function Find-Game {
  if ($Dir) { return $Dir }
  $p = $here
  while ($p -and (Split-Path -Leaf $p) -ne 'steamapps') { $p = Split-Path -Parent $p }
  if ($p) {
    foreach ($name in 'ProjectZomboid', 'Project Zomboid Dedicated Server') {
      $g = Join-Path $p "common\$name"
      if (Test-Path -LiteralPath (Join-Path $g 'projectzomboid.jar')) { return $g }
    }
  }
  throw 'Game folder not found. Run again with -Dir "<the folder that holds projectzomboid.jar>".'
}

$game = Find-Game
$dst = Join-Path $game 'ZomboidFixesB42'
if (Get-Process -Name 'ProjectZomboid64' -ErrorAction SilentlyContinue) { throw 'Close Project Zomboid first.' }

# Launcher JSON (the game; a Linux server too): ours right after PZ Optimization's agent, or first, never twice.
$json = Join-Path $game 'ProjectZomboid64.json'
if (Test-Path -LiteralPath $json) {
  $j = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json
  $v = [System.Collections.ArrayList]@($j.vmArgs | Where-Object { $_ -ne $ours })
  if (-not $Uninstall) { $v.Insert([Math]::Max(0, $v.IndexOf($pzopt) + 1), $ours) }
  $j.vmArgs = @($v)
  [IO.File]::WriteAllText($json, ($j | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
  Write-Host "launcher: $((@($v) | Where-Object { $_ -like '-javaagent:*' }) -join ' ')"
}

# Server start files run jre64\bin\java.exe themselves: the argument goes on their java line.
foreach ($name in 'StartServer64.bat', 'StartServer64_nosteam.bat', 'ProjectZomboidServer.bat') {
  $bat = Join-Path $game $name
  if (-not (Test-Path -LiteralPath $bat)) { continue }
  $text = [IO.File]::ReadAllText($bat).Replace(" $ours", '')
  if (-not $Uninstall) {
    if ($text.Contains($pzopt)) { $text = $text.Replace($pzopt, "$pzopt $ours") }
    else { $text = [regex]::Replace($text, '(java\.exe"?)', "`$1 $ours") }
  }
  [IO.File]::WriteAllText($bat, $text)
  Write-Host "server start file: $name"
}

if ($Uninstall) {
  if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
  Write-Host "Removed. If your Steam launch option names $dst\launch.cmd, clear it, or the game will not start."
  return
}

New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item -LiteralPath (Join-Path $here 'zfix-agent.jar') -Destination $dst -Force
Copy-Item -LiteralPath (Join-Path $here 'launch.cmd') -Destination $dst -Force
if (-not (Test-Path -LiteralPath (Join-Path $dst 'java.ini'))) { Copy-Item -LiteralPath (Join-Path $here 'java.ini') -Destination $dst }
Write-Host "Installed into $dst"

# Java's agent DLL needs the game's jre64\bin on PATH, which Steam's start of ProjectZomboid64.exe does not give it.
$cmd = Join-Path $game 'pzopt-launch.cmd'
if (-not (Test-Path -LiteralPath $cmd)) { $cmd = Join-Path $dst 'launch.cmd' }
$line = "`"C:\Windows\System32\conhost.exe`" --headless `"$cmd`" %command%"
Write-Host ''
Write-Host 'Last step, or the game closes at start: Steam > Project Zomboid > Properties > General > Launch Options:'
Write-Host "  $line"
Write-Host 'Keep any options you had after %command%. (Copied to the clipboard.) A dedicated server needs no launch option.'
try { Set-Clipboard -Value $line } catch { }
