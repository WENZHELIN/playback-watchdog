# 場域端快速部署：Tailscale + OpenClaw Node

> 適用：新的 Windows 播控主機加入遠端監控網路  
> 執行身份：系統管理員  
> 完成時間：約 5 分鐘

---

## 前置準備（在 Roy 這端先做）

### 1. 取得 Tailscale Pre-Auth Key

前往 https://login.tailscale.com/admin/settings/keys  
→ 點「Generate auth key」  
→ 勾選 **Reusable**（一把 key 可用於多台）  
→ 複製 key（格式：`tskey-auth-xxxxx`）

### 2. 確認 OpenClaw Gateway 網址

```
wenzhelin-minimac-mini.tail2ef762.ts.net:443
```

---

## 場域端執行（以系統管理員開啟 PowerShell）

### 一行指令（最快）

```powershell
irm https://raw.githubusercontent.com/WENZHELIN/playback-watchdog/main/scripts/silent-setup.ps1 -OutFile C:\Temp\s.ps1
powershell -ExecutionPolicy Bypass -File C:\Temp\s.ps1 `
  -TailscaleKey "tskey-auth-kmvbMzLtv321CNTRL-bJtb9AF8FL5YdouuhkZLL5eEevqMBXc9i" `
  -DisplayName "site-a"
```

> 把 `site-a` 換成這台主機的名稱。跑完後通知 Roy 核准配對。

---

### 完整腳本（自訂參數版）

把以下腳本存為 `setup.ps1`，或直接貼入 PowerShell 執行。  
**執行前替換第 3~5 行的三個變數。**

```powershell
# ─── 填入這三個值 ───────────────────────────────────────────
$TAILSCALE_KEY   = "tskey-auth-xxxxxx"      # 從 tailscale admin 取得
$DISPLAY_NAME    = "playback-site-a"        # 這台主機的名稱（英文）
$GATEWAY_HOST    = "wenzhelin-minimac-mini.tail2ef762.ts.net"
# ────────────────────────────────────────────────────────────

$ErrorActionPreference = "Continue"

Write-Host "`n=== Step 1：安裝 Node.js ===" -ForegroundColor Cyan
$nodeVer = node -v 2>$null
if ($nodeVer) {
    Write-Host "✅ Node.js 已安裝：$nodeVer"
} else {
    Write-Host "下載 Node.js LTS..."
    $nodeUrl = "https://nodejs.org/dist/v20.11.1/node-v20.11.1-x64.msi"
    $nodeMsi = "$env:TEMP\node-setup.msi"
    Invoke-WebRequest -Uri $nodeUrl -OutFile $nodeMsi -UseBasicParsing
    Start-Process msiexec -ArgumentList "/i $nodeMsi /qn ADDLOCAL=ALL" -Wait
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine")
    Write-Host "✅ Node.js 安裝完成"
}

Write-Host "`n=== Step 2：安裝 Tailscale ===" -ForegroundColor Cyan
$tsInstalled = Get-Command tailscale -EA SilentlyContinue
if ($tsInstalled) {
    Write-Host "✅ Tailscale 已安裝"
} else {
    Write-Host "下載 Tailscale..."
    $tsUrl = "https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe"
    $tsExe = "$env:TEMP\tailscale-setup.exe"
    Invoke-WebRequest -Uri $tsUrl -OutFile $tsExe -UseBasicParsing
    Start-Process -FilePath $tsExe -ArgumentList "/S" -Wait
    Start-Sleep 5
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";C:\Program Files\Tailscale"
    Write-Host "✅ Tailscale 安裝完成"
}

Write-Host "`n=== Step 3：加入 Tailnet ===" -ForegroundColor Cyan
tailscale up --authkey=$TAILSCALE_KEY --hostname=$DISPLAY_NAME --accept-routes
Start-Sleep 3
$tsStatus = tailscale status 2>$null
if ($tsStatus -match "100\.\d+\.\d+\.\d+") {
    Write-Host "✅ Tailscale 已連線"
    tailscale status | Select-Object -First 3
} else {
    Write-Host "⚠️  Tailscale 狀態異常，請手動確認：tailscale status"
}

Write-Host "`n=== Step 4：安裝 OpenClaw ===" -ForegroundColor Cyan
$ocInstalled = Get-Command openclaw -EA SilentlyContinue
if (-not $ocInstalled) {
    Write-Host "安裝 OpenClaw..."
    npm install -g openclaw
}
$ocVer = openclaw --version 2>$null
Write-Host "✅ OpenClaw：$ocVer"

Write-Host "`n=== Step 5：設定 OpenClaw Node 開機自動啟動 ===" -ForegroundColor Cyan

# 找 node 和 openclaw 的絕對路徑
$nodePath   = (Get-Command node).Source
$ocPath     = (Get-Command openclaw).Source -replace '\.cmd$', '.mjs'
# 通常是 C:\Users\xxx\AppData\Roaming\npm\node_modules\openclaw\openclaw.mjs
$npmGlobal  = npm root -g
$ocMjs      = "$npmGlobal\openclaw\openclaw.mjs"

if (-not (Test-Path $ocMjs)) {
    # 嘗試另一個路徑
    $ocMjs = (Get-Command openclaw).Source -replace 'openclaw\.cmd', 'node_modules\openclaw\openclaw.mjs'
}

Write-Host "Node 路徑：$nodePath"
Write-Host "OpenClaw 路徑：$ocMjs"

$args = "node run --host $GATEWAY_HOST --port 443 --tls --display-name $DISPLAY_NAME"

# 移除舊 Task
Unregister-ScheduledTask -TaskName "OpenClaw-Node" -Confirm:$false -EA SilentlyContinue

# 建立 Task Scheduler
$action    = New-ScheduledTaskAction -Execute $nodePath `
                 -Argument "$ocMjs $args"
$trigger   = New-ScheduledTaskTrigger -AtLogOn
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable `
                 -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) `
                 -ExecutionTimeLimit (New-TimeSpan -Hours 0)
$principal = New-ScheduledTaskPrincipal `
                 -UserId $env:USERNAME -RunLevel Highest

Register-ScheduledTask -TaskName "OpenClaw-Node" `
    -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force

Write-Host "✅ Task Scheduler 'OpenClaw-Node' 已建立（AtLogOn）"

Write-Host "`n=== Step 6：立即啟動 OpenClaw Node ===" -ForegroundColor Cyan
Start-Process -FilePath $nodePath `
    -ArgumentList "$ocMjs $args" `
    -WindowStyle Hidden

Write-Host "✅ OpenClaw Node 已啟動，等待配對確認..."
Write-Host ""
Write-Host "════════════════════════════════════════" -ForegroundColor Yellow
Write-Host "  請通知 Roy 在他的 OpenClaw 主控端"     -ForegroundColor Yellow
Write-Host "  確認並核准這台主機的配對請求"           -ForegroundColor Yellow
Write-Host "  主機名稱：$DISPLAY_NAME"                -ForegroundColor Yellow
Write-Host "════════════════════════════════════════" -ForegroundColor Yellow
```

---

## Roy 這端：核准配對

場域端啟動 OpenClaw Node 後，Roy 在主控端執行：

```bash
# 查看待核准的 node
openclaw nodes pending

# 核准指定 node
openclaw nodes approve <node-id>
```

或直接用 Rosey 確認。

---

## 驗證

### Roy 端查看新 node 是否上線
```bash
openclaw nodes status
```

### 場域端查看 Tailscale 連線狀態
```powershell
tailscale status
tailscale ping wenzhelin-minimac-mini.tail2ef762.ts.net
```

---

## 同時部署 PlaybackAgent（可選）

若這台也是播控主機，接著跑 `NODE-DEPLOY.md` 的 Step 2~6。  
OpenClaw Node 已跑在背景，兩者互不干擾。

---

## 常見問題

**Q: Tailscale 安裝後 `tailscale` 指令找不到？**  
→ 重新開啟 PowerShell，或執行：  
`$env:Path += ";C:\Program Files\Tailscale"`

**Q: OpenClaw node 啟動後看不到配對請求？**  
→ 確認 Tailscale 已連線（`tailscale status` 有 IP）  
→ 確認 gateway host 正確（`tailscale ping wenzhelin-minimac-mini.tail2ef762.ts.net`）

**Q: 想讓 OpenClaw Node 用 SYSTEM 帳號跑（不需要登入）？**  
→ 把 Task Scheduler 的 Principal 改為 SYSTEM，並確認 Tailscale 也設定為系統服務（預設就是）
