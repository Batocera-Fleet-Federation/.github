# Plan: Three Fixes — Online/Offline Flipping, Not Resolvable, Auto-Sync Panel Removal

---

## Fix 1 — Online/Offline Flipping (Cache datetime Bug)

### Root Cause
`cache.set()` uses `json.dumps(value, default=str)`, serializing Python `datetime` objects to ISO strings. `cache.get()` uses `json.loads()`, returning them as plain `str`. In `device_response()` (presenters.py:122), `isinstance(last_seen, datetime)` **fails** for a string → `online = False` on every cache hit → drone shows Offline. Every ~15s when the cache expires and DB is queried, `last_seen` is a real `datetime` → drone shows Online. This causes the random flipping.

### Fix — `postgres_store.py` (~line 2183)

In `list_user_devices()`, parse datetime fields back from string after reading from cache using the existing `self._dt()` helper.

**Replace (lines 2181–2185):**
```python
if _cache:
    cache_key = _cache.user_devices_key(user_id, swarm_id)
    cached = _cache.get(cache_key)
    if cached is not None:
        return cached
```

**With:**
```python
if _cache:
    cache_key = _cache.user_devices_key(user_id, swarm_id)
    cached = _cache.get(cache_key)
    if cached is not None:
        for d in cached:
            d["last_seen"] = self._dt(d.get("last_seen"))
            d["registered_at"] = self._dt(d.get("registered_at"))
            d["removed_at"] = self._dt(d.get("removed_at"))
            pr = d.get("public_reachability")
            if isinstance(pr, dict):
                pr["checked_at"] = self._dt(pr.get("checked_at"))
        return cached
```

---

## Fix 2 — "Not Resolvable" (Scheduled Lambda Throttled + Skip Logic)

### Root Cause A — Lambda throttled to zero
`terraform.tfvars:82` has `lambda_scheduled_reserved_concurrency = 0` with a comment left from a temporary DB-recovery pause. This hard-throttles the scheduled Lambda to zero invocations. CloudWatch confirms: **zero invocations since May 31**. The public-reachability EventBridge rule fires every 15 minutes but every invocation is immediately throttled.

### Fix A — `terraform.tfvars` (line 82)
Change:
```hcl
lambda_scheduled_reserved_concurrency = 0
```
To:
```hcl
lambda_scheduled_reserved_concurrency = null
```
`null` removes the reserved concurrency reservation, letting the function draw from the unreserved pool (correct behavior for a low-frequency scheduled job). Run `terraform apply` to push the change.

### Root Cause B — Skip-if-resolved logic prevents re-probing
`public_reachability_already_resolved()` returns `True` for any device whose probe previously succeeded and whose IP hasn't changed. Once a drone is resolved, it is **never re-probed**, so:
- A drone that went offline after a successful probe stays "Resolvable" indefinitely
- A drone that was never probed (Lambda was throttled) correctly gets queued, but a drone that was probed once before the throttle was applied gets silently skipped

User requirement: "each drone that has a public IP to be pinged" — this requires periodic re-probing.

### Fix B — `main.py` (~line 453)
Remove the skip-if-resolved check from `poll_public_drone_reachability_once()`. The `oldest_checked_first` ordering in `list_all_approved_devices` already ensures round-robin probing across all devices — no explicit skip is needed.

**Remove this block inside the `for device in devices:` loop:**
```python
if public_reachability_already_resolved(device):
    continue
```

With this removed, every run probes up to `PUBLIC_PEER_PROBE_MAX_DEVICES_PER_RUN` devices in oldest-checked-first order. Devices that were probed successfully will cycle back around when their turn comes. The `PUBLIC_PEER_PROBE_PORTS = (8443, 443, 8080, 5000)` probe order is already correct.

> Note: `public_reachability_already_resolved` and the surrounding functions can be left in place for now — they may still be useful as a reference. If you want to fully clean up, the function can be deleted from `main.py`.

---

## Fix 3 — Remove `drone-auto-sync-panel`

### What it does (for your reference)
The auto-sync panel appears on the device detail view under the "Systems" sub-tab. It lets a user configure a per-drone **ROM metadata auto-sync policy**: toggle auto-sync on/off, and select which game systems (e.g., "snes", "nes", "psx") should have their ROM metadata automatically pushed to the Overmind swarm when the drone reports new data. When saved (`PATCH /api/devices/{id}/auto-sync`), the policy is stored in `drone_auto_sync_policies` + `drone_auto_sync_policy_systems` tables and read back by the drone on its next heartbeat to drive automatic metadata push behavior.

### Files to change

**`index.html` (line 358)** — Remove the panel container div:
```html
<!-- remove this line: -->
<div id="drone-auto-sync-panel" class="mb-3"></div>
```

**`overmind.js`** — Remove:
- `renderDroneAutoSyncPanel()` function (lines 2987–3023)
- `toggleDroneAutoSyncDropdown()` function (lines 3025–3034)
- `closeDroneAutoSyncDropdown()` function (lines 3036–3042)
- `document.addEventListener('click', closeDroneAutoSyncDropdown)` (line 3044)
- `updateDroneAutoSyncSystemLabel()` function (lines 3046–3051)
- `saveDroneAutoSyncPolicy()` function (lines 3107–3115)
- All four `renderDroneAutoSyncPanel()` call sites (lines 2446, 2460, 2829, 2855)

The backend API endpoint, database tables, and `auto_sync_policy` field in `device_response()` can be left untouched — removing the UI is sufficient.

---

## Critical Files

| File | Change |
|------|--------|
| `batocera.overmind/src/overmind/postgres_store.py` | Fix 1: parse datetimes in `list_user_devices` cache-read path (~line 2183) |
| `.github/terraform/aws/us-east-1/terraform.tfvars` | Fix 2A: set `lambda_scheduled_reserved_concurrency = null` (line 82) |
| `batocera.overmind/src/overmind/main.py` | Fix 2B: remove `public_reachability_already_resolved` skip in poller (~line 462) |
| `batocera.overmind/src/overmind/templates/index.html` | Fix 3: remove `drone-auto-sync-panel` div (line 358) |
| `batocera.overmind/src/overmind/static/js/overmind.js` | Fix 3: remove 6 functions + 4 call sites |

---

## Execution Order

1. Fix 1 (postgres_store.py) — standalone, fixes the flipping immediately on next deploy
2. Fix 2B (main.py) — standalone, removes the skip; takes effect once Lambda is unthrottled
3. Fix 2A (terraform.tfvars + `terraform apply`) — unblocks the poller; after this, probing starts
4. Fix 3 (HTML + JS) — standalone UI-only removal, safe to do in the same deploy as Fix 1/2B

---

## Verification

1. **Online/Offline fix**: Hit `GET /api/devices` multiple times in quick succession. All responses within the 15s cache window should show the same `online` value. Check CloudWatch — the device list SELECT should only appear once per ~15s per user.

2. **Not Resolvable fix**: After `terraform apply`, check CloudWatch on `bff-overmind-prod-scheduled` — should see invocations immediately. Within one 15-minute cycle, drones with a public IP should flip from "Not Resolvable" to a resolved state (or show a concrete failure reason). Confirm via `GET /api/devices/{id}` that `public_resolvable` updates.

3. **Auto-sync panel**: Open a drone's device detail → Systems tab. The auto-sync card should no longer appear.
