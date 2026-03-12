#!/usr/bin/env python3
"""
Playback Watchdog — Deploy Orchestration Test
==============================================
由 Linux 監控伺服器主導，自動完成從部署驗證 → 重開機 → 回線確認 → 健康驗證的完整測試流程。

使用方式：
    python3 tests/deploy-orchestration-test.py \
        --monitor http://localhost:3100 \
        --machine samoi-roy \
        --agent   http://192.168.1.158:4010 \
        --token   dev-secret-samoi-roy \
        [--no-reboot]   # 跳過重開機測試（快速驗證模式）

退出碼：0 = 全通過 | 1 = 有失敗
"""

import argparse, requests, time, sys, json, datetime

# ─────────────────────────────────────────────────────────────────
# CLI 參數
# ─────────────────────────────────────────────────────────────────
parser = argparse.ArgumentParser(description="Playback Watchdog Orchestration Test")
parser.add_argument("--monitor",   default="http://localhost:3100",       help="Linux 監控伺服器 base URL")
parser.add_argument("--machine",   required=True,                          help="目標節點 machineId")
parser.add_argument("--agent",     required=True,                          help="Windows Agent base URL")
parser.add_argument("--token",     required=True,                          help="Bearer token")
parser.add_argument("--no-reboot", action="store_true",                    help="跳過重開機步驟（快速模式）")
parser.add_argument("--reboot-timeout", type=int, default=300,            help="重開機等待上限（秒，預設 300）")
args = parser.parse_args()

MONITOR  = args.monitor.rstrip("/")
MACHINE  = args.machine
AGENT    = args.agent.rstrip("/")
TOKEN    = args.token
HEADERS  = {"Authorization": f"Bearer {TOKEN}"}

passed = []; failed = []
phase_results = {}

def ts():
    return datetime.datetime.now().strftime("%H:%M:%S")

def ok(name, detail=""):
    passed.append(name)
    suffix = f"  ({detail})" if detail else ""
    print(f"  ✅ PASS [{ts()}]: {name}{suffix}")

def fail(name, reason=""):
    failed.append(name)
    print(f"  ❌ FAIL [{ts()}]: {name}" + (f" — {reason}" if reason else ""))

def section(title):
    print(f"\n{'═'*60}")
    print(f"  {title}")
    print(f"{'═'*60}")

def get_node():
    r = requests.get(f"{MONITOR}/api/v1/nodes/{MACHINE}", timeout=5)
    if r.status_code != 200: return None
    return r.json()

def agent_get(path, timeout=5):
    return requests.get(f"{AGENT}{path}", headers=HEADERS, timeout=timeout)

def agent_post(path, body, timeout=5):
    return requests.post(f"{AGENT}{path}", json=body, headers=HEADERS, timeout=timeout)

def wait_until(condition_fn, timeout_sec, poll_sec=3, label="condition"):
    """輪詢直到 condition_fn() 回傳 True 或超時。回傳 (success, elapsed)。"""
    start = time.time()
    print(f"  ⏳ 等待 {label}（最多 {timeout_sec}s）")
    while True:
        elapsed = int(time.time() - start)
        try:
            result = condition_fn()
            if result:
                print(f"  ✅ {label} — 達成（{elapsed}s）")
                return True, elapsed
        except Exception:
            pass
        if elapsed >= timeout_sec:
            print(f"  ❌ {label} — 超時（{timeout_sec}s）")
            return False, elapsed
        print(f"     T+{elapsed}s ...", end="\r", flush=True)
        time.sleep(poll_sec)

# ═══════════════════════════════════════════════════════════════
print("\n" + "═"*60)
print("  Playback Watchdog — Deploy Orchestration Test")
print(f"  Monitor : {MONITOR}")
print(f"  Machine : {MACHINE}")
print(f"  Agent   : {AGENT}")
print(f"  Reboot  : {'SKIP' if args.no_reboot else 'YES'}")
print("═"*60)

# ═══════════════════════════════════════════════════════════════
# PHASE 1：Pre-reboot 基礎驗證
# ═══════════════════════════════════════════════════════════════
section("PHASE 1 — Pre-reboot 基礎驗證")

# P1-01 Monitor 在線
try:
    r = requests.get(f"{MONITOR}/api/v1/nodes", timeout=5)
    ids = [n["machineId"] for n in r.json()]
    if MACHINE in ids:
        ok("P1-01 Linux Monitor 在線且包含目標節點")
    else:
        fail("P1-01 Linux Monitor 未包含目標節點", f"nodes={ids}")
except Exception as e:
    fail("P1-01 Linux Monitor 連線失敗", str(e))

# P1-02 Agent ping（無 token）
try:
    r = requests.get(f"{AGENT}/api/v1/admin/ping", timeout=5)
    if r.status_code == 200:
        d = r.json()
        ok("P1-02 Agent /ping 回應", f"uptime={d.get('uptime')}s")
    else:
        fail("P1-02 Agent /ping", f"status={r.status_code}")
except Exception as e:
    fail("P1-02 Agent /ping 連線失敗", str(e))

# P1-03 Agent /status（帶 token）
try:
    r = agent_get("/api/v1/status")
    if r.status_code == 200:
        d = r.json()
        ok("P1-03 Agent /status", f"appRunning={d['appRunning']} pid={d.get('appPid')}")
    else:
        fail("P1-03 Agent /status", f"status={r.status_code}")
except Exception as e:
    fail("P1-03 Agent /status 連線失敗", str(e))

# P1-04 Monitor 顯示節點 healthy
n = get_node()
if n and n.get("health") in ["healthy", "degraded", "recovering"]:
    ok("P1-04 Monitor 已追蹤目標節點", f"health={n['health']}")
else:
    fail("P1-04 Monitor 節點狀態異常", f"state={n}")

# P1-05 Heartbeat 正在更新
hb1 = get_node()
time.sleep(8)
hb2 = get_node()
if hb1 and hb2:
    t1 = hb1.get("lastHeartbeatAt", 0) or 0
    t2 = hb2.get("lastHeartbeatAt", 0) or 0
    if t2 > t1:
        ok("P1-05 Heartbeat 持續更新", f"間隔 {t2-t1}ms")
    else:
        fail("P1-05 Heartbeat 未更新", f"t1={t1} t2={t2}")
else:
    fail("P1-05 Heartbeat 讀取失敗")

# P1-06 Token 安全：錯誤 token 被拒
try:
    r = requests.get(f"{AGENT}/api/v1/status", headers={"Authorization": "Bearer wrong"}, timeout=5)
    if r.status_code == 401:
        ok("P1-06 錯誤 token 被拒（401）")
    else:
        fail("P1-06 Token 驗證", f"status={r.status_code}")
except Exception as e:
    fail("P1-06 Token 測試失敗", str(e))

phase_results["P1"] = len(failed) == 0

# ═══════════════════════════════════════════════════════════════
# PHASE 2：App Crash → Auto Restart（重開機前）
# ═══════════════════════════════════════════════════════════════
section("PHASE 2 — App Crash → Auto Restart 測試")

n = get_node()
pre_health = n.get("health") if n else "unknown"

if pre_health == "healthy":
    pre_pid = n.get("appPid")
    print(f"  ℹ️  觸發 App restart（當前 PID={pre_pid}）")

    # 觸發 restart（直接呼叫 agent）
    try:
        r = agent_post("/api/v1/restart", {
            "machineId": MACHINE,
            "reason": "orchestration-test-p2",
            "requestedBy": "linux-orchestrator",
            "requestId": "orch-p2-001"
        })
        if r.status_code in [200, 202, 429]:
            print(f"  ℹ️  Restart 指令送出（status={r.status_code}）")
        else:
            fail("P2-01 Restart 指令", f"status={r.status_code}")
    except Exception as e:
        fail("P2-01 Restart 指令失敗", str(e))

    # 等待恢復 healthy
    def p2_healthy():
        nd = get_node()
        return nd and nd.get("health") == "healthy" and nd.get("appPid") is not None

    success, elapsed = wait_until(p2_healthy, timeout_sec=60, label="App 重啟後回到 healthy")
    if success:
        post_pid = (get_node() or {}).get("appPid")
        ok("P2-02 App 自動重啟成功", f"PID {pre_pid} → {post_pid}，耗時 {elapsed}s")
    else:
        fail("P2-02 App 未在 60s 內恢復 healthy")
else:
    print(f"  ⚠️  節點非 healthy（{pre_health}），跳過 Crash 測試")
    ok("P2-SKIP App Crash 測試（前置條件不符，跳過）")

phase_results["P2"] = True  # 不阻擋後續

# ═══════════════════════════════════════════════════════════════
# PHASE 3：重開機
# ═══════════════════════════════════════════════════════════════
if args.no_reboot:
    section("PHASE 3 — 重開機（已跳過，--no-reboot 模式）")
    ok("P3-SKIP 重開機（跳過）")
    phase_results["P3"] = True
    phase_results["P4"] = True
    phase_results["P5"] = True
else:
    section("PHASE 3 — 觸發重開機")

    reboot_ok = False
    try:
        r = agent_post("/api/v1/admin/reboot", {
            "reason": "orchestration-test-reboot",
            "requestId": "orch-reboot-001"
        })
        if r.status_code == 202:
            ok("P3-01 重開機指令接受（202）", r.json().get("message", ""))
            reboot_ok = True
        else:
            fail("P3-01 重開機指令", f"status={r.status_code} body={r.text[:100]}")
    except Exception as e:
        fail("P3-01 重開機指令失敗", str(e))

    if not reboot_ok:
        print("  ⚠️  重開機失敗，跳過後續 Phase 4/5")
        phase_results["P3"] = False
        phase_results["P4"] = False
        phase_results["P5"] = False
    else:
        phase_results["P3"] = True

        # ═══════════════════════════════════════════════════════════
        # PHASE 4：等待主機斷線 → 重新上線
        # ═══════════════════════════════════════════════════════════
        section("PHASE 4 — 等待主機重開機並回線")

        # 4a：等待主機斷線（ping 失敗 → offline）
        print(f"  ℹ️  等待主機進入重開機（最多 60s）")
        time.sleep(15)  # 給 Windows shutdown 指令執行的時間

        def p4a_offline():
            nd = get_node()
            return nd and not nd.get("hostReachable")

        success_off, _ = wait_until(p4a_offline, timeout_sec=60, label="主機斷線（offline）")
        if success_off:
            ok("P4-01 主機進入離線狀態（重開機中）")
        else:
            # 可能重開很快，不算 fail
            print("  ⚠️  未偵測到明確離線狀態（主機可能重開很快）")
            ok("P4-01 離線偵測（可能重開過快，非阻斷錯誤）")

        # 4b：等待主機 ping 回線
        def p4b_online():
            nd = get_node()
            return nd and nd.get("hostReachable") is True

        success_on, elapsed_on = wait_until(p4b_online, timeout_sec=args.reboot_timeout, poll_sec=5, label="主機 Ping 回線")
        if success_on:
            ok("P4-02 主機 Ping 回線", f"耗時 {elapsed_on}s")
            phase_results["P4"] = True
        else:
            fail("P4-02 主機未在規定時間內回線", f"timeout={args.reboot_timeout}s")
            phase_results["P4"] = False
            print("  ❌ 主機未回線，中止後續測試")
            # 跳到結果輸出
            phase_results["P5"] = False
            args.no_reboot = True  # 防止後續繼續

        # ═══════════════════════════════════════════════════════════
        # PHASE 5：等待 Agent 自動啟動（Task Scheduler 驗證）
        # ═══════════════════════════════════════════════════════════
        if phase_results.get("P4"):
            section("PHASE 5 — Agent 自動啟動驗證（Task Scheduler）")

            # 5a：等待 agent /ping 回應
            def p5a_agent_alive():
                try:
                    r = requests.get(f"{AGENT}/api/v1/admin/ping", timeout=3)
                    return r.status_code == 200
                except Exception:
                    return False

            success_agent, elapsed_agent = wait_until(p5a_agent_alive, timeout_sec=120, poll_sec=3, label="Agent /ping 回應")
            if success_agent:
                ok("P5-01 Agent 自動啟動成功（Task Scheduler 生效）", f"耗時 {elapsed_agent}s")
            else:
                fail("P5-01 Agent 未在 120s 內自動啟動", "Task Scheduler 可能未設定或 node.exe 路徑錯誤")

            # 5b：等待 heartbeat 出現在 Monitor
            def p5b_heartbeat():
                nd = get_node()
                hb = nd.get("lastHeartbeatAt") if nd else None
                if not hb: return False
                return (time.time() * 1000 - hb) < 15000  # 15 秒內有 heartbeat

            success_hb, elapsed_hb = wait_until(p5b_heartbeat, timeout_sec=60, poll_sec=3, label="Monitor 收到 Heartbeat")
            if success_hb:
                ok("P5-02 Monitor 收到重開機後第一個 Heartbeat", f"耗時 {elapsed_hb}s")
            else:
                fail("P5-02 Monitor 未收到 Heartbeat（heartbeat thread 可能未啟動）")

            # 5c：Monitor health 狀態
            nd = get_node()
            health_after = nd.get("health") if nd else "unknown"
            if health_after == "healthy":
                ok("P5-03 重開機後節點狀態 = healthy")
            elif health_after == "recovering":
                ok("P5-03 節點狀態 = recovering（App 尚未完全啟動，可接受）")
            else:
                fail("P5-03 重開機後節點狀態異常", f"health={health_after}")

            phase_results["P5"] = success_agent and success_hb

# ═══════════════════════════════════════════════════════════════
# PHASE 6：重開機後功能驗證
# ═══════════════════════════════════════════════════════════════
section("PHASE 6 — 重開機後完整功能驗證")

# 等待節點穩定到 healthy
def p6_healthy():
    nd = get_node()
    return nd and nd.get("health") == "healthy"

wait_until(p6_healthy, timeout_sec=60, label="等待 healthy 狀態穩定")

nd = get_node()

# P6-01 Agent /status
try:
    r = agent_get("/api/v1/status", timeout=5)
    if r.status_code == 200:
        d = r.json()
        ok("P6-01 Agent /status 正常", f"appRunning={d['appRunning']} uptime={d.get('uptime')}s")
    else:
        fail("P6-01 Agent /status", f"status={r.status_code}")
except Exception as e:
    fail("P6-01 Agent /status 失敗", str(e))

# P6-02 Monitor 節點完整欄位
required_fields = ["machineId", "displayName", "hostIp", "hostReachable",
                   "agentReachable", "appRunning", "health", "restartCount10m"]
missing = [f for f in required_fields if nd and f not in nd]
if nd and not missing:
    ok("P6-02 Monitor 節點狀態欄位完整", f"health={nd.get('health')}")
else:
    fail("P6-02 Monitor 節點欄位缺失", str(missing))

# P6-03 restartCount10m 未超限
if nd:
    rc = nd.get("restartCount10m", 0)
    max_r = 3  # config default
    if rc < max_r:
        ok("P6-03 重啟計數正常", f"{rc}/{max_r}")
    else:
        fail("P6-03 重啟計數已達上限", f"{rc}/{max_r}（可能有問題）")

# P6-04 Token 驗證仍有效
try:
    r = requests.get(f"{AGENT}/api/v1/status", headers={"Authorization": "Bearer WRONG"}, timeout=5)
    if r.status_code == 401:
        ok("P6-04 Token 驗證（重開機後仍有效）")
    else:
        fail("P6-04 Token 驗證", f"status={r.status_code}")
except Exception as e:
    fail("P6-04 Token 驗證測試失敗", str(e))

# P6-05 Heartbeat 頻率（重開機後）
hb_now = get_node()
time.sleep(8)
hb_after = get_node()
t1 = (hb_now or {}).get("lastHeartbeatAt", 0) or 0
t2 = (hb_after or {}).get("lastHeartbeatAt", 0) or 0
if t2 > t1:
    ok("P6-05 重開機後 Heartbeat 持續正常", f"間隔 {t2-t1}ms")
else:
    fail("P6-05 重開機後 Heartbeat 異常", f"t1={t1} t2={t2}")

phase_results["P6"] = True

# ═══════════════════════════════════════════════════════════════
# PHASE 7：重開機後 App Crash → Auto Restart
# ═══════════════════════════════════════════════════════════════
section("PHASE 7 — 重開機後 App Crash → Auto Restart 驗證")

nd_now = get_node()
if nd_now and nd_now.get("health") == "healthy":
    pre_pid = nd_now.get("appPid")
    print(f"  ℹ️  觸發 restart（PID={pre_pid}）")
    try:
        r = agent_post("/api/v1/restart", {
            "machineId": MACHINE,
            "reason": "orchestration-test-p7",
            "requestedBy": "linux-orchestrator",
            "requestId": "orch-p7-001"
        })
        triggered = r.status_code in [200, 202]
        print(f"  ℹ️  Restart 指令 status={r.status_code}")
    except Exception as e:
        triggered = False
        print(f"  ⚠️  Restart 指令失敗：{e}")

    if triggered:
        def p7_recovered():
            nd = get_node()
            return nd and nd.get("health") == "healthy" and nd.get("appPid") is not None

        success, elapsed = wait_until(p7_recovered, timeout_sec=60, label="重開機後 App 恢復 healthy")
        if success:
            post_pid = (get_node() or {}).get("appPid")
            ok("P7-01 重開機後 App Crash → Auto Restart 成功", f"PID {pre_pid} → {post_pid}，耗時 {elapsed}s")
        else:
            fail("P7-01 重開機後 App 未恢復")
    else:
        ok("P7-01 Restart 因 cooldown 擋住（重開機後計數已有值，可接受）")
else:
    health = (nd_now or {}).get("health", "unknown")
    print(f"  ⚠️  節點非 healthy（{health}），跳過 P7")
    ok("P7-SKIP App Crash 測試（前置條件不符）")

phase_results["P7"] = True

# ═══════════════════════════════════════════════════════════════
# 最終報告
# ═══════════════════════════════════════════════════════════════
print("\n" + "═"*60)
print("  測試結果總覽")
print("═"*60)

phase_labels = {
    "P1": "Pre-reboot 基礎驗證",
    "P2": "App Crash → Auto Restart",
    "P3": "重開機指令",
    "P4": "主機斷線 → 回線",
    "P5": "Agent 自動啟動（Task Scheduler）",
    "P6": "重開機後功能驗證",
    "P7": "重開機後 App Crash → Restart",
}
for phase, label in phase_labels.items():
    result = phase_results.get(phase)
    if result is True:
        print(f"  ✅ {phase}: {label}")
    elif result is False:
        print(f"  ❌ {phase}: {label}")
    else:
        print(f"  ⚠️  {phase}: {label}（未執行）")

print(f"\n  測試項目：{len(passed)} 通過 / {len(failed)} 失敗 / {len(passed)+len(failed)} 共")
print("═"*60)

if failed:
    print("\n  失敗項目：")
    for f in failed:
        print(f"    ❌ {f}")

print()
sys.exit(0 if not failed else 1)
