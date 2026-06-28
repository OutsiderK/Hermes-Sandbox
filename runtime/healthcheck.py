#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path


def fail(message: str) -> int:
    print(message, file=sys.stderr)
    return 1


def main() -> int:
    if os.geteuid() == 0:
        return fail("Hermes healthcheck is running as root")

    state_path = Path("/tmp/hermes-supervisor.json")
    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
    except Exception as exc:
        return fail(f"cannot read supervisor state: {exc}")

    if state.get("status") != "running":
        return fail(f"supervisor status is {state.get('status')!r}")

    names = {item.get("name") for item in state.get("processes", [])}
    if not {"gateway", "dashboard"}.issubset(names):
        return fail(f"missing critical process: {names}")

    for item in state.get("processes", []):
        try:
            os.kill(int(item["pid"]), 0)
        except Exception as exc:
            return fail(f"process {item!r} is not alive: {exc}")

    try:
        with urllib.request.urlopen("http://127.0.0.1:9119/api/status", timeout=3) as response:
            if response.status != 200:
                return fail(f"dashboard status returned HTTP {response.status}")
            payload = json.load(response)
    except (OSError, urllib.error.URLError, ValueError) as exc:
        return fail(f"dashboard status check failed: {exc}")

    if payload.get("auth_required") is not True:
        return fail("dashboard auth gate is not active")

    providers = set(payload.get("auth_providers") or [])
    if "basic" not in providers:
        return fail(f"basic auth provider is not active: {providers}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
