#!/usr/bin/env python3
"""Minimal non-root PID 1 for Hermes Dashboard + Gateway.

The whole container exits if either critical process exits. Docker's restart
policy then restarts the complete stack, avoiding a large privileged init layer.
"""

from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict

SECRET_FILE = Path(os.environ.get("HERMES_SECRET_EFFECTIVE_FILE", "/run/hermes/hermes.env"))
STATE_FILE = Path("/tmp/hermes-supervisor.json")
REQUIRED_DASHBOARD_VARS = (
    "HERMES_DASHBOARD_BASIC_AUTH_USERNAME",
    "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH",
    "HERMES_DASHBOARD_BASIC_AUTH_SECRET",
)
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def log(message: str) -> None:
    print(f"[secure-supervisor] {message}", flush=True)


def load_env_file(path: Path) -> Dict[str, str]:
    values: Dict[str, str] = {}
    text = path.read_text(encoding="utf-8-sig")
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"{path}:{number}: expected KEY=VALUE")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not KEY_RE.fullmatch(key):
            raise ValueError(f"{path}:{number}: invalid environment key {key!r}")
        if value[:1] == value[-1:] and value[:1] in {"'", '"'}:
            value = value[1:-1]
        if "\x00" in value or "\n" in value or "\r" in value:
            raise ValueError(f"{path}:{number}: multiline/NUL values are not supported")
        values[key] = value
    return values


def write_state(processes: Dict[int, str], status: str) -> None:
    payload = {
        "uid": os.geteuid(),
        "status": status,
        "processes": [{"pid": pid, "name": name} for pid, name in processes.items()],
        "updated_at": time.time(),
    }
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload), encoding="utf-8")
    os.replace(tmp, STATE_FILE)


def terminate_all(processes: Dict[int, str], grace: float = 20.0) -> None:
    for pid, name in list(processes.items()):
        try:
            os.killpg(pid, signal.SIGTERM)
            log(f"sent SIGTERM to {name} (pid {pid})")
        except ProcessLookupError:
            pass

    deadline = time.monotonic() + grace
    while processes and time.monotonic() < deadline:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            processes.clear()
            break
        if pid == 0:
            time.sleep(0.1)
            continue
        processes.pop(pid, None)

    for pid, name in list(processes.items()):
        try:
            os.killpg(pid, signal.SIGKILL)
            log(f"sent SIGKILL to {name} (pid {pid})")
        except ProcessLookupError:
            pass

    while processes:
        try:
            pid, _ = os.waitpid(-1, 0)
        except ChildProcessError:
            break
        processes.pop(pid, None)


def main() -> int:
    if os.geteuid() == 0:
        log("FATAL: refusing to run as root")
        return 70

    try:
        secrets = load_env_file(SECRET_FILE)
    except Exception as exc:
        log(f"FATAL: cannot load secrets file: {exc}")
        return 75

    env = os.environ.copy()
    env.update(secrets)

    missing = [name for name in REQUIRED_DASHBOARD_VARS if not env.get(name)]
    if missing:
        log("FATAL: dashboard authentication is not configured: " + ", ".join(missing))
        return 76

    if not env["HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH"].startswith("scrypt$"):
        log("FATAL: dashboard password must be stored as an scrypt hash")
        return 77

    commands = [
        (
            "gateway",
            ["hermes", "gateway", "run", "--no-supervise"],
        ),
        (
            "dashboard",
            [
                "hermes",
                "dashboard",
                "--host",
                "0.0.0.0",
                "--port",
                "9119",
                "--no-open",
            ],
        ),
    ]

    processes: Dict[int, str] = {}
    stopping = False

    def request_stop(signum: int, _frame: object) -> None:
        nonlocal stopping
        stopping = True
        log(f"received signal {signum}; stopping")

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGHUP, request_stop)

    try:
        for name, command in commands:
            log(f"starting {name}: {' '.join(command)}")
            proc = subprocess.Popen(
                command,
                env=env,
                cwd="/opt/data/workspace",
                stdin=subprocess.DEVNULL,
                stdout=None,
                stderr=None,
                start_new_session=True,
                close_fds=True,
            )
            processes[proc.pid] = name
            write_state(processes, "starting")
            time.sleep(1.0)

        write_state(processes, "running")

        while not stopping:
            try:
                pid, status = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                log("FATAL: all child processes disappeared")
                return 78

            if pid == 0:
                time.sleep(0.25)
                continue

            name = processes.pop(pid, "child")
            if name in {"gateway", "dashboard"}:
                if os.WIFEXITED(status):
                    detail = f"exit code {os.WEXITSTATUS(status)}"
                elif os.WIFSIGNALED(status):
                    detail = f"signal {os.WTERMSIG(status)}"
                else:
                    detail = f"status {status}"
                log(f"FATAL: critical process {name} exited ({detail})")
                write_state(processes, "failed")
                return 79
            log(f"reaped orphan child pid {pid}")

        write_state(processes, "stopping")
        return 0
    finally:
        terminate_all(processes)
        write_state({}, "stopped")


if __name__ == "__main__":
    sys.exit(main())
