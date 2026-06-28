#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
failures: list[str] = []


def expect(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


compose = yaml.safe_load((ROOT / "compose.yaml").read_text(encoding="utf-8"))
services = compose["services"]
hermes = services["hermes"]
netguard = services["netguard"]
mihomo = services["mihomo"]
exporter = services["exporter"]
state_init = services["state-init"]

expect(hermes.get("user") == "10000:10000", "Hermes user must be 10000:10000")
expect(hermes.get("read_only") is True, "Hermes rootfs must be read-only")
expect(hermes.get("privileged") is not True, "Hermes must not be privileged")
expect(hermes.get("cap_drop") == ["ALL"], "Hermes must drop all capabilities")
expect("no-new-privileges:true" in hermes.get("security_opt", []), "Hermes needs no-new-privileges")
expect(hermes.get("network_mode") == "service:netguard", "Hermes must share netguard namespace")
expect("ports" not in hermes, "Hermes service must not publish ports")

mounts = {m["target"]: m for m in hermes.get("volumes", []) if isinstance(m, dict)}
expect(mounts.get("/input", {}).get("read_only") is True, "/input must be read-only")
expect(mounts.get("/opt/data/.env", {}).get("read_only") is True, "secret file must be read-only")
expect(any(isinstance(m, str) and m.endswith(":/opt/data") for m in hermes.get("volumes", [])), "state volume missing")

ports = netguard.get("ports", [])
expect(len(ports) == 2 and all(str(port).startswith("127.0.0.1:") for port in ports), "Published ports must bind host loopback")
expect(any(str(port).startswith("127.0.0.1:9119:") for port in ports), "Dashboard must bind host loopback")
expect(any(str(port).startswith("127.0.0.1:9090:") for port in ports), "mihomo controller must bind host loopback")
expect(netguard.get("cap_drop") == ["ALL"], "netguard must drop all capabilities first")
expect(set(netguard.get("cap_add", [])) == {"NET_ADMIN", "SETUID", "SETGID"}, "netguard capability set is unexpected")

expect(mihomo.get("user") == "10002:10002", "mihomo user must be 10002:10002")
expect(mihomo.get("network_mode") == "service:netguard", "mihomo must share netguard namespace")
expect(mihomo.get("read_only") is True, "mihomo rootfs must be read-only")
expect(mihomo.get("cap_drop") == ["ALL"], "mihomo must drop all capabilities")
expect("no-new-privileges:true" in mihomo.get("security_opt", []), "mihomo needs no-new-privileges")
mihomo_mounts = {m["target"]: m for m in mihomo.get("volumes", []) if isinstance(m, dict)}
expect(mihomo_mounts.get("/etc/mihomo/config.yaml", {}).get("read_only") is True, "mihomo config must be read-only")
expect(mihomo_mounts.get("/var/lib/mihomo", {}).get("type") == "volume", "mihomo state volume missing")

expect(exporter.get("network_mode") == "none", "exporter must be networkless")
expect(exporter.get("user") == "10000:10000", "exporter must be non-root")
expect(exporter.get("read_only") is True, "exporter rootfs must be read-only")
expect(state_init.get("network_mode") == "none", "state-init must be networkless")
expect(state_init.get("read_only") is True, "state-init rootfs must be read-only")

for service_name, service in services.items():
    expect(service.get("privileged") is not True, f"{service_name} must not be privileged")
    expect(service.get("network_mode") != "host", f"{service_name} must not use host network")
    for mount in service.get("volumes", []):
        rendered = str(mount)
        expect("docker.sock" not in rendered and "docker_engine" not in rendered, f"{service_name} exposes Docker control: {rendered}")

run_stack = (ROOT / "runtime/run-stack.sh").read_text(encoding="utf-8")
expect('if [ "$(id -u)" -eq 0 ]' in run_stack, "runtime root assertion missing")
expect("/input is writable" in run_stack, "input write assertion missing")

supervisor = (ROOT / "runtime/supervisor.py").read_text(encoding="utf-8")
expect(re.search(r"[\"\']gateway[\"\']\s*,\s*\[\s*[\"\']hermes[\"\']\s*,\s*[\"\']gateway[\"\']\s*,\s*[\"\']run[\"\']\s*,\s*[\"\']--no-supervise[\"\']", supervisor, re.S) is not None, "gateway foreground command missing")
expect('"--host",\n                "0.0.0.0"' in supervisor, "dashboard container bind missing")
expect("scrypt$" in supervisor, "dashboard hash validation missing")

netguard_script = (ROOT / "netguard/entrypoint.sh").read_text(encoding="utf-8")
expect("--uid-owner \"$HERMES_UID\" -j REJECT" in netguard_script, "Hermes direct egress reject missing")
expect("HERMES_LOOPBACK_TCP_PORTS" in netguard_script, "Hermes loopback allowlist missing")
expect("--uid-owner \"$HERMES_UID\" -o lo -p tcp -m multiport --dports \"$HERMES_LOOPBACK_TCP_PORTS\"" in netguard_script, "Hermes loopback TCP restriction missing")
expect("--uid-owner \"$PROXY_UID\" -o lo -p tcp --dport 7890" in netguard_script, "tinyproxy-to-mihomo restriction missing")
expect("--uid-owner \"$MIHOMO_UID\" -p tcp -m multiport --dports \"$MIHOMO_TCP_PORTS\"" in netguard_script, "mihomo public TCP allowlist missing")
expect("169.254.0.0/16" in netguard_script and "192.168.0.0/16" in netguard_script, "private network blocks missing")

ps_script = (ROOT / "scripts/hermes.ps1").read_text(encoding="utf-8")
expect("Assert-HostPathLayout" in ps_script and "ReparsePoint" in ps_script, "host path reparse-point guard missing")
expect("No state-volume backup was created" in ps_script, "update must state no backup")
expect(re.search(r"'export'.*Export-Outbox", ps_script, re.S) is not None, "export command missing")
expect("Security audit failed; Hermes will be stopped" in ps_script, "startup must fail closed after audit failure")
expect("@('stop', 'hermes', 'mihomo', 'netguard')" in ps_script, "startup failure stop action missing")
expect("'proxy-subscription'" in ps_script and "'proxy-ui'" in ps_script, "mihomo helper commands missing")

audit_script = (ROOT / "scripts/audit.ps1").read_text(encoding="utf-8")
expect("Test-SafeHostPath" in audit_script and "ReparsePoint" in audit_script, "audit host path guard missing")
expect("7890, 9090" in audit_script, "audit forbidden sidecar loopback probe missing")

exporter_script = (ROOT / "runtime/export_outbox.py").read_text(encoding="utf-8")
expect("EXPORT_MAX_ENTRIES" in exporter_script, "export entry limit missing")
expect("EXPORT_MAX_DEPTH" in exporter_script, "export depth limit missing")
expect("EXPORT_MAX_RELATIVE_PATH_CHARS" in exporter_script, "export relative path limit missing")

mihomo_example = (ROOT / "proxy/mihomo.yaml.example").read_text(encoding="utf-8")
expect("DOMAIN-SUFFIX,deepseek.com,DIRECT" in mihomo_example, "DeepSeek direct rule missing")
expect("DOMAIN,dictionary.cambridge.org,DIRECT" in mihomo_example, "Cambridge direct rule missing")
expect("GEOSITE,CN,DIRECT" in mihomo_example and "GEOIP,CN,DIRECT" in mihomo_example, "Mainland China direct rules missing")
expect("external-controller: 0.0.0.0:9090" in mihomo_example, "mihomo controller config missing")

if failures:
    print("STATIC CHECK FAILED")
    for item in failures:
        print(f" - {item}")
    sys.exit(1)

print("STATIC CHECK PASSED")
