# Architecture

```text
Windows browser
  │ http://127.0.0.1:9119
  ▼
netguard network namespace
  ├─ host port forwarding to Dashboard:9119
  ├─ host port forwarding to mihomo controller:9090
  ├─ UID firewall
  ├─ tinyproxy (UID 10001)
  ├─ mihomo (UID 10002)
  └─ Hermes container shares this network namespace only
       ├─ secure supervisor (UID 10000, PID 1)
       ├─ hermes dashboard (UID 10000)
       ├─ hermes gateway run --no-supervise (UID 10000)
       ├─ /input                read-only Windows bind
       └─ /opt/data             writable Docker named volume
            ├─ workspace
            ├─ outbox
            ├─ config.yaml
            ├─ sessions/memory/skills
            └─ user packages/cache
```

## Process supervision

The official image normally starts its root s6 init layer. This project overrides that entrypoint. A small Python PID 1 starts the Gateway and Dashboard directly as UID 10000. If either exits, the whole container exits and Docker's `unless-stopped` policy restarts it.

The Gateway remains running because it is responsible for messaging integrations, cron ticks and other background maintenance. Dashboard chat runs the real Hermes TUI through its PTY/WebSocket path.

## File boundaries

### Read-only input

`exchange/inbox` is the only host input mount and maps to `/input` with Docker's read-only flag. Both startup and runtime audit attempt a write and fail closed if it succeeds.

### Private writable state

A Docker named volume maps only to `/opt/data`. It is considered untrusted and disposable. Hermes can destroy all of it.

### Explicit output

The Hermes service never mounts `exports`. The exporter service is separate, non-root, networkless and reads the state volume read-only. The host export directory is visible only to that one-shot service.

## Network boundary

Hermes uses `network_mode: service:netguard`, giving it no independent Docker network attachment. Owner rules in the shared namespace implement:

- UID 10000: local loopback only; all non-loopback egress rejected.
- UID 10001: local loopback to mihomo port 7890 only.
- UID 10002: Docker DNS plus the public TCP port allowlist; private/reserved destinations rejected after resolution.
- all other UIDs: rejected.

Hermes receives `HTTP_PROXY`, `HTTPS_PROXY` and `ALL_PROXY` pointing to loopback tinyproxy. tinyproxy forwards to mihomo, which applies the direct-domain list and Clash subscription policy. Host ports 9119 and 9090 are published by netguard only to Windows `127.0.0.1`.

## Trusted helpers

`state-init`, `netguard` and `mihomo` are intentionally narrow. None receives the Docker socket. `state-init` has no network and sees only named volumes. `netguard` sees no Hermes filesystem or Windows bind mount. `mihomo` sees only its read-only local config and writable named provider cache.
