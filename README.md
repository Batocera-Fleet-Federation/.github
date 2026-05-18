# Batocera Fleet Federation Shared Tools

This repo holds local swarm orchestration, integration tests, scripts, and test data.

## TL;DR

- Put ROM test data in `.github/data/roms/<system>/<files>`.
- Populate that folder with `scripts/import-roms-remotely.sh`.
- Run one Overmind and four lightweight Drone containers with `scripts/swarm-up.sh`.
- Drones check in with Overmind every 60 seconds by default.
- Each Drone gets its own hostname, device id, MAC address, port, volume, and copied ROM subset.
- Fake data is off by default. Set `USE_FAKE_DATA=true` only when you intentionally want demo/preconfigured data.
- Run integration tests with `scripts/run-integration-tests.sh`.

From the federation workspace:

```bash
.github/scripts/import-roms-remotely.sh
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

Overmind builds a master ROM list from ROM metadata reported by approved Drones. On a selected Drone page, Overmind shows which swarm ROMs are missing on that Drone. Choose a ROM or system to sync; the target Drone automatically chooses the best source peer using recent peer health and speed samples. Overmind coordinates the action and records sync activity, but it does not transfer ROM files.
