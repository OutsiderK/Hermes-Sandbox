# Hermes Secure for Windows + Docker Desktop

A security-focused Hermes deployment matching these constraints:

- Hermes, Dashboard, Gateway and every Hermes child process run as UID/GID `10000`, never root.
- The Windows input exchange directory is mounted at `/input` read-only.
- Hermes writes only to a Docker named volume (`/opt/data`).
- Results are placed in `/opt/data/outbox` and copied to Windows only by an explicit exporter container.
- The Dashboard is reachable only at `http://127.0.0.1:9119` and requires a password.
- The mihomo controller is reachable only at `http://127.0.0.1:9090` for local node switching and provider updates.
- Hermes has no Docker socket, no host namespace, no Linux capabilities and a read-only root filesystem.
- Public HTTP/HTTPS traffic goes through netguard, tinyproxy and mihomo. Hermes cannot connect directly to the host, LAN or Internet.
- There is intentionally **no automatic backup system**. Keep important projects in Git.

## What runs as root?

The **Hermes container never runs as root**. Two small trusted helper containers use limited root privileges:

1. `state-init` receives only the Docker state volume and sets its ownership to UID 10000, then exits.
2. `netguard` receives `NET_ADMIN` plus `SETUID`/`SETGID` long enough to install firewall rules and use `setpriv` to drop tinyproxy to UID 10001 with an empty capability set in its own network namespace. The entrypoint then uses `setpriv` to run tinyproxy as UID 10001 with an empty capability set. It has no Hermes files, no host files and no Docker socket.

Hermes shares only netguard's network namespace, not its filesystem, PID namespace or user identity. A non-root mihomo sidecar runs as UID 10002 in the same network namespace; tinyproxy can only forward to mihomo, and mihomo applies direct-domain and subscription-node policy.

## First-time setup

Prerequisites:

- Windows 10/11
- Docker Desktop using Linux containers
- PowerShell 5.1 or PowerShell 7

Open PowerShell in this project directory:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\hermes.ps1 init
.\scripts\hermes.ps1 proxy-subscription
.\scripts\hermes.ps1 start -Open
```

`init` performs these operations:

1. Creates `.env` and `secrets/hermes.env` locally.
2. Pulls the configured upstream images.
3. Resolves each mutable tag to an immutable `@sha256:` digest.
4. Creates local `proxy\mihomo.yaml` with a generated controller secret.
5. Builds the non-root runtime and network guard.
6. Prompts for a Dashboard username and password; only the scrypt hash is stored.

The Dashboard opens at `http://127.0.0.1:9119`.

## Daily use

```powershell
.\scripts\hermes.ps1 start -Open
.\scripts\hermes.ps1 stop
.\scripts\hermes.ps1 status
.\scripts\hermes.ps1 logs
```

Create a desktop shortcut:

```powershell
.\scripts\hermes.ps1 shortcut
```

The root-level `Start-Hermes.cmd` and `Stop-Hermes.cmd` files are also available.

## Supplying files to Hermes

Copy files into:

```text
exchange\inbox\
```

They appear at `/input` inside Hermes. The mount is enforced read-only by Docker and checked again at startup and by `audit.ps1`.

Do not put anything there that Hermes is not allowed to read or upload.

## Working projects and Git

Create projects under:

```text
/opt/data/workspace
```

Hermes can freely create, change and delete files there. Initialize important projects as Git repositories and push them to a remote you trust. The project deliberately does not back up the whole Docker volume.

The default egress policy supports public HTTP/HTTPS through the proxy, so use **Git over HTTPS** with a repository-scoped, revocable, short-lived token. Ordinary SSH on port 22 is intentionally blocked; do not give Hermes a general account credential.

## Proxy, direct rules and node switching

Hermes uses this path:

```text
Hermes -> tinyproxy -> mihomo -> DIRECT or subscription node
```

Set the Clash/mihomo subscription URL:

```powershell
.\scripts\hermes.ps1 proxy-subscription
```

Open the local mihomo GUI helper:

```powershell
.\scripts\hermes.ps1 proxy-ui
```

The script prints `http://127.0.0.1:9090` plus the controller secret, then opens `https://d.metacubex.one`. Add that API endpoint in the dashboard to switch nodes and update providers.

`proxy\mihomo.yaml` is ignored by Git and excluded from the Docker build context. The template sends mainland China domains and IPs direct by default, keeps the requested direct-domain list explicit for review, and netguard still blocks private, host, link-local and metadata ranges at the IP layer.

## API keys and tokens

The host `secrets\hermes.env` file is mounted read-only at `/run/secrets/hermes.env`. At container startup, the entrypoint copies it into the tmpfs-backed `/run/hermes/hermes.env`, and Hermes reads that runtime copy.

If a container process changes the runtime copy, the change lasts only for the current container lifecycle. The next restart overwrites it from the read-only host source. Persist a key from the host:

```powershell
.\scripts\hermes.ps1 secret-set DEEPSEEK_API_KEY
```

Then choose the provider/model in the Dashboard. Repeat for other variables such as `OPENROUTER_API_KEY` or `TELEGRAM_BOT_TOKEN`.

The Dashboard's API-key page may be able to modify the runtime copy, but it must not be used to persist keys because restart restores the host source file.

Rotate the Dashboard login:

```powershell
.\scripts\hermes.ps1 dashboard-password
```

## Exporting results: scheme A

Hermes writes deliverables to:

```text
/opt/data/outbox
```

Export them explicitly:

```powershell
.\scripts\hermes.ps1 export
```

The command briefly stops Hermes, launches a non-root/no-network exporter with the state volume read-only, rejects symbolic links, hard links, special files, unsafe Windows names and oversized data, and copies ordinary files to a timestamped directory under `exports\`.

The source outbox is not deleted automatically. After checking the export:

```powershell
.\scripts\hermes.ps1 outbox-clear
```

## Updating

```powershell
.\scripts\hermes.ps1 update
```

This re-resolves upstream tags to new immutable digests, rebuilds, restarts and audits the deployment. It does **not** create a state backup. Commit/push important project changes before updating.

To rebuild without changing upstream versions:

```powershell
.\scripts\hermes.ps1 rebuild
```

## Resetting

```powershell
.\scripts\hermes.ps1 reset
```

This deletes the Hermes named state volume. It does not delete:

- `exchange\inbox`
- `exports`
- `secrets\hermes.env`
- Git repositories already pushed to an external remote

No backup is created before reset.

## Security audit

Every successful `start` runs:

```powershell
.\scripts\hermes.ps1 audit
```

The audit checks the effective Docker configuration and performs write/network probes. A failure prevents the script from opening the Dashboard.

## Known trade-offs

- `apt install` is unavailable at runtime because Hermes is non-root and the image layer is read-only. Add common system packages in `Dockerfile.hermes` during a reviewed rebuild.
- Python user packages, virtual environments, NPM project dependencies and binaries placed under `/opt/data` remain possible.
- Programs that ignore standard HTTP proxy variables cannot access the Internet. Add a narrowly scoped sidecar rather than connecting Hermes directly to a normal Docker network.
- Hermes can read and potentially upload everything in `/input`, `/opt/data`, and any credential given to it.
- The mihomo subscription URL is proxy credential material; do not commit or export `proxy\mihomo.yaml`.
- Docker Desktop and the Linux kernel are still part of the trusted computing base; this design reduces attack surface but cannot guarantee immunity to unknown container-escape vulnerabilities.

See `docs/ARCHITECTURE.md` and `docs/SECURITY.md` for the full model.

## Validation notes

See [`docs/VALIDATION.md`](docs/VALIDATION.md) for completed checks and the first-run validation boundary.
