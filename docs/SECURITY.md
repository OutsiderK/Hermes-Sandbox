# Security model

## Assumed compromised

Assume that all of the following can become malicious:

- the model and its generated commands;
- prompt-injected webpages and documents;
- Hermes skills/plugins;
- packages installed under `/opt/data`;
- every file in the Hermes state volume;
- scheduled jobs and child agents.

## Protected assets

The architecture is designed not to expose:

- Windows user profiles, Desktop, Documents or Downloads;
- browser cookies/passwords;
- SSH/GPG credentials unless explicitly supplied;
- the Docker socket or Docker Desktop control plane;
- other containers and volumes;
- host/LAN services and cloud metadata endpoints.

## Hard controls

- UID/GID 10000 in the Hermes container.
- no runtime UID 0 process.
- `cap_drop: ALL` and `no-new-privileges`.
- read-only root filesystem.
- no host PID, IPC or network namespace.
- a single read-only host input mount.
- a named state volume instead of a Windows user-directory bind.
- Dashboard host publication restricted to `127.0.0.1`.
- mihomo controller publication restricted to `127.0.0.1`.
- mandatory Dashboard basic authentication with an scrypt password hash.
- owner-based egress firewall plus mihomo policy routing and destination filtering.
- no Docker socket, device passthrough or privileged mode.

## Secrets

A secret used by Hermes cannot be hidden from a fully compromised Hermes process. Therefore every credential should be:

- dedicated to Hermes;
- minimally scoped;
- rate/credit limited;
- independently revocable;
- unable to administer the host or Docker environment.

The host secret file is read-only to Hermes, preventing persistence changes, but its values are inherited by Hermes child processes when needed.

## Residual risks

- An unknown Docker Desktop, Linux kernel or container-runtime escape.
- Exfiltration of data that the user deliberately placed in `/input` or `/opt/data`.
- Abuse of API keys intentionally granted to Hermes.
- Public Internet abuse over HTTP/HTTPS or configured proxy-node ports, since web/model access is a required capability.
- Leakage or abuse of the local Clash subscription URL in `proxy/mihomo.yaml`.
- A vulnerability in the trusted netguard, mihomo or state-init helper images.

This is a containment design, not a claim of absolute isolation.
