# CLAUDE.md — Federation infra (`.github`)

Guidance for Claude Code when working in **this repo** (shared infra for the
Batocera Fleet Federation). Siblings: `batocera.overmind/` (hub + Edge),
`batocera.drone/` (device agent). This repo holds the local multi-container swarm,
integration tests, AWS Terraform, diagnostics, and issue-triage tooling.

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
`public-reachability` — the last relaxed/off by default for outbound-only).

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
