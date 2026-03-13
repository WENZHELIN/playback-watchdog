# start-openclaw-node.ps1
# 通用 OpenClaw Node 啟動腳本 — 自動偵測路徑
# 使用方式: powershell -ExecutionPolicy Bypass -File start-openclaw-node.ps1 -DisplayName "samoi-roy"

param(
    [string]$DisplayName = $env:COMPUTERNAME,
    [string]$GatewayHost = "wenzhelin-minimac-mini.tail2ef762.ts.net",
    [int]$GatewayPort = 443
)

$TOKEN = "606382b23cccd95064bf60d097f766df9accf6c8ce4823df"

# 1. 設定系統環境變數（一次性）
$current = [System.Environment]::GetEnvironmentVariable("OPENCLAW_GATEWAY_TOKEN", "Machine")
if ($current -ne $TOKEN) {
    [System.Environment]::SetEnvironmentVariable("OPENCLAW_GATEWAY_TOKEN", $TOKEN, "Machine")
    Write-Host "Set OPENCLAW_GATEWAY_TOKEN"
}
$env:OPENCLAW_GATEWAY_TOKEN = $TOKEN

# 2. 自動偵測 node.exe 和 openclaw.mjs
$candidates = @(
    "C:\nvm4w\nodejs",
    "C:\Program Files\nodejs",
    "$env:APPDATA\npm"
)

$nodeExe = $null
$ocMjs   = $null

foreach ($base in $candidates) {
    $ne = Join-Path $base "node.exe"
    $om = Join-Path $base "node_modules\openclaw\openclaw.mjs"
    if ((Test-Path $ne) -and (Test-Path $om)) {
        $nodeExe = $ne
        $ocMjs   = $om
        break
    }
}

if (-not $nodeExe) {
    # fallback: 從 PATH 找 node，npm root -g 找 openclaw
    $nodePath = (Get-Command node -ErrorAction SilentlyContinue).Source
    if ($nodePath) {
        $npmRoot = (cmd /c "npm root -g" 2>$null).Trim()
        $om = Join-Path $npmRoot "openclaw\openclaw.mjs"
        if (Test-Path $om) {
            $nodeExe = $nodePath
            $ocMjs   = $om
        }
    }
}

if (-not $nodeExe) {
    Write-Error "找不到 node.exe 或 openclaw.mjs，請先安裝 openclaw"
    exit 1
}

Write-Host "node  : $nodeExe"
Write-Host "openclaw: $ocMjs"
Write-Host "name  : $DisplayName"

# 3. 寫入 openclaw.json（只含 token，不加 exec key）
$configDir = "$env:USERPROFILE\.openclaw"
New-Item -ItemType Directory -Path $configDir -Force | Out-Null
$configPath = Join-Path $configDir "openclaw.json"
$config = '{"gateway":{"remote":{"token":"' + $TOKEN + '"}}}'
[System.IO.File]::WriteAllText($configPath, $config, [System.Text.Encoding]::UTF8)

# 4. 啟動 node
Write-Host "Starting openclaw node..."
& $nodeExe $ocMjs node run --host $GatewayHost --port $GatewayPort --tls --display-name $DisplayName
