# 場域無聲部署指南

> **核心原則：場域螢幕（LED）上什麼都不出現。**  
> 全程由 Roy 遠端透過 OpenClaw 執行，場域主機零互動。

---

## Roy 執行（在自己的電腦 / Telegram 告訴 Rosey）

### 前置：取得 Tailscale Pre-Auth Key

前往 https://login.tailscale.com/admin/settings/keys  
→ Generate auth key → 勾 **Reusable** → 複製

---

## Step 1：遠端下載並執行安裝腳本（完全隱藏）

Rosey 透過 OpenClaw node 對場域主機執行，全部跑在背景：

```bash
# Rosey 對指定 node 執行（例如 samoi-roy）
nodes invoke samoi-roy system.run \
  '["powershell", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-Command",
    "Invoke-WebRequest https://raw.githubusercontent.com/WENZHELIN/playback-watchdog/main/scripts/silent-setup.ps1 -OutFile C:\\Temp\\silent-setup.ps1; powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\\Temp\\silent-setup.ps1 -TailscaleKey TSKEY -DisplayName site-a 2>&1 | Out-File C:\\Temp\\setup.log"]'
```

腳本跑在背景，輸出寫到 `C:\Temp\setup.log`，螢幕上完全沒有動靜。

---

## Step 2：查看安裝進度（不動螢幕）

```bash
# 讀取 log 確認進度
nodes invoke samoi-roy system.run \
  '["powershell", "-Command", "Get-Content C:\\Temp\\setup.log -Tail 20"]'
```

---

## 實際安裝腳本（silent-setup.ps1）

以下是推到 repo 的腳本主體，所有視窗都隱藏，輸出全進 log：

```powershell
param(
    [string]$TailscaleKey  = "",
    [string]$DisplayName   = "playback-node",
    [string]$GatewayHost   = "wenzhelin-minimac-mini.tail2ef762.ts.net",
    [string]$LogFile       = "C:\Temp\setup.log"
)

New-Item -ItemType Directory -Path C:\Temp -Force | Out-Null
function Log { param($msg) $t = Get-Date -Format "HH:mm:ss"; "$t  $msg" | Tee-Object -FilePath $LogFile -Append | Write-Host }

Log "=== Silent Setup Start: $DisplayName ==="

# 1. Node.js
if (-not (Get-Command node -EA SilentlyContinue)) {
    Log "Installing Node.js..."
    $msi = "$env:TEMP\node.msi"
    (New-Object Net.WebClient).DownloadFile("https://nodejs.org/dist/v20.11.1/node-v20.11.1-x64.msi", $msi)
    Start-Process msiexec -ArgumentList "/i $msi /qn ADDLOCAL=ALL" -Wait -WindowStyle Hidden
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine")
    Log "Node.js installed: $(node -v)"
} else {
    Log "Node.js OK: $(node -v)"
}

# 2. Tailscale
if (-not (Get-Command tailscale -EA SilentlyContinue)) {
    Log "Installing Tailscale..."
    $ts = "$env:TEMP\tailscale.exe"
    (New-Object Net.WebClient).DownloadFile("https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe", $ts)
    Start-Process $ts -ArgumentList "/S" -Wait -WindowStyle Hidden
    $env:Path += ";C:\Program Files\Tailscale"
    Log "Tailscale installed"
} else {
    Log "Tailscale OK"
}

# 3. 加入 Tailnet（背景，不開任何視窗）
if ($TailscaleKey -ne "") {
    Log "Joining tailnet as $DisplayName..."
    Start-Process tailscale -ArgumentList "up --authkey=$TailscaleKey --hostname=$DisplayName --unattended" `
        -Wait -WindowStyle Hidden -RedirectStandardOutput "$env:TEMP\ts.log"
    Start-Sleep 3
    $ip = (tailscale ip -4 2>$null)
    Log "Tailscale IP: $ip"
} else {
    Log "WARN: No TailscaleKey provided, skipping tailnet join"
}

# 4. OpenClaw
if (-not (Get-Command openclaw -EA SilentlyContinue)) {
    Log "Installing OpenClaw..."
    Start-Process npm -ArgumentList "install -g openclaw" -Wait -WindowStyle Hidden `
        -RedirectStandardOutput "$env:TEMP\oc-install.log"
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")
}
Log "OpenClaw: $(openclaw --version 2>$null)"

# 5. OpenClaw Node — Task Scheduler（AtStartup, SYSTEM, Hidden）
$nodePath = (Get-Command node -EA SilentlyContinue)?.Source
if (-not $nodePath) { $nodePath = "C:\Program Files\nodejs\node.exe" }
$npmRoot  = (npm root -g 2>$null).Trim()
$ocMjs    = "$npmRoot\openclaw\openclaw.mjs"
$ocArgs   = "node run --host $GatewayHost --port 443 --tls --display-name $DisplayName"

Log "Registering OpenClaw-Node task (SYSTEM, hidden)..."

# 用 XML 精確控制執行（確保無 UI 互動）
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>OpenClaw Node Agent</Description></RegistrationInfo>
  <Triggers><BootTrigger><Enabled>true</Enabled></BootTrigger></Triggers>
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
    <RestartOnFailure><Interval>PT1M</Interval><Count>10</Count></RestartOnFailure>
  </Settings>
  <Actions>
    <Exec>
      <Command>$nodePath</Command>
      <Arguments>$ocMjs $ocArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$xmlPath = "$env:TEMP\oc-task.xml"
$xml | Out-File $xmlPath -Encoding Unicode
schtasks /Create /TN "OpenClaw-Node" /XML $xmlPath /F | Out-Null
Remove-Item $xmlPath -Force

Log "OpenClaw-Node task registered"

# 6. 立即啟動（背景，Hidden）
Unregister-ScheduledTask -TaskName "OpenClaw-Node-Now" -Confirm:$false -EA SilentlyContinue
Start-Process $nodePath -ArgumentList "$ocMjs $ocArgs" -WindowStyle Hidden
Log "OpenClaw Node started in background"

Log "=== Setup Complete ==="
Log "Check pairing: Roy run [openclaw nodes pending] to approve this node"
```

---

## Step 3：Roy 核准 Node 配對

```bash
# 看有沒有新 node 待核准
openclaw nodes pending

# 核准
openclaw nodes approve <node-id>
```

---

## Step 4：驗證（遠端查看，不動螢幕）

```bash
# 查 setup log
nodes invoke <node-id> system.run '["powershell", "-Command", "Get-Content C:\\Temp\\setup.log"]'

# 查 Tailscale 狀態
nodes invoke <node-id> system.run '["powershell", "-Command", "tailscale status"]'
```

---

## 關鍵設計：為什麼不會出現在螢幕上

| 元件 | 怎麼隱藏 |
|------|---------|
| PowerShell | `-WindowStyle Hidden` |
| Node.js 安裝 | `msiexec /qn`（完全靜默）|
| Tailscale 安裝 | `/S`（Silent install）|
| Tailscale 連線 | `--unattended`（背景執行）|
| OpenClaw Node | Task Scheduler SYSTEM + 無 console |
| 所有輸出 | 導向 `C:\Temp\setup.log` |

整個過程螢幕上沒有任何視窗彈出，LED 顯示不受干擾。
