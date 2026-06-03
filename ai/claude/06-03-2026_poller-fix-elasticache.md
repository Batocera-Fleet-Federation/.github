# Plan: Poller Fix + ElastiCache Caching Layer

## Context

Two problems to solve:

1. **"Not Resolvable" despite drone at 72.176.228.250:8443** — Root cause is `poll_public_drone_reachability_once` iterating `db.devices.values()`, which is always empty on the PostgreSQL path. `db.refresh_persistent_state()` is a no-op when `postgres_store.url` is set (returns immediately at db.py:202), so `db.devices` is never populated in production. The poller probes zero devices.

2. **ElastiCache caching** — Add a Redis-backed caching layer to cut response times for expensive read operations (master asset pages, user device lists, ROM system summaries).

---

## Part 1 — Fix the Poller (Not Resolvable)

### 1a. Add `postgres_store.list_all_approved_devices()` (`postgres_store.py`)

Add after `list_user_devices` (~line 2199). Uses existing `_select_device_sql` and `_device_from_row` helpers:

```python
def list_all_approved_devices(
    self,
    limit: int = 0,
    oldest_checked_first: bool = True,
) -> Optional[list[dict]]:
    conn = self._core_connection(ensure_schema=False)
    if conn is None:
        return None
    order = "n.checked_at ASC NULLS FIRST, d.registered_at ASC" if oldest_checked_first else "d.registered_at ASC"
    limit_clause = f"LIMIT {max(1, int(limit))}" if limit else ""
    with conn:
        with conn.cursor() as cur:
            cur.execute(
                self._select_device_sql("d.approval_status = 'approved' AND d.removed_at IS NULL")
                + f" ORDER BY {order} {limit_clause}"
            )
            return [d for d in (self._device_from_row(row) for row in cur.fetchall()) if d]
```

### 1b. Add `postgres_store.update_device_reachability()` (`postgres_store.py`)

Write probe results directly to `drone_network_state` without needing an in-memory device dict:

```python
def update_device_reachability(self, drone_id: str, result: dict) -> bool:
    conn = self._core_connection(ensure_schema=False)
    if conn is None:
        return False
    resolvable = bool(result.get("resolvable"))
    probed_ip  = str(result.get("public_ip") or "") or None
    api_port   = int(result["api_port"]) if resolvable and result.get("api_port") else None
    checked_at = self._dt(result.get("checked_at"))
    with conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO drone_network_state
                    (drone_id, public_resolvable, public_ip, api_port, checked_at, updated_at)
                VALUES (%s, %s, %s, %s, %s, now())
                ON CONFLICT (drone_id) DO UPDATE SET
                    public_resolvable = EXCLUDED.public_resolvable,
                    public_ip   = COALESCE(EXCLUDED.public_ip, drone_network_state.public_ip),
                    api_port    = COALESCE(EXCLUDED.api_port,  drone_network_state.api_port),
                    checked_at  = EXCLUDED.checked_at,
                    updated_at  = now()
                """,
                (drone_id, resolvable, probed_ip, api_port, checked_at),
            )
    return True
```

### 1c. Rewrite `poll_public_drone_reachability_once()` (`main.py` ~line 453)

Replace in-memory dict iteration with postgres-direct query:

```python
def poll_public_drone_reachability_once() -> None:
    """Probe peer endpoints for all approved Drones."""
    if postgres_store.available():
        devices = postgres_store.list_all_approved_devices(
            limit=PUBLIC_PEER_PROBE_MAX_DEVICES_PER_RUN,
            oldest_checked_first=True,
        ) or []
    else:
        db.refresh_persistent_state()
        devices = [
            d for d in list(db.devices.values())
            if d.get("approval_status", "approved") == "approved"
        ]
        devices.sort(key=lambda d: str((d.get("public_reachability") or {}).get("checked_at") or ""))
        if PUBLIC_PEER_PROBE_MAX_DEVICES_PER_RUN:
            devices = devices[:PUBLIC_PEER_PROBE_MAX_DEVICES_PER_RUN]
    for device in devices:
        if device.get("approval_status", "approved") != "approved":
            continue
        if public_reachability_already_resolved(device):
            continue
        result = probe_device_public_endpoint(device)
        if postgres_store.available():
            postgres_store.update_device_reachability(device["id"], result)
        else:
            db.update_device_public_reachability(device["id"], result)
```

---

## Part 2 — ElastiCache Terraform

**File:** `.github/terraform/aws/us-east-1/main.tf`

Add a new section after the VPC endpoints block. Conditioned on
`var.enable_elasticache` (default `true`). Uses private subnets that already exist
when `lambda_create_nat_gateway = true`. Uses `aws_security_group_rule` resources
to match the existing SG rule pattern in this file.

```hcl
# ── ElastiCache (Redis) ──────────────────────────────────────────────────────

resource "aws_security_group" "elasticache" {
  count       = var.enable_elasticache ? 1 : 0
  name        = "${var.project_name}-${var.environment}-elasticache"
  description = "Redis access from Overmind Lambda functions"
  vpc_id      = aws_vpc.overmind.id
}

resource "aws_security_group_rule" "elasticache_from_lambda" {
  count                    = var.enable_elasticache ? 1 : 0
  type                     = "ingress"
  description              = "Redis from Lambda"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.elasticache[0].id
  source_security_group_id = aws_security_group.lambda[0].id
}

resource "aws_security_group_rule" "elasticache_egress" {
  count             = var.enable_elasticache ? 1 : 0
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.elasticache[0].id
}

resource "aws_elasticache_subnet_group" "overmind" {
  count      = var.enable_elasticache ? 1 : 0
  name       = "${var.project_name}-${var.environment}-cache"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_elasticache_cluster" "overmind" {
  count                = var.enable_elasticache ? 1 : 0
  cluster_id           = "${var.project_name}-${var.environment}-cache"
  engine               = "redis"
  node_type            = var.elasticache_node_type
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  engine_version       = "7.1"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.overmind[0].name
  security_group_ids   = [aws_security_group.elasticache[0].id]
}
```

Add `OVERMIND_REDIS_URL` to both Lambda `environment { variables { ... } }` blocks
via an additional `merge(...)` conditional:

```hcl
}, var.enable_elasticache ? {
  OVERMIND_REDIS_URL = "redis://${aws_elasticache_cluster.overmind[0].cache_nodes[0].address}:6379"
} : {})
```

**File:** `.github/terraform/aws/us-east-1/variables.tf` — append:

```hcl
variable "enable_elasticache" {
  description = "Create an ElastiCache Redis cluster (requires lambda_create_nat_gateway = true)"
  type        = bool
  default     = true
}

variable "elasticache_node_type" {
  description = "ElastiCache node instance type"
  type        = string
  default     = "cache.t3.micro"
}
```

**File:** `.github/terraform/aws/us-east-1/terraform.tfvars` — append:

```hcl
enable_elasticache    = true
elasticache_node_type = "cache.t3.micro"
```

**File:** `.github/terraform/aws/us-east-1/outputs.tf` — append:

```hcl
output "redis_endpoint" {
  description = "ElastiCache Redis endpoint"
  value       = var.enable_elasticache ? aws_elasticache_cluster.overmind[0].cache_nodes[0].address : null
}
```

---

## Part 3 — Application Caching Layer

### 3a. Add redis to `requirements.txt`

```
redis>=5.0.0
```

### 3b. Create `src/overmind/cache.py`

New module. Lazy-init Redis client, graceful degradation (returns `None` if Redis is down or unconfigured), short timeouts so a Redis hiccup never blocks a Lambda response:

```python
"""Redis-backed cache for Overmind. Falls back silently when Redis is unavailable."""
from __future__ import annotations
import hashlib, json, logging, os
from typing import Any, Optional

logger = logging.getLogger("overmind.cache")
_client = None


def _get_client():
    global _client
    if _client is None:
        url = (os.getenv("OVERMIND_REDIS_URL") or os.getenv("REDIS_URL") or "").strip()
        if url:
            try:
                import redis
                _client = redis.Redis.from_url(
                    url,
                    decode_responses=True,
                    socket_timeout=0.5,
                    socket_connect_timeout=0.5,
                )
            except Exception as exc:
                logger.warning("Redis init failed: %s", exc)
    return _client


def _key(*parts) -> str:
    return "overmind:" + ":".join(str(p) for p in parts)


def _hash(*parts) -> str:
    return hashlib.md5(json.dumps(parts, sort_keys=True, default=str).encode()).hexdigest()[:16]


def get(key: str) -> Optional[Any]:
    try:
        client = _get_client()
        if not client:
            return None
        raw = client.get(key)
        return json.loads(raw) if raw is not None else None
    except Exception:
        return None


def set(key: str, value: Any, ttl: int = 30) -> None:
    try:
        client = _get_client()
        if not client:
            return
        client.setex(key, ttl, json.dumps(value, default=str))
    except Exception:
        pass


def delete_pattern(pattern: str) -> None:
    try:
        client = _get_client()
        if not client:
            return
        keys = client.keys(pattern)
        if keys:
            client.delete(*keys)
    except Exception:
        pass


# ── Typed key builders ───────────────────────────────────────────────────────

def master_assets_key(device_ids: list[str], asset_type: str, **kwargs) -> str:
    return _key("ma", _hash(sorted(device_ids), asset_type, kwargs))


def user_devices_key(user_id: str, swarm_id: Optional[str] = None) -> str:
    return _key("ud", user_id, swarm_id or "")


def count_assets_key(device_id: str, asset_type: str) -> str:
    return _key("ca", device_id, asset_type)


def rom_systems_key(device_ids: list[str]) -> str:
    return _key("rs", _hash(sorted(device_ids)))


# ── Invalidation helpers ─────────────────────────────────────────────────────

def invalidate_user_devices(user_id: str) -> None:
    delete_pattern(_key("ud", user_id, "*"))


def invalidate_master_assets() -> None:
    delete_pattern(_key("ma", "*"))


def invalidate_asset_counts(device_id: str) -> None:
    delete_pattern(_key("ca", device_id, "*"))
```

### 3c. Add caching to `postgres_store.py`

Import at top of file (wrapped in try/except for circular-import safety):
```python
try:
    from overmind import cache as _cache
except Exception:
    _cache = None
```

**`list_user_devices`** — check cache before query, set 15s TTL after:
```python
if _cache:
    cache_key = _cache.user_devices_key(user_id, swarm_id)
    cached = _cache.get(cache_key)
    if cached is not None:
        return cached
# ... existing query into `result` ...
if _cache:
    _cache.set(cache_key, result, ttl=15)
return result
```

**`page_master_assets`** — check cache before query, set 30s TTL after the output list is built:
```python
if _cache:
    cache_key = _cache.master_assets_key(ids, asset_type,
        selected=selected_internal_id, q=query, sys=system_name,
        st=status, art=artwork_type, pg=page, pp=per_page)
    cached = _cache.get(cache_key)
    if cached is not None:
        return cached["rows"], cached["total"]
# ... existing query ...
if _cache:
    _cache.set(cache_key, {"rows": output, "total": total}, ttl=30)
return output, total
```

**`count_device_assets`** — 60s TTL:
```python
if _cache:
    cache_key = _cache.count_assets_key(device_id, asset_type)
    cached = _cache.get(cache_key)
    if cached is not None:
        return int(cached)
# ... existing query into `result` ...
if _cache:
    _cache.set(cache_key, result, ttl=60)
return result
```

**`summarize_rom_systems`** — 60s TTL:
```python
if _cache:
    cache_key = _cache.rom_systems_key(ids)
    cached = _cache.get(cache_key)
    if cached is not None:
        return cached
# ... existing query into `result` ...
if _cache:
    _cache.set(cache_key, result, ttl=60)
return result
```

### 3d. Cache invalidation in write paths

**`postgres_store.publish_device_asset_inventory`** — after the transaction commits:
```python
if _cache:
    _cache.invalidate_master_assets()
    _cache.invalidate_asset_counts(device_internal_id)
```

**`postgres_store.upsert_device_assets`** — after the transaction commits (only when rows were written):
```python
if _cache and prepared:
    _cache.invalidate_master_assets()
    _cache.invalidate_asset_counts(device_id)
```

**`db.accept_pending_drone_connection`** — after device is created:
```python
if _cache:
    _cache.invalidate_user_devices(user_id)
```

**`db.admin_delete_device`** — after device is removed:
```python
if _cache and owner_id:
    _cache.invalidate_user_devices(owner_id)
```

---

## Critical Files

| File | Change |
|------|--------|
| `batocera.overmind/src/overmind/postgres_store.py` | Add `list_all_approved_devices`, `update_device_reachability`, cache import, caching wrappers on 4 read methods, invalidation on 2 write methods |
| `batocera.overmind/src/overmind/main.py` | Rewrite `poll_public_drone_reachability_once` |
| `batocera.overmind/src/overmind/db.py` | Cache import, invalidation in `accept_pending_drone_connection` and `admin_delete_device` |
| `batocera.overmind/src/overmind/cache.py` | New file — Redis client + key/invalidation helpers |
| `batocera.overmind/requirements.txt` | Add `redis>=5.0.0` |
| `.github/terraform/aws/us-east-1/main.tf` | ElastiCache SG + rules, subnet group, cluster, `OVERMIND_REDIS_URL` in both Lambda env blocks |
| `.github/terraform/aws/us-east-1/variables.tf` | Add `enable_elasticache`, `elasticache_node_type` |
| `.github/terraform/aws/us-east-1/terraform.tfvars` | Set `enable_elasticache = true`, `elasticache_node_type = "cache.t3.micro"` |
| `.github/terraform/aws/us-east-1/outputs.tf` | Add `redis_endpoint` output |

---

## Dependency Note

`enable_elasticache = true` requires `lambda_create_nat_gateway = true` (already set in
`terraform.tfvars`). ElastiCache uses `aws_subnet.private[*].id` which only exists
when NAT Gateway is enabled.

---

## Execution Order

1. Part 1 (poller fix) — independent, deploy first to unblock "Not Resolvable"
2. Part 3a + 3b (requirements + cache.py) — no runtime effect until Redis URL is set
3. Part 2 (Terraform) — `terraform apply` to provision ElastiCache
4. Part 3c + 3d (caching wrappers) — activate after Redis endpoint is live

---

## Verification

1. **Poller fix**: Check CloudWatch logs for the `public-reachability` EventBridge job
   after deploy — should see probe activity instead of silence. Device at
   72.176.228.250 should flip to Resolvable within one 15-minute cycle, or trigger
   manually via `POST /api/admin/run-job?job=public-reachability`.

2. **ElastiCache**: After `terraform apply`, verify `redis_endpoint` output is populated.
   Run `redis-cli -h <endpoint> -p 6379 ping` → `PONG`.

3. **Caching**: Hit `GET /api/devices/{id}/master-roms` twice in quick succession —
   second call should be significantly faster. Run `redis-cli keys "overmind:*"` to
   confirm cache keys are populated.

4. **Cache invalidation**: Upload new ROM metadata, then verify master-roms reflects
   the updated data (not stale).
