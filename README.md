# Batocera Fleet Federation Shared Tools

This repo holds local swarm orchestration, integration tests, scripts, and test data.

## TL;DR

- Put ROM test data in `.github/data/roms/<system>/<files>`.
- Populate that folder with `scripts/import-roms-remotely.sh`.
- Run one Overmind and multiple Drone containers with `scripts/swarm-up.sh`.
- Drones check in with Overmind every 60 seconds by default.
- Each Drone gets its own identity and a copied, varied subset of ROMs.
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
.github/scripts/run-integration-tests.sh
```

Docker must be running. If no ROM files are present, the swarm scripts fail and tell you to import ROMs first.
