# Plan: Overmind ROM Loading Performance Optimization

## Context

The Overmind UI's "Loading master ROMs..." is slow. The user wants the app to be
stateless (no in-memory state dependency per request), query only paged data from
the DB, and have noticeably faster load times.

**Root causes identified (in order of impact):**

1. `page_master_assets` runs **two full CTE scans** per request — one for COUNT, one for data
2. Text search (`lower(n.payload::text) LIKE %s`) has **no DB index** — full sequential scan every search
3. Frontend `showSwarmMasterList` loads 250 rows with **no pagination UI** and no page state
4. `count_device_roms` fallback calls `list_device_assets` (loads all rows) just to count
5. `GET /api/master-bios` loads all bios into Python then filters/paginates there
6. `refresh_persistent_state()` is sprinkled on asset endpoints (it's a no-op on postgres path, but is noise and breaks the in-memory fallback path unnecessarily)

---

## Fix 1 — Combine count + data into one query (`postgres_store.py`)

**File:** `src/overmind/postgres_store.py` — `page_master_assets()` (~line 4762)

Replace the two-query pattern (COUNT query then data query) with a single query
using `COUNT(*) OVER ()` as a window function.

**Current pattern (two round-trips):**
```python
cur.execute("WITH normalized AS (...), filtered_keys AS (...) SELECT count(*) FROM filtered_keys", base_params)
total = ...
cur.execute("WITH normalized AS (...), filtered_keys AS (...), paged_keys AS (...) SELECT ... FROM normalized n JOIN paged_keys p ...", [*base_params, per_page, offset, ...])
```

**New pattern (one round-trip):**
```python
# Remove the first COUNT query entirely.
# In the data query, add two CTEs after filtered_keys:
#
#   counted_keys AS (
#       SELECT master_key, sort_key, COUNT(*) OVER () AS total_count
#       FROM filtered_keys
#   ),
#   paged_keys AS (
#       SELECT master_key, total_count
#       FROM counted_keys
#       ORDER BY sort_key, master_key
#       LIMIT %s OFFSET %s
#   )
#
# Add p.total_count as the last selected column.
# After fetchall(), read total = int(rows[0][5]) if rows else 0.
# Replace the early-exit "if not total: return [], 0" with "if not rows: return [], 0".

cur.execute(f"""
    WITH normalized AS ({normalized_sql}),
    {filtered_sql},
    counted_keys AS (
        SELECT master_key, sort_key, COUNT(*) OVER () AS total_count
        FROM filtered_keys
    ),
    paged_keys AS (
        SELECT master_key, total_count
        FROM counted_keys
        ORDER BY sort_key, master_key
        LIMIT %s OFFSET %s
    )
    SELECT n.device_internal_id, n.payload, n.master_key, n.artwork_type,
           CASE WHEN %s::text IS NULL THEN false ELSE EXISTS (
               SELECT 1 FROM normalized selected
               WHERE selected.master_key = n.master_key AND selected.device_internal_id = %s
           ) END AS present_on_selected,
           p.total_count
    FROM normalized n
    JOIN paged_keys p ON p.master_key = n.master_key
    ORDER BY n.sort_key, n.master_key, n.device_internal_id
""", [*base_params, per_page, offset, selected_param, selected_param])
rows = cur.fetchall()

if not rows:
    return [], 0
total = int(rows[0][5] or 0)
```

Update the unpacking loop to accept 6 columns:
```python
for internal_id, payload, group_key, row_artwork_type, present_on_selected, _ in rows:
```

---

## Fix 2 — Add `pg_trgm` GIN index for text search (`postgres_store.py`)

**File:** `src/overmind/postgres_store.py` — `_ensure_relational_schema()` (~line 978, after existing indexes)

The `lower(n.payload::text) LIKE %s` filter in `page_master_assets` does a full
table scan. A `pg_trgm` GIN index makes LIKE/ILIKE queries use an index.

Add to `_ensure_relational_schema` after the existing indexes block:
```python
cur.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
cur.execute(
    """
    CREATE INDEX IF NOT EXISTS idx_overmind_device_assets_payload_trgm
    ON overmind_device_assets USING GIN (lower(payload::text) gin_trgm_ops)
    """
)
```

No predicate changes needed — the existing `lower(n.payload::text) LIKE %s` query
will automatically use the GIN index.

> Note: Index creation is idempotent (`IF NOT EXISTS`). Initial creation on a large
> table is a one-time cost at deploy. On AWS RDS, `pg_trgm` is available by default.

---

## Fix 3 — Fix `count_device_roms` to not load all rows (`db.py` + `postgres_store.py`)

**Problem:** `db.count_device_roms` (~line 2315) has a fallback that calls
`postgres_store.list_device_assets(device["id"], "rom")` (no LIMIT) just to `len()`
the result. This branch is hit when `postgres_store.count_device_roms()` returns 0
(e.g., the `drone_roms` relational table is unused but `overmind_device_assets` has data).

**Step A** — Add `count_device_assets()` to `postgres_store.py`:
```python
def count_device_assets(self, device_id: str, asset_type: str) -> Optional[int]:
    conn = self._core_connection(ensure_schema=False)
    if conn is None:
        return None
    with conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT count(*) FROM overmind_device_assets WHERE device_id = %s AND asset_type = %s",
                (device_id, asset_type),
            )
            row = cur.fetchone()
            return int(row[0] or 0) if row else 0
```

Note: Uses `device_id` (string column on `overmind_device_assets`), not the internal UUID.

**Step B** — Update `db.count_device_roms()`:
```python
def count_device_roms(self, device_id: str) -> int:
    if postgres_store.assets_enabled():
        result = postgres_store.count_device_assets(device_id, "rom")
        if result is not None:
            return result
    if postgres_store.available():
        result = postgres_store.count_device_roms(device_id)
        if result is not None:
            return result
    device = self.get_device_by_device_id(device_id)
    if not device:
        return 0
    return len(self.roms.get(device["id"], []))
```

---

## Fix 4 — Push master-bios filtering to SQL (`db.py` + `main.py`)

**Problem:** `GET /api/master-bios` (~main.py line 2330) loads ALL bios with
`get_swarm_master_bios()` then filters and paginates in Python.

**Step A** — Add `get_swarm_master_bios_page()` to `db.py` (after `get_swarm_master_roms_page` ~line 2878):
```python
def get_swarm_master_bios_page(
    self,
    user_id: str,
    *,
    query: Optional[str] = None,
    page: int = 1,
    per_page: int = 100,
) -> dict:
    page = max(1, int(page))
    per_page = max(1, min(int(per_page), 500))
    if self._asset_store_enabled():
        devices = self.get_user_devices(user_id)
        raw_rows, total = postgres_store.page_master_assets(
            [device["id"] for device in devices],
            "bios",
            query=query,
            page=page,
            per_page=per_page,
        )
        return {
            "rows": self._master_page_from_asset_rows("bios", raw_rows, user_id, include_presence=False),
            "total": total,
            "page": page,
            "per_page": per_page,
        }
    rows = self._filter_master_rows(self.get_swarm_master_bios(user_id), asset_type="bios", query=query)
    start = (page - 1) * per_page
    return {"rows": rows[start:start + per_page], "total": len(rows), "page": page, "per_page": per_page}
```

**Step B** — Replace `get_swarm_master_bios` handler body in `main.py` (~line 2338):
```python
async def get_swarm_master_bios(...):
    user = get_current_user(authorization)
    result = db.get_swarm_master_bios_page(user["id"], query=q, page=page, per_page=per_page)
    return {"bios": result["rows"], "total": result["total"], "page": result["page"], "per_page": result["per_page"]}
```

Remove the inline Python filtering (the `filtered = [row for row in rows if ...]` block).

---

## Fix 5 — Remove `refresh_persistent_state()` from asset handlers (`main.py`)

**File:** `src/overmind/main.py`

`refresh_persistent_state()` is already a **no-op on the postgres path** (returns
immediately when `postgres_store.url` is set, see db.py line 202). All five handlers
that call it before asset queries (`get_device_master_roms`, `get_swarm_master_roms`,
`get_device_master_bios`, `get_swarm_master_bios`, `get_device_master_artwork`) can
have this call removed. The `user_can_access_device` call that follows already uses
`postgres_store.user_can_access_device()` directly (db.py line 1568).

Delete the `db.refresh_persistent_state()` line from each of the five handlers.

---

## Fix 6 — Frontend: paginate `showSwarmMasterList` (`overmind.js`)

**File:** `src/overmind/static/js/overmind.js`

`showSwarmMasterList` (~line 1930) loads `per_page=250` with no page controls.

Changes:
1. **Add state variable** near existing `let masterRomPage = 1;`:
   ```js
   let swarmMasterPage = 1;
   ```

2. **Update params** in `showSwarmMasterList()`:
   ```js
   params.set('per_page', '100');      // was 250
   params.set('page', String(swarmMasterPage));
   ```

3. **Extract pagination data** from response:
   ```js
   const total = payload.total || rows.length;
   const perPage = payload.per_page || 100;
   const pageCount = Math.max(1, Math.ceil(total / perPage));
   ```

4. **Add `setSwarmMasterPage()` helper** (parallel to `setMasterRomPage`):
   ```js
   function setSwarmMasterPage(page) {
       swarmMasterPage = Math.max(1, page);
       showSwarmMasterList(false);
   }
   function submitSwarmMasterSearch() {
       swarmMasterPage = 1;
       showSwarmMasterList(false);
   }
   ```

5. **Render pagination controls** in the panel HTML — model on the existing
   `loadSwarmRomAvailabilityPanel` pagination block (~line 3114). Inject prev/next
   buttons and page number buttons above the ROM table, along with a
   `"${total} unique ROMs · Page ${page} of ${pageCount}"` count label.

6. **Wire Search button** to `submitSwarmMasterSearch()` instead of
   `showSwarmMasterList(false)` so a new search resets to page 1.

7. **Reduce artwork per_page** from 500 → 100 at overmind.js ~line 3098
   (the master-artwork parallel fetch in `loadSwarmRomAvailabilityPanel`).

---

## Critical Files

| File | Fixes |
|------|-------|
| `src/overmind/postgres_store.py` | Fix 1 (CTE window function), Fix 2 (GIN index), Fix 3a (count_device_assets) |
| `src/overmind/db.py` | Fix 3b (count_device_roms), Fix 4a (get_swarm_master_bios_page) |
| `src/overmind/main.py` | Fix 4b (bios handler), Fix 5 (remove refresh_persistent_state) |
| `src/overmind/static/js/overmind.js` | Fix 6 (pagination) |

---

## Execution Order

Fixes are independent of each other. Recommended order:
1. Fix 5 (trivial — just delete lines, no risk)
2. Fix 3 (low risk — add a method, fix a fallback)
3. Fix 4 (medium — new db method + handler cleanup)
4. Fix 1 (medium — restructure the main hot CTE query)
5. Fix 2 (medium — schema migration, deploy with care on large tables)
6. Fix 6 (medium — frontend pagination UI)

---

## Verification

1. **Unit test (Fix 1):** Start app locally, upload a known ROM set, call
   `GET /api/devices/{id}/master-roms?page=1&per_page=10` and verify:
   - `total` is correct (matches full count)
   - `roms` has ≤ 10 rows
   - Response time is roughly half vs. before

2. **Text search (Fix 2):** With pg_trgm installed, run
   `EXPLAIN ANALYZE SELECT ... WHERE lower(payload::text) LIKE '%mario%'` on
   `overmind_device_assets` — verify "Bitmap Index Scan on idx_...payload_trgm" appears.

3. **Count fix (Fix 3):** Check that `device_response()` renders the correct ROM count
   in the UI for a device whose ROMs live in `overmind_device_assets`.

4. **Bios endpoint (Fix 4):** Call `GET /api/master-bios?page=2&per_page=10` and verify
   paginated results come back instead of the full list.

5. **Frontend (Fix 6):** In the Swarm Master List view, verify page navigation buttons
   appear, searching resets to page 1, and the initial load only fetches 100 rows.

6. **Regression:** Verify `GET /api/devices/{id}/master-roms?status=missing` still
   correctly marks `present_on_selected` — this is the most complex filter path in
   `page_master_assets`.
