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

# 確保 C:\Temp 存在
New-Item -ItemType Directory -Path C:\Temp -Force | Out-Null

function Log {
    param($msg)
    $t = Get-Date -Format "HH:mm:ss"
    "$t  $msg" | Tee-Object -FilePath $LogFile -Append | Write-Host
}

function RefreshPath {
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path    = $machinePath + ";" + $userPath
}

Log "=== Silent Setup Start: $DisplayName ==="
Log "Gateway: $GatewayHost"

# ─── 1. Node.js ───────────────────────────────────────────────
Log "[1/5] Node.js"
RefreshPath
# 強制使用官方 MSI 路徑（C:\Program Files\nodejs\），避免 nvm4w SmartScreen 問題
$officialNodePath = "C:\Program Files\nodejs\node.exe"
if (-not (Test-Path $officialNodePath)) {
    Log "  Installing Node.js v20 LTS (official MSI)..."
    $msi = "$env:TEMP\node-setup.msi"
    (New-Object System.Net.WebClient).DownloadFile(
        "https://nodejs.org/dist/v20.11.1/node-v20.11.1-x64.msi", $msi)
    Start-Process msiexec -ArgumentList @("/i", $msi, "/qn", "ADDLOCAL=ALL") -Wait -WindowStyle Hidden
    RefreshPath
    Log "  Node.js installed"
} else {
    Log "  Official Node.js found: $officialNodePath"
}
$nodePath = $officialNodePath

# ─── 2. Tailscale ─────────────────────────────────────────────
Log "[2/5] Tailscale"
$tsBin = "C:\Program Files\Tailscale\tailscale.exe"
if (-not (Test-Path $tsBin)) {
    Log "  Downloading Tailscale..."
    $tsExe = "$env:TEMP\tailscale-setup.exe"
    (New-Object System.Net.WebClient).DownloadFile(
        "https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe", $tsExe)
    Start-Process $tsExe -ArgumentList @("/S") -Wait -WindowStyle Hidden
    Start-Sleep 5
    Log "  Tailscale installed"
} else {
    Log "  Already installed"
}

# ─── 3. 加入 Tailnet ──────────────────────────────────────────
Log "[3/5] Tailnet"
if ($TailscaleKey -ne "") {
    Log "  Joining as $DisplayName..."
    Start-Process $tsBin `
        -ArgumentList @("up", "--authkey=$TailscaleKey", "--hostname=$DisplayName", "--unattended") `
        -Wait -WindowStyle Hidden
    # 等 Tailscale 取得 IP（最多 30 秒）
    $tsIp = ""
    for ($i = 0; $i -lt 6; $i++) {
        Start-Sleep 5
        $tsIp = (& $tsBin ip -4 2>$null)
        if ($tsIp -match "100\.\d+\.\d+\.\d+") { break }
    }
    if ($tsIp) {
        Log "  Connected! IP: $tsIp"
    } else {
        Log "  WARN: Tailscale IP not confirmed, continuing anyway"
    }
} else {
    Log "  SKIP: No TailscaleKey provided"
}

# ─── 4. OpenClaw ──────────────────────────────────────────────
Log "[4/5] OpenClaw"
RefreshPath
$npmCmd = Get-Command npm -ErrorAction SilentlyContinue
if (-not $npmCmd) {
    Log "  ERROR: npm not found, Node.js install may have failed"
    exit 1
}

# 找 openclaw.mjs（npm 是 .cmd，用 cmd /c 呼叫）
$npmRootRaw = cmd /c "npm root -g" 2>$null
$npmRoot    = if ($npmRootRaw) { $npmRootRaw.Trim() } else { "" }
$ocMjs      = ""
if ($npmRoot -and (Test-Path "$npmRoot\openclaw\openclaw.mjs")) {
    $ocMjs = "$npmRoot\openclaw\openclaw.mjs"
}
if (-not $ocMjs) {
    $ocMjs = "$env:APPDATA\npm\node_modules\openclaw\openclaw.mjs"
}

if (-not (Test-Path $ocMjs)) {
    Log "  Installing openclaw (this may take 1-2 minutes)..."
    # 直接在當前 session 執行，錯誤寫入 log
    cmd /c "npm install -g openclaw" 2>&1 | Out-File "$env:TEMP\oc-install.log" -Encoding UTF8
    Log "  npm install done, finding path..."
    RefreshPath
    # 重新找路徑
    $npmRootRaw = cmd /c "npm root -g" 2>$null
    $npmRoot    = if ($npmRootRaw) { ($npmRootRaw | Select-Object -Last 1).Trim() } else { "" }
    Log "  npm root -g: $npmRoot"
    if ($npmRoot -and (Test-Path "$npmRoot\openclaw\openclaw.mjs")) {
        $ocMjs = "$npmRoot\openclaw\openclaw.mjs"
    }
    # 若還是找不到，列出 npm 全局路徑輔助診斷
    if (-not (Test-Path $ocMjs)) {
        $altRoot = cmd /c "npm config get prefix" 2>$null
        $altRoot = if ($altRoot) { ($altRoot | Select-Object -Last 1).Trim() } else { "" }
        Log "  npm prefix: $altRoot"
        if ($altRoot -and (Test-Path "$altRoot\node_modules\openclaw\openclaw.mjs")) {
            $ocMjs = "$altRoot\node_modules\openclaw\openclaw.mjs"
        }
    }
}

if (Test-Path $ocMjs) {
    Log "  OpenClaw found: $ocMjs"
} else {
    Log "  ERROR: openclaw.mjs not found at $ocMjs"
    exit 1
}

# ─── 5. OpenClaw Node — Task Scheduler + 立即啟動 ────────────
Log "[5/5] OpenClaw Node"

Log "  Node path : $nodePath"
Log "  OpenClaw  : $ocMjs"

$ocArgsList = @(
    $ocMjs,
    "node", "run",
    "--host", $GatewayHost,
    "--port", "443",
    "--tls",
    "--display-name", $DisplayName
)
$ocArgsStr = $ocArgsList -join " "

# Task Scheduler XML（當前使用者身份，AtLogon，確保能存取 AppData 路徑）
$currentUser = "$env:USERDOMAIN\$env:USERNAME"
$xmlContent = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>OpenClaw Node Agent</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$currentUser</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
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
      <Arguments>$($ocArgsStr -replace '\\', '\\')</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$xmlPath = "$env:TEMP\oc-node-task.xml"
$xmlContent | Out-File $xmlPath -Encoding Unicode
schtasks /Create /TN "OpenClaw-Node" /XML $xmlPath /F 2>&1 | Out-Null
Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
Log "  Task Scheduler registered (AtLogon/$env:USERNAME)"

# 立即啟動（陣列傳參，避免 PS5.1 問題）
Start-Process -FilePath $nodePath -ArgumentList $ocArgsList -WindowStyle Hidden
Log "  Started in background"

# ─── 完成 ─────────────────────────────────────────────────────
Log ""
Log "=== Setup Complete ==="
Log "  Tailscale: connected as $DisplayName"
Log "  OpenClaw : running in background"
Log "  Next     : Roy runs [openclaw nodes pending] to approve"
Log "  Log      : $LogFile"
