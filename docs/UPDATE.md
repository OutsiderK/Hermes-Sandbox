# Update policy

`hermes.ps1 update` performs:

1. Pull mutable source tags listed in `.env`.
2. Resolve them to immutable repository digests.
3. Store those digests in `.env`.
4. Rebuild the derived runtime and netguard images.
5. Restart the deployment if it was running.
6. Run the full effective-configuration audit.

No state-volume backup is made. Before updating, commit and push important projects from `/opt/data/workspace` to Git.

Review these files when changing the framework itself:

- `compose.yaml`
- `Dockerfile.hermes`
- `runtime/run-stack.sh`
- `runtime/supervisor.py`
- `netguard/entrypoint.sh`
- `netguard/tinyproxy.conf`
- `proxy/mihomo.yaml.example`
- `scripts/audit.ps1`

Particularly sensitive changes are new mounts, ports, capabilities, namespace sharing, writable paths, direct-domain rules, proxy-node port allowlists and proxy exceptions.
