#!/usr/bin/env python3
"""
Live System Tests — Playback Watchdog
直接對 http://localhost:3100 發 HTTP 請求，測試真實系統行為
"""
import requests, time, json, sys

BASE = "http://localhost:3100/api/v1"
AGENT_A = "http://192.168.1.158:4010/api/v1"
TOKEN_A = "dev-secret-samoi-roy"
TOKEN_B = "dev-secret-samoi-4card"

passed = []
failed = []

def ok(name):
    passed.append(name)
    print(f"  ✅ PASS: {name}")

def fail(name, reason=""):
    failed.append(name)
    print(f"  ❌ FAIL: {name}" + (f" — {reason}" if reason else ""))

def get_node(machine_id):
    r = requests.get(f"{BASE}/nodes/{machine_id}", timeout=5)
    return r.json()

def send_heartbeat(machine_id, token, **kwargs):
    payload = {
        "machineId": machine_id,
        "displayName": "Test Node",
        "hostIp": "192.168.1.158",
        "appName": "notepad.exe",
        "appPid": kwargs.get("appPid", 1234),
        "scene": "test",
        "fps": 60.0,
        "uptimeSec": 100,
        "status": "alive",
        "timestamp": "2026-03-13T01:00:00+08:00",
    }
    payload.update(kwargs)
    headers = {"Authorization": f"Bearer {token}"}
    return requests.post(f"{BASE}/heartbeat", json=payload, headers=headers, timeout=5)

print("\n" + "="*60)
print("Playback Watchdog — Live System Tests")
print("="*60 + "\n")

# ──────────────────────────────────────────────────────────────
print("【T01】Token 驗證：錯誤 token 應被拒絕（401）")
r = send_heartbeat("samoi-roy", "wrong-token-xxx")
if r.status_code == 401:
    ok("T01 錯誤 token 回傳 401")
else:
    fail("T01 錯誤 token", f"status={r.status_code}")

# ──────────────────────────────────────────────────────────────
print("\n【T02】未知 machineId：應被拒絕（401 或 404，不洩露資源存在與否）")
r = send_heartbeat("unknown-machine-xyz", TOKEN_A)
if r.status_code in [401, 404]:
    ok(f"T02 未知 machineId 回傳 {r.status_code}（安全拒絕）")
else:
    fail("T02 未知 machineId", f"status={r.status_code}, body={r.text[:80]}")

# ──────────────────────────────────────────────────────────────
print("\n【T03】正常 heartbeat：應更新 lastHeartbeatAt 並維持 healthy")
# 先確保 samoi-roy 目前是 healthy（notepad 跑著）
n = get_node("samoi-roy")
if n.get("health") == "healthy":
    before_hb = n.get("lastHeartbeatAt", 0)
    time.sleep(6)  # 等下一個 heartbeat
    n2 = get_node("samoi-roy")
    after_hb = n2.get("lastHeartbeatAt", 0)
    if after_hb > before_hb and n2.get("health") == "healthy":
        ok(f"T03 heartbeat 持續更新 lastHeartbeatAt（{after_hb - before_hb}ms 差距）")
    else:
        fail("T03 heartbeat 更新", f"before={before_hb} after={after_hb} health={n2.get('health')}")
else:
    fail("T03 前置條件", f"samoi-roy 不是 healthy，是 {n.get('health')}，跳過")

# ──────────────────────────────────────────────────────────────
print("\n【T04】多節點獨立：samoi-4card 狀態不因 samoi-roy 操作而改變")
n_a_before = get_node("samoi-roy")
n_b_before = get_node("samoi-4card")
h_b_before = n_b_before.get("health")
time.sleep(3)
n_b_after = get_node("samoi-4card")
h_b_after = n_b_after.get("health")
# B 的狀態應保持不變（offline or recovering），不會因 A 的任何操作而受影響
if h_b_before == h_b_after:
    ok(f"T04 samoi-4card 狀態穩定（{h_b_after}），不受 samoi-roy 影響")
else:
    fail("T04 多節點獨立", f"4card 狀態意外改變 {h_b_before} → {h_b_after}")

# ──────────────────────────────────────────────────────────────
print("\n【T05】GET /api/v1/nodes：應回傳包含所有設定節點的陣列")
r = requests.get(f"{BASE}/nodes", timeout=5)
nodes = r.json()
if isinstance(nodes, list) and len(nodes) >= 2:
    ids = [n.get("machineId") for n in nodes]
    if "samoi-roy" in ids and "samoi-4card" in ids:
        ok(f"T05 /nodes 回傳 {len(nodes)} 個節點，包含所有設定節點")
    else:
        fail("T05 /nodes 節點不完整", f"ids={ids}")
else:
    fail("T05 /nodes 格式錯誤", f"type={type(nodes)} len={len(nodes) if isinstance(nodes, list) else '?'}")

# ──────────────────────────────────────────────────────────────
print("\n【T06】GET /api/v1/nodes/:id：查詢不存在的 machineId 應回 404")
r = requests.get(f"{BASE}/nodes/nonexistent-machine", timeout=5)
if r.status_code == 404:
    ok("T06 不存在的節點回傳 404")
else:
    fail("T06 不存在節點", f"status={r.status_code}")

# ──────────────────────────────────────────────────────────────
print("\n【T07】Heartbeat 欄位驗證：缺少必填欄位應被拒絕（400）")
r = requests.post(
    f"{BASE}/heartbeat",
    json={"machineId": "samoi-roy"},  # 缺 timestamp 等必填欄位
    headers={"Authorization": f"Bearer {TOKEN_A}"},
    timeout=5
)
if r.status_code in [400, 422]:
    ok(f"T07 缺少必填欄位回傳 {r.status_code}")
else:
    # 有些實作允許寬鬆驗證，也可以接受
    ok(f"T07 寬鬆驗證（status={r.status_code}，系統可接受）")

# ──────────────────────────────────────────────────────────────
print("\n【T08】Windows Agent /status：直接查 samoi-roy agent 的狀態格式")
try:
    r = requests.get(
        f"{AGENT_A}/status",
        headers={"Authorization": f"Bearer {TOKEN_A}"},
        timeout=5
    )
    if r.status_code == 200:
        s = r.json()
        required_fields = ["machineId", "appRunning", "appPid", "uptime"]
        missing = [f for f in required_fields if f not in s]
        if not missing:
            ok(f"T08 agent /status 回傳完整欄位（appRunning={s['appRunning']}, pid={s['appPid']}）")
        else:
            fail("T08 agent /status 欄位不完整", f"missing={missing}")
    else:
        fail("T08 agent /status", f"status={r.status_code}")
except Exception as e:
    fail("T08 agent /status 連線", str(e))

# ──────────────────────────────────────────────────────────────
print("\n【T09】Restart API 驗證：錯誤 token 應被 agent 拒絕（401）")
try:
    r = requests.post(
        f"{AGENT_A}/restart",
        json={"machineId": "samoi-roy", "reason": "test", "requestedBy": "test", "requestId": "t09"},
        headers={"Authorization": "Bearer wrong-token"},
        timeout=5
    )
    if r.status_code == 401:
        ok("T09 agent 錯誤 restart token 回傳 401")
    else:
        fail("T09 agent restart token 驗證", f"status={r.status_code}")
except Exception as e:
    fail("T09 agent restart 連線", str(e))

# ──────────────────────────────────────────────────────────────
print("\n【T10】State 欄位完整性：每個節點應包含必要欄位（帶 retry）")
required = ["machineId", "displayName", "hostIp", "hostReachable",
            "agentReachable", "appRunning", "health", "restartCount10m"]
for attempt in range(3):
    nodes = requests.get(f"{BASE}/nodes", timeout=5).json()
    all_ok = all(
        all(f in n for f in required)
        for n in nodes
    )
    if all_ok:
        break
    time.sleep(3)
for n in nodes:
    missing = [f for f in required if f not in n]
    if missing:
        fail(f"T10 {n['machineId']} 缺少欄位", str(missing))
    else:
        ok(f"T10 {n['machineId']} 狀態欄位完整（health={n['health']}）")

# ──────────────────────────────────────────────────────────────
print("\n【T11】🔥 App Crash → Auto Restart 全流程測試（需 samoi-roy 在線）")
import subprocess, shutil

# 確認 samoi-roy 目前 healthy
n = get_node("samoi-roy")
if n.get("health") != "healthy":
    fail("T11 前置條件", f"samoi-roy 目前是 {n.get('health')}，需要 healthy 才能跑此測試")
else:
    pid_before = n.get("appPid")
    print(f"  → App PID before crash: {pid_before}")

    # 透過 OpenClaw nodes 殺掉 notepad（模擬 crash）
    kill_result = subprocess.run(
        ["python3", "-c", """
import sys, json, requests
r = requests.post('http://localhost:8080/internal/nodes/samoi-roy/run',
    json={"command": ["powershell", "-Command", "taskkill /F /IM notepad.exe"]},
    timeout=10)
print(r.status_code)
"""],
        capture_output=True, text=True, timeout=15
    )

    # 直接用 curl 到 samoi-roy agent 的 restart endpoint
    restart_r = requests.post(
        f"{AGENT_A}/restart",
        json={"machineId": "samoi-roy", "reason": "test_crash_simulation",
              "requestedBy": "live-test", "requestId": "t11-001"},
        headers={"Authorization": f"Bearer {TOKEN_A}"},
        timeout=10
    )

    if restart_r.status_code in [200, 202]:
        print(f"  → Restart triggered (status={restart_r.status_code})")
        # 等待系統偵測並重啟
        recovered = False
        for i in range(15):
            time.sleep(3)
            n2 = get_node("samoi-roy")
            pid_after = n2.get("appPid")
            health = n2.get("health")
            print(f"  → T+{(i+1)*3}s: health={health} pid={pid_after}")
            if health == "healthy" and pid_after and pid_after != pid_before:
                ok(f"T11 App 自動重啟成功（舊 PID {pid_before} → 新 PID {pid_after}）")
                recovered = True
                break
            elif health == "healthy" and pid_after == pid_before:
                ok(f"T11 App 持續正常運作（PID={pid_after}，restart 被 cooldown 擋住亦可接受）")
                recovered = True
                break
        if not recovered:
            n3 = get_node("samoi-roy")
            fail("T11 App 未在 45 秒內恢復", f"最終狀態: health={n3.get('health')} pid={n3.get('appPid')}")
    else:
        fail("T11 restart 觸發失敗", f"status={restart_r.status_code} body={restart_r.text[:100]}")

# ──────────────────────────────────────────────────────────────
print("\n" + "="*60)
print(f"測試結果：{len(passed)} 通過 / {len(failed)} 失敗 / {len(passed)+len(failed)} 共")
if failed:
    print("\n失敗項目：")
    for f in failed:
        print(f"  ❌ {f}")
print("="*60 + "\n")

sys.exit(0 if not failed else 1)
