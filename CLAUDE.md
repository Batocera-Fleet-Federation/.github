# CLAUDE.md — Federation hub + infra (`.github`)

This is the **shared/federation repo**; it also serves as the workspace-level
overview (the federation root is not itself a git repo, so this file is the
checked-in home for cross-repo guidance — the root `CLAUDE.md` is a symlink to it).
This repo holds the local multi-container swarm, integration tests, AWS Terraform,
diagnostics, and issue-triage tooling.

## Federation overview

A **federation workspace** of three independently-versioned git repos:

- **`batocera.overmind/`** — central hub: FastAPI + Postgres (uvicorn/EC2 or AWS
  Lambda) **and** the always-on **Edge** (`src/overmind/edge/`). Control plane +
  relay/mux server.
- **`batocera.drone/`** — the device agent on each Batocera machine: stdlib
  `http.server` web app + SQLite cache + the outbound-only `app/transport/` stack.
- **`.github/`** — this repo: shared infra (swarm, integration tests, Terraform,
  diagnostics).

**Each repo has its own committed `CLAUDE.md`** (architecture, commands,
conventions) and auto-surfaced skills under `*/.claude/skills/` — read the matching
one before non-trivial work: Overmind (`overmind-db-management`,
`overmind-edge-networking`), Drone (`drone-db-management`,
`drone-p2p-transfer-security`, `drone-edge-networking`), shared
(`bff-ui-theme-functionality`). A change often **spans two repos** (e.g. a new
drone-reported field needs drone scan/upload + overmind ingest/UI; a networking
change spans `app/transport/` and `src/overmind/edge/`) — cross-reference both.

**Networking (outbound-only), in one paragraph.** Drones make **outbound
connections only** — no port-forward, public IP, or inbound HTTPS. Each Drone holds
one persistent mux to the **Edge**; asset bytes move Drone↔Drone over the best tier
(`LAN-direct → direct-public → UDP hole-punch → Edge relay`, fall-through on
failure), and the Edge **relays only as a last resort** (never sees plaintext on
other tiers, never carries bytes through the control plane). It is **single-source
P2P** (one best peer per transfer), **not** torrent-style swarming. **When is the
Edge needed?** Same-LAN P2P works **without** it (same-public-IP detection);
cross-network P2P needs the Edge **or** the legacy port-forward + reachability probe
(which auto-defaults on when there's no Edge, so toggling the Edge can't strand
cross-network drones). The Edge is opt-in (`enable_edge`, default off) and **not
free-tier** (~$35–40/mo Fargate+NLB; self-host `bff-edge` to avoid that). Depth:
the `drone-edge-networking` + `overmind-edge-networking` skills, and the **AWS
Terraform** section below for deploy + cost.

## Local swarm & integration tests (run from the federation root)

```bash
.github/scripts/import-batocera-test-data.sh    # needs ROMs in .github/data/roms/<system>/
.github/scripts/swarm-up.sh                      # 1 Overmind + 1 Edge + 4 Drone containers (Docker)
.github/scripts/run-integration-tests.sh         # unittest discover .github/tests
.github/scripts/swarm-down.sh --volumes
```

`docker/docker-compose.swarm.yml` includes the **`bff-edge`** service (built from
`batocera.overmind/Dockerfile.edge`) and wires Drones to it via `DRONE_EDGE_*`
(`DRONE_EDGE_ENABLED`, `DRONE_EDGE_URL=tls://bff-edge:9443`, `DRONE_EDGE_VERIFY_TLS`).

### Networking tests (`.github/tests/`)

- **`test_edge_relay_integration.py`** — in-process, cross-repo, **no Docker**
  (runs in CI). Imports the real Overmind Edge `MuxServer` (asyncio) and the real
  Drone `app.transport` client, stands them up over a self-signed TLS loopback,
  and moves a real asset through the Edge **relay** — the production path minus
  router/port-forward + TLS verify. Asserts outbound connect, the
  `TRANSFER_REQUEST→OFFER` handshake, relayed bytes match (sha256), the
  `active→completed` lifecycle, and offline-sender handling. Run it directly:
  `python3 -m pytest .github/tests/test_edge_relay_integration.py`.
- **`test_swarm_networking.py`** — black-box HTTP against the live swarm: Drones
  show `edge_online`, `GET /api/admin/transfers` is deployed + super-admin gated,
  device detail keeps its legacy reachability fields.
- **`test_swarm_integration.py`** — the broader live-swarm HTTP suite.

`run-integration-tests.sh` brings the swarm up (unless `USE_EXISTING_SWARM=true`)
then runs `python3 -m unittest discover .github/tests`, so any `test_*.py` here is
auto-included. The cross-repo relay test needs no swarm; the others do.

## AWS Terraform (`terraform/aws/us-east-1/`)

Lambda + API Gateway (HTTP) + RDS + ElastiCache + Route53. Scheduled jobs +
cadences in `locals.tf` (`notification-delivery`, `device-status`,
`public-reachability` — the last defaults conditional on the Edge: OFF when
`OVERMIND_EDGE_ENABLED` (Terraform sets it from `enable_edge`), ON without an Edge
so cross-network Drones keep a direct WAN path; the EventBridge rule still fires
and the job no-ops when disabled).

**Edge (`edge.tf`, gated on `var.enable_edge`, default false → no-op).** ECS
Fargate service running `overmind.edge.edge_app` behind a Network Load Balancer:
NLB TLS :443 (ACM cert for `<edge_subdomain>.<domain>`) → task :9443; the task runs
`EDGE_ALLOW_INSECURE` (TLS terminated at the NLB, in-VPC). DB creds + `SECRET_KEY`
injected from the existing `overmind/<env>/runtime` secret; `OVERMIND_REDIS_URL`
from ElastiCache. Edge SG + ingress to RDS (5432)/Redis (6379); ECR repo;
CloudWatch logs; task/exec IAM. Outputs `edge_endpoint` (set the Drones'
`DRONE_EDGE_URL`) + the edge ECR url. `terraform fmt`/`validate` pass; run
`terraform plan` before `apply`. **Follow-ups:** build+push the edge image to its
ECR repo (CI), and add a STUN/UDP NLB listener to enable prod hole-punch
(`EDGE_STUN_PORT=0` today, so prod falls back to relay).

**Deploy sequence (the ECS service references an image in an ECR repo Terraform
itself creates, so order matters — there is no edge-image CI yet, push is manual):**
```bash
# 1. app code (new endpoints + migrations 0015/0016) — normal Lambda deploy
.github/scripts/run-with-aws-credentials.sh .github/scripts/update-overmind-lambdas.sh
# 2. set enable_edge=true in tfvars, then create the ECR repo first
terraform apply -target=aws_ecr_repository.edge
# 3. build + push the edge image (context = batocera.overmind/, repo batocera-edge:edge-latest)
ECR=<acct>.dkr.ecr.us-east-1.amazonaws.com
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR
docker build -f batocera.overmind/Dockerfile.edge -t $ECR/batocera-edge:edge-latest batocera.overmind
docker push $ECR/batocera-edge:edge-latest
# 4. full apply (ECS/NLB/ACM DNS-validated/Route53 — a few min), then point drones
terraform apply && terraform output edge_endpoint   # -> tls://edge.<domain>:443
# 5. set DRONE_EDGE_ENABLED=1 + DRONE_EDGE_URL=<edge_endpoint> on drones; roll out
```
Setting `OVERMIND_EDGE_ENABLED` (auto from `enable_edge`) flips the
`public-reachability` default OFF, so the inbound probe stops once the Edge is up.

**Cost / when the Edge is needed.** The Edge is **not free-tier**: the Fargate task
(~$18/mo at the default 0.5 vCPU/1 GB) + NLB (~$16–21/mo) run 24/7 (≈$35–40/mo +
relay egress). It is **only needed for cross-network P2P** (drones in different
houses/NATs) — same-LAN transfers work P2P with the Edge off (LAN-direct uses
same-public-IP detection, no Edge). Cheaper paths: self-host the `bff-edge`
container on existing/cheap compute (skips the NLB+Fargate bill), or shrink
`edge_cpu/edge_memory`. With the Edge off, cross-network falls back to the legacy
direct-WAN path (needs port-forwarding + the auto-on reachability probe).

## Live diagnostics (read-only; never print/commit credentials)

```bash
.github/scripts/run-with-aws-credentials.sh <cmd>
.github/scripts/run-with-aws-credentials.sh .github/scripts/debug-overmind-lambda.sh
.github/scripts/debug-batocera-drone.sh          # read-only Batocera/Drone inspection
```
Do not modify or restart the remote drone without explicit approval.

## Skills (`.claude/skills/`, auto-surfaced)

`bff-ui-theme-functionality`. (Edge/Drone networking depth lives in the
`overmind-edge-networking` and `drone-edge-networking` skills in those repos.)
