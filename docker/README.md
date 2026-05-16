# Batocera Docker/QEMU Test Runner

## TL;DR

This folder builds a reusable Docker image that contains **QEMU and the VM startup logic only**. The Batocera `.img` file is **not copied into the Docker image**.

Instead, the Batocera image is mounted at runtime by `run.sh`:

```bash
./download-batocera-image.sh x86_64
./build.sh
./run.sh
```

What this means:

```text
Docker image = small reusable QEMU runner
Batocera .img = local runtime-mounted disk image
GHCR push = pushes only the runner, not the huge Batocera image
```

SSH into Batocera from another terminal:

```bash
ssh -p 2222 root@localhost
```

Default password:

```text
linux
```

Open the Batocera screen with a VNC client:

```text
localhost:5901
```

On macOS:

```bash
open vnc://localhost:5901
```

For Apple Silicon Macs running the x86_64 Batocera image, the scripts default to `linux/amd64`. You can also pass it explicitly:

```bash
./build.sh --platform linux/amd64
./run.sh --platform linux/amd64
```

---

## What Changed

Earlier versions copied the Batocera `.img` file into the Docker image during build.

That approach worked, but it made the Docker image very large and caused problems when pushing to GitHub Container Registry.

The current design does **not** copy Batocera into the Docker image.

Current behavior:

- `build.sh` builds the QEMU runner image only.
- `push.sh` pushes the QEMU runner image only.
- `run.sh` mounts the local Batocera `.img` file into the container at runtime.
- The Batocera `.img` remains local and is not uploaded to GHCR.

Runtime mount path:

```text
local batocera*.img -> /vms/batocera.img inside container
```

---

## What This Is

This project starts a Batocera `.img` file inside QEMU, with QEMU running from a Docker container.

It is intended for quick, disposable testing. It is not intended to replace running Batocera on real hardware.

## What It Is Useful For

Use this to test:

- Batocera startup behavior
- Custom scripts
- Drone install scripts
- File paths and permissions
- SSH access
- Logs
- Config changes
- Quick tear-down/re-run workflows

## What It Is Not For

This is not ideal for:

- Real emulator performance testing
- GPU acceleration
- Controller or Bluetooth testing
- Accurate hardware passthrough
- Production Batocera usage

---

## Project Structure

```text
.
├── Dockerfile
├── entrypoint.sh
├── download-batocera-image.sh
├── build.sh
├── run.sh
├── push.sh
├── README.md
└── batocera-v43_x86_64.img
```

The `.img` file is shown because it exists locally after download, but it is not copied into the Docker image.

---

## Requirements

You need:

- macOS or Linux
- Rancher Desktop or Docker Engine
- Docker-compatible engine enabled, such as Rancher Desktop `dockerd/moby`
- Docker `buildx` for push workflows
- Homebrew on macOS for the downloader script
- Enough disk space for the Batocera image and Docker build layers

If using Rancher Desktop, verify Docker is working:

```bash
docker info
```

If using Rancher Desktop, make sure the active Docker context is correct:

```bash
docker context ls
docker context use rancher-desktop
```

---

## Download a Batocera Image

Use `download-batocera-image.sh` to download a Batocera image using `aria2c` for multi-threaded downloads.

The image key or URL is passed as an input parameter:

```bash
./download-batocera-image.sh <image-key-or-url>
```

List available image keys:

```bash
./download-batocera-image.sh
```

Download the x86_64 image:

```bash
./download-batocera-image.sh x86_64
```

Download from a direct Batocera image URL:

```bash
./download-batocera-image.sh "https://updates.batocera.org/x86_64/stable/last/batocera-x86_64-43-20260430.img.gz"
```

The script checks for Homebrew and installs `aria2` if `aria2c` is missing.

By default, the script decompresses the downloaded `.gz` or `.zip` file and deletes the archive after successful extraction.

### Common Image Keys

Examples include:

```text
x86_64
pc
desktop
steamdeck
rpi5
rpi4
rpi3
rpi2
rpi1
rpi0
odroid-goa
odroid-c2
odroid-c4
odroid-n2
odroid-xu4
rg351p
rg353
rg552
orangepi5
orangepi5b
orangepi5plus
rock5b
rockpro64
khadas-vim3
khadas-edge2
```

### Downloader Tuning

The image key or URL is an input parameter. Optional tuning uses environment variables.

| Variable | Default | Description |
|---|---:|---|
| `OUTPUT_DIR` | `.` | Directory to save the image |
| `OUTPUT_NAME` | derived from URL | Output filename |
| `CONNECTIONS` | `8` | Connections per server |
| `SPLITS` | `8` | Download split count |
| `DECOMPRESS` | `true` | Decompress `.gz` or `.zip` after download |
| `DELETE_ARCHIVE_AFTER_DECOMPRESS` | `true` | Delete archive after successful decompression |
| `BATOCERA_VERSION` | `43` | Batocera version used in generated URLs |
| `BATOCERA_DATE` | `20260430` | Batocera build date used in generated URLs |

Example using a specific output filename:

```bash
OUTPUT_NAME="batocera-v43_x86_64.img.gz" ./download-batocera-image.sh x86_64
```

Expected decompressed result:

```text
batocera-v43_x86_64.img
```

---

## Build Locally

Use `build.sh` to build the local Docker image.

```bash
./build.sh
```

This builds a QEMU runner image only. It does **not** require a Batocera `.img` file to exist.

Resulting local tags:

```text
ghcr.io/batocera-fleet-federation/batocera-emulator:v43
ghcr.io/batocera-fleet-federation/batocera-emulator:latest
batocera-emulator:test
```

The short local tag `batocera-emulator:test` is created for simple local runs.

### build.sh Parameters

```bash
./build.sh --help
```

| Parameter | Default | Description |
|---|---:|---|
| `--image-registry` | `ghcr.io` | Container registry used for image tags |
| `--image-owner` | `Batocera-Fleet-Federation` | Image owner or organization |
| `--image-name` | `batocera-emulator` | Image name |
| `--image-tag` | `v43` | Image version tag |
| `--local-image-name` | `batocera-emulator:test` | Short local image tag |
| `--dockerfile` | `Dockerfile` | Dockerfile path |
| `--build-context` | `.` | Docker build context |
| `--platform` | auto-detected | Docker platform |
| `--tag-local-short` | `true` | Whether to create the short local tag |

Examples:

```bash
./build.sh
./build.sh --platform linux/amd64
./build.sh --image-tag v43
./build.sh clean
```

---

## Run Locally

Use `run.sh` to run the disposable Batocera VM container.

```bash
./run.sh
```

By default, `run.sh` scans the current directory for exactly one file matching:

```text
batocera*.img
```

If exactly one match is found, it is mounted into the container as:

```text
/vms/batocera.img
```

If no image is found, `run.sh` errors and tells you to download or specify one.

If multiple images are found, `run.sh` errors and tells you to specify which one to use.

Specify the Batocera image explicitly:

```bash
./run.sh --batocera-img ./batocera-v43_x86_64.img
```

Run with more memory and CPUs:

```bash
./run.sh --memory 8192 --cpus 4
```

Run a specific Docker image:

```bash
./run.sh --image-name ghcr.io/batocera-fleet-federation/batocera-emulator:v43
```

Run with explicit platform:

```bash
./run.sh --platform linux/amd64
```

Clean an existing container:

```bash
./run.sh --clean
```

### run.sh Parameters

| Parameter | Default | Description |
|---|---:|---|
| `--image-name` | `batocera-emulator:test` | Docker image to run |
| `--container-name` | `batocera-emulator-test` | Container name |
| `--memory` | `4096` | VM memory in MB |
| `--cpus` | `2` | VM CPU count |
| `--ssh-port` | `2222` | Host SSH port |
| `--vnc-port` | `5901` | Host VNC port |
| `--platform` | auto-detected | Docker platform |
| `--batocera-img` | auto-detect `batocera*.img` | Batocera image to mount at runtime |
| `--clean` | disabled | Stop/remove existing container and exit |

### Equivalent docker run Command

`run.sh` wraps this Docker command:

```bash
docker run --rm -it \
  --name batocera-emulator-test \
  --platform linux/amd64 \
  -p 2222:2222 \
  -p 5901:5901 \
  -v "$PWD/batocera-v43_x86_64.img:/vms/batocera.img:ro" \
  -e VM_MEM=4096 \
  -e VM_CPUS=2 \
  batocera-emulator:test
```

The `:ro` mount makes the Batocera image read-only from the container perspective. QEMU uses snapshot mode, so test changes are discarded when the VM stops.

---

## SSH Into Batocera

After the VM boots, connect from another terminal:

```bash
ssh -p 2222 root@localhost
```

Default password:

```text
linux
```

If SSH hangs, first verify the port is open:

```bash
nc -vz localhost 2222
```

If the port is open but SSH hangs after printing `Local version string`, QEMU is forwarding the port but Batocera has not returned an SSH banner yet. Check VNC to confirm whether Batocera has booted.

---

## Open VNC

Use a VNC client and connect to:

```text
localhost:5901
```

On macOS:

```bash
open vnc://localhost:5901
```

VNC is useful for checking whether Batocera is actually booting if SSH does not respond.

---

## Push to GitHub Container Registry

Use `push.sh` for GHCR publishing.

`push.sh` pushes the QEMU runner image only. It does **not** push or validate a Batocera `.img` file.

Login to GHCR:

```bash
./push.sh login \
  --ghcr-username mynameisjerrod \
  --ghcr-token YOUR_GITHUB_TOKEN_WITH_WRITE_PACKAGES
```

Push the multi-platform image:

```bash
./push.sh push
```

Push only x86 / amd64:

```bash
./push.sh push-x86
```

Push only ARM64:

```bash
./push.sh push-arm
```

Push the Apple Silicon tag:

```bash
./push.sh push-apple
```

Inspect the pushed manifest:

```bash
./push.sh inspect
```

Clean the buildx builder:

```bash
./push.sh clean
```

### push.sh Commands

| Command | Description |
|---|---|
| `login` | Login to GitHub Container Registry |
| `push` | Build and push a multi-platform image |
| `push-x86` | Build and push `linux/amd64` only |
| `push-arm` | Build and push `linux/arm64` only |
| `push-apple` | Build and push an Apple Silicon tag backed by `linux/arm64` |
| `inspect` | Inspect the pushed image manifest |
| `clean` | Remove the buildx builder created by the script |
| `help` | Show script help |

### push.sh Parameters

| Parameter | Default | Description |
|---|---:|---|
| `--image-registry` | `ghcr.io` | Container registry |
| `--image-owner` | `Batocera-Fleet-Federation` | GHCR owner or organization |
| `--image-name` | `batocera-emulator` | Image name |
| `--image-tag` | `v43` | Image version tag |
| `--dockerfile` | `Dockerfile` | Dockerfile path |
| `--build-context` | `.` | Docker build context |
| `--builder-name` | `batocera-emulator-builder` | Docker buildx builder name |
| `--platforms` | `linux/amd64,linux/arm64` | Platforms for multi-platform push |
| `--ghcr-username` | unset | GitHub username for GHCR login |
| `--ghcr-token` | unset | GitHub token with `write:packages` permission |

Examples:

```bash
./push.sh push --image-tag v43
./push.sh push-x86 --image-tag v43
./push.sh push --platforms linux/amd64
```

---

## How It Works

Docker builds an image containing:

- QEMU
- networking tools
- SSH client tools
- `entrypoint.sh`

Docker does **not** build in the Batocera `.img` file.

When `run.sh` starts the container, it mounts the selected local Batocera image here:

```text
/vms/batocera.img
```

Then `entrypoint.sh` starts QEMU against that mounted disk image.

Runtime port mappings expose:

```text
localhost:2222 -> Batocera SSH port 22
localhost:5901 -> QEMU VNC display
```

QEMU runs the Batocera image in snapshot mode. Any changes made during the VM session are temporary and discarded when the VM stops.

The Docker container runs with `--rm`, so the container is removed automatically after shutdown.

This means each run starts clean, and the original Batocera image stays unchanged.

---

## Current QEMU Behavior

The entrypoint uses:

- AHCI/SATA disk instead of VirtIO disk
- `e1000` network instead of VirtIO network
- QEMU audio disabled
- VNC enabled on `localhost:5901`
- SSH forwarded on `localhost:2222`
- snapshot mode so disk changes are discarded

These choices are intended to make the Batocera image more likely to boot cleanly in QEMU.

---

## Copy Files Into the VM

Once the VM is running, copy files in with `scp`.

Example script copy:

```bash
scp -P 2222 ./my-script.sh root@localhost:/userdata/system/scripts/
```

Example ROM copy:

```bash
scp -P 2222 -r ./test-roms/* root@localhost:/userdata/roms/
```

---

## Stop the VM

From the terminal running Docker/QEMU:

```text
Ctrl+C
```

Or from the QEMU monitor:

```text
Ctrl+A, then X
```

After shutdown, the container is removed and VM changes are discarded.