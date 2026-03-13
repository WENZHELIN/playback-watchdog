#Requires -RunAsAdministrator
<#
.SYNOPSIS
    場域無聲部署：Tailscale + OpenClaw Node
    全程背景執行，螢幕上不出現任何視窗。
    輸出寫入 C:\Temp\setup.log
#>
param(
    [string]$TailscaleKey = "",
    [string]$DisplayName  = "playback-node",
    [string]$GatewayHost  = "wenzhelin-minimac-mini.tail2ef762.ts.net",
    [string]$LogFile      = "C:\Temp\setup.log"
)

New-Item -ItemType Directory -Path C:\Temp -Force | Out-Null
function Log {
    param($msg)
    $t = Get-Date -Format "HH:mm:ss"
    "$t  $msg" | Tee-Object -FilePath $LogFile -Append | Write-Host
}

Log "=== Silent Setup Start: $DisplayName ==="
Log "Gateway: $GatewayHost"

# ─── 1. Node.js ───────────────────────────────────────────────
Log "[1/5] Node.js"
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
    Log "  Downloading Node.js v20 LTS..."
    $msi = "$env:TEMP\node-setup.msi"
    (New-Object System.Net.WebClient).DownloadFile(
        "https://nodejs.org/dist/v20.11.1/node-v20.11.1-x64.msi", $msi)
    Start-Process msiexec -ArgumentList "/i `"$msi`" /qn ADDLOCAL=ALL" -Wait -WindowStyle Hidden
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    Log "  Node.js installed: $(node -v 2>$null)"
} else {
    Log "  Already installed: $(node -v)"
}

# ─── 2. Tailscale ─────────────────────────────────────────────
Log "[2/5] Tailscale"
$tsCmd = Get-Command tailscale -ErrorAction SilentlyContinue
if (-not $tsCmd) {
    Log "  Downloading Tailscale..."
    $tsExe = "$env:TEMP\tailscale-setup.exe"
    (New-Object System.Net.WebClient).DownloadFile(
        "https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe", $tsExe)
    Start-Process $tsExe -ArgumentList "/S" -Wait -WindowStyle Hidden
    $env:Path += ";C:\Program Files\Tailscale"
    Start-Sleep 3
    Log "  Tailscale installed"
} else {
    Log "  Already installed"
}

# ─── 3. 加入 Tailnet ──────────────────────────────────────────
Log "[3/5] Tailnet"
if ($TailscaleKey -ne "") {
    Log "  Joining as $DisplayName..."
    Start-Process tailscale `
        -ArgumentList "up --authkey=$TailscaleKey --hostname=$DisplayName --unattended" `
        -Wait -WindowStyle Hidden -RedirectStandardOutput "$env:TEMP\ts-up.log"
    Start-Sleep 5
    $tsIp = (tailscale ip -4 2>$null)
    if ($tsIp) {
        Log "  Connected! IP: $tsIp"
    } else {
        Log "  WARN: Tailscale connected but IP not found yet"
    }
} else {
    Log "  SKIP: No TailscaleKey provided"
}

# ─── 4. OpenClaw ──────────────────────────────────────────────
Log "[4/5] OpenClaw"
$ocCmd = Get-Command openclaw -ErrorAction SilentlyContinue
if (-not $ocCmd) {
    Log "  Installing openclaw..."
    Start-Process npm -ArgumentList "install -g openclaw" `
        -Wait -WindowStyle Hidden `
        -RedirectStandardOutput "$env:TEMP\oc-install.log" `
        -RedirectStandardError  "$env:TEMP\oc-install-err.log"
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}
$ocVer = openclaw --version 2>$null
Log "  OpenClaw: $ocVer"

# ─── 5. OpenClaw Node — Task Scheduler ───────────────────────
Log "[5/5] OpenClaw Node (Task Scheduler + background start)"

$nodePath = (Get-Command node -ErrorAction SilentlyContinue)?.Source
if (-not $nodePath) { $nodePath = "C:\Program Files\nodejs\node.exe" }

$npmRoot = (npm root -g 2>$null)?.Trim()
$ocMjs   = if ($npmRoot) { "$npmRoot\openclaw\openclaw.mjs" } else { "" }

# 備用路徑
if (-not $ocMjs -or -not (Test-Path $ocMjs)) {
    $ocMjs = "$env:APPDATA\npm\node_modules\openclaw\openclaw.mjs"
}
if (-not (Test-Path $ocMjs)) {
    $ocMjs = "C:\Users\$env:USERNAME\AppData\Roaming\npm\node_modules\openclaw\openclaw.mjs"
}

Log "  Node path : $nodePath"
Log "  OpenClaw  : $ocMjs"

$ocArgs = "node run --host $GatewayHost --port 443 --tls --display-name $DisplayName"

# 用 XML 建立 Task（SYSTEM, BootTrigger, Hidden, 重試 10 次）
$xmlContent = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>OpenClaw Node Agent — Auto-start at boot</Description>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled></BootTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>10</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$($nodePath -replace '\\', '\\')</Command>
      <Arguments>$($ocMjs -replace '\\', '\\') $ocArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$xmlPath = "$env:TEMP\oc-node-task.xml"
$xmlContent | Out-File $xmlPath -Encoding Unicode
schtasks /Create /TN "OpenClaw-Node" /XML $xmlPath /F 2>&1 | Out-Null
Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue

Log "  Task Scheduler registered: OpenClaw-Node (SYSTEM/BootTrigger)"

# 立即在背景啟動（不等重開機）
Start-Process -FilePath $nodePath `
    -ArgumentList "$ocMjs $ocArgs" `
    -WindowStyle Hidden

Log "  Started in background"

# ─── 完成 ─────────────────────────────────────────────────────
Log ""
Log "=== Setup Complete ==="
Log "Next: Roy approves node pairing"
Log "  Command: openclaw nodes pending"
Log "  Log: $LogFile"
