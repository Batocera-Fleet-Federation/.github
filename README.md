# Batocera Fleet Federation Shared Tools

This repo holds local swarm orchestration, integration tests, scripts, and test data.

## TL;DR

- Put ROM test data in `.github/data/roms/<system>/<files>` and BIOS test data in `.github/data/bios/<files>`.
- Populate that folder with `scripts/import-batocera-test-data.sh`.
- Run one Overmind and four lightweight Drone containers with `scripts/swarm-up.sh`.
- Drones check in with Overmind every 60 seconds by default.
- Each Drone gets its own hostname, device id, MAC address, port, volume, and copied ROM subset.
- Fake data is off by default. Set `USE_FAKE_DATA=true` only when you intentionally want demo/preconfigured data.
- Run integration tests with `scripts/run-integration-tests.sh`.

From the federation workspace:

```bash
.github/scripts/import-batocera-test-data.sh
.github/scripts/swarm-up.sh
.github/scripts/swarm-status.sh
.github/scripts/run-integration-tests.sh
.github/scripts/swarm-down.sh --volumes
```

The integration tests can also run against existing endpoints:

```bash
USE_EXISTING_SWARM=true \
OVERMIND_URL=http://overmind.example:8000 \
DRONE_A_URL=https://drone-a.example:8443 \
DRONE_B_URL=https://drone-b.example:8443 \
DRONE_C_URL=https://drone-c.example:8443 \
DRONE_D_URL=https://drone-d.example:8443 \
.github/scripts/run-integration-tests.sh
```

Docker must be running. If no ROM files are present, the swarm scripts fail and tell you to import ROMs first.

`swarm-up.sh` generates per-Drone ROM userdata under `.github/generated/drone-*/userdata/roms` before starting Compose. Each Drone gets a deterministic randomized subset when `--seed` is supplied, and each generated `gamelist.xml` contains only files copied into that Drone:

```bash
.github/scripts/swarm-up.sh --import-data --reset-data --seed local-demo
```

## Scripts

### TL;DR: deploy the latest Overmind Lambda image

After `batocera-overmind:lambda-latest` has been pushed to ECR, update the AWS Lambda functions with:

```bash
.github/scripts/update-overmind-lambdas.sh
```

The script defaults to production:

```bash
AWS_REGION=us-east-1
PROJECT_NAME=bff-overmind
ENVIRONMENT=prod
ECR_REPO=batocera-overmind
TAG=lambda-latest
```

Lambda pins an image digest when function code is updated, so pushing a new `lambda-latest` image to ECR is not enough by itself. Run `update-overmind-lambdas.sh` after the image push to make these functions re-resolve the tag:

```text
bff-overmind-prod-low
bff-overmind-prod-medium
bff-overmind-prod-high
bff-overmind-prod-scheduled
```

To deploy a different tag or environment, override only the value you need:

```bash
TAG=v0.0.17-alpha .github/scripts/update-overmind-lambdas.sh
```

### TL;DR: collect Overmind Lambda debug logs

For the serverless AWS deployment, collect API Gateway state, Lambda configuration, recent Lambda logs, API Gateway access logs, DNS output, and curl timing with:

```bash
.github/scripts/debug-overmind-lambda.sh
```

The script saves one file per diagnostic section, plus `combined.log`, under:

```text
.github/scripts/debug-output/overmind-lambda/<timestamp>/
```

It defaults to:

```bash
AWS_REGION=us-east-1
PROJECT_NAME=bff-overmind
ENVIRONMENT=prod
PUBLIC_URL=https://www.batocera-swarm.com
SINCE=1h
```

To collect a larger window:

```bash
SINCE=6h .github/scripts/debug-overmind-lambda.sh
```

## Onboarding

The default swarm starts Drones as real unapproved devices. They know the Overmind URL, submit a pending request, and show up in Overmind as **Psionic connection detected**. The Overlord approves them from the Drones page.

For token-based onboarding, generate a Drone authorization token in Overmind, paste it into the Drone admin Overmind Integration page with the Overlord email, then start integration. The old integration password flow is deprecated.

## Peer mTLS

Drone-to-Drone calls use each Drone's local certificate. Before calling a peer, Drone asks Overmind for that approved peer's public certificate and caches it under:

```text
/userdata/system/drone-app/peer-certs/
```

If a peer call fails with an unknown CA or certificate error, Drone refreshes the cached peer certificate from Overmind and retries once. Private keys are never sent to Overmind.

## ROM Sync

Overmind builds a master ROM list from disk-authoritative ROM metadata reported by approved Drones. Drone inventory walks `/userdata/roms/<system>` and treats `gamelist.xml` as optional metadata enrichment only. ROM identity is md5-based: matching md5 means the ROM is already present even if the filename differs, while same-name/different-md5 downloads use normal collision suffixes such as `(2)` and `(3)`.

On a selected Drone page, Overmind shows which swarm ROMs are missing on that Drone. Choose a ROM or system to sync; the target Drone automatically chooses the best source peer using recent peer health and speed samples. Overmind coordinates the action and records sync activity, but it does not transfer ROM files. Completed peer downloads report duration, md5, bytes, and inventory refresh status back to Overmind. The Drones page also includes swarm-wide Sync Activity search and a md5-deduplicated Master List.
