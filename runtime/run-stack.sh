#!/bin/sh
set -eu

if [ "$(id -u)" -eq 0 ]; then
  echo "FATAL: Hermes must never run as root." >&2
  exit 70
fi

umask 077

for dir in /opt/data /opt/data/workspace /opt/data/outbox /opt/data/cache /opt/data/logs /opt/data/.local; do
  if [ ! -d "$dir" ]; then
    echo "FATAL: required state directory is missing: $dir" >&2
    echo "Run the state-init service through scripts/hermes.ps1 start." >&2
    exit 71
  fi
done

if [ ! -w /opt/data/workspace ] || [ ! -w /opt/data/outbox ]; then
  echo "FATAL: Hermes state volume is not writable by UID $(id -u)." >&2
  exit 72
fi

root_probe="/.__hermes_rootfs_probe_$$"
if ( : > "$root_probe" ) 2>/dev/null; then
  rm -f "$root_probe"
  echo "FATAL: container root filesystem is writable." >&2
  exit 73
fi

input_probe="/input/.__hermes_input_probe_$$"
if ( : > "$input_probe" ) 2>/dev/null; then
  rm -f "$input_probe"
  echo "FATAL: /input is writable; refusing to start." >&2
  exit 74
fi

if [ ! -r /opt/data/.env ]; then
  echo "FATAL: /opt/data/.env is missing or unreadable." >&2
  exit 75
fi

if [ ! -f /opt/data/config.yaml ]; then
  cp /opt/secure/config.default.yaml /opt/data/config.yaml
  chmod 0600 /opt/data/config.yaml
fi

exec python /opt/secure/supervisor.py
