#!/usr/bin/env bash
set -euo pipefail

VM_MEM="${VM_MEM:-4096}"
VM_CPUS="${VM_CPUS:-2}"
VM_DISK="${VM_DISK:-/vms/batocera.img}"
SSH_PORT="${SSH_PORT:-2222}"
VNC_PORT="${VNC_PORT:-5901}"

echo "======================================="
echo "Starting Batocera VM inside Docker"
echo "======================================="
echo "Memory: ${VM_MEM} MB"
echo "CPUs:   ${VM_CPUS}"
echo "Disk:   ${VM_DISK}"
echo "VNC:    host localhost:${VNC_PORT}"
echo "SSH:    host localhost:${SSH_PORT} -> guest :22"
echo "======================================="

export QEMU_AUDIO_DRV=none

exec qemu-system-x86_64 \
  -machine q35 \
  -m "${VM_MEM}" \
  -smp "${VM_CPUS}" \
  -drive file="${VM_DISK}",format=raw,snapshot=on,if=none,id=batocera_disk \
  -device ich9-ahci,id=ahci \
  -device ide-hd,drive=batocera_disk,bus=ahci.0 \
  -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
  -device e1000,netdev=net0 \
  -vnc 0.0.0.0:1 \
  -display none \
  -serial mon:stdio