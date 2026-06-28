#!/usr/bin/env python3
"""Copy /opt/data/outbox to a host export directory without following links.

Run only through the dedicated exporter service. Hermes is stopped by the
PowerShell wrapper before this process starts, so the read-only source is stable.
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import stat
import sys
from pathlib import Path

SOURCE = Path("/opt/data/outbox")
EXPORT_ROOT = Path("/export")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$")
WINDOWS_RESERVED = {
    "CON", "PRN", "AUX", "NUL",
    *(f"COM{i}" for i in range(1, 10)),
    *(f"LPT{i}" for i in range(1, 10)),
}
INVALID_WINDOWS_CHARS = set('<>:"/\\|?*')
MAX_FILE = int(os.environ.get("EXPORT_MAX_FILE_BYTES", str(512 * 1024 * 1024)))
MAX_TOTAL = int(os.environ.get("EXPORT_MAX_TOTAL_BYTES", str(2 * 1024 * 1024 * 1024)))
MAX_ENTRIES = int(os.environ.get("EXPORT_MAX_ENTRIES", "20000"))
MAX_DEPTH = int(os.environ.get("EXPORT_MAX_DEPTH", "32"))
MAX_RELATIVE_PATH_CHARS = int(os.environ.get("EXPORT_MAX_RELATIVE_PATH_CHARS", "220"))
MAX_COMPONENT_CHARS = int(os.environ.get("EXPORT_MAX_COMPONENT_CHARS", "96"))


def validate_component(name: str) -> None:
    if not name or name in {".", ".."}:
        raise ValueError(f"invalid path component: {name!r}")
    if len(name) > MAX_COMPONENT_CHARS:
        raise ValueError(f"path component exceeds export limit: {name!r}")
    if name[-1] in {" ", "."}:
        raise ValueError(f"Windows-incompatible trailing character: {name!r}")
    if any(ord(ch) < 32 or ch in INVALID_WINDOWS_CHARS for ch in name):
        raise ValueError(f"Windows-incompatible filename: {name!r}")
    stem = name.split(".", 1)[0].upper()
    if stem in WINDOWS_RESERVED:
        raise ValueError(f"Windows reserved filename: {name!r}")


def open_verified_regular(path: Path, expected: os.stat_result) -> int:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags)
    actual = os.fstat(fd)
    if not stat.S_ISREG(actual.st_mode):
        os.close(fd)
        raise ValueError(f"not a regular file: {path}")
    if (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino):
        os.close(fd)
        raise ValueError(f"file changed during export: {path}")
    if actual.st_nlink != 1:
        os.close(fd)
        raise ValueError(f"hard-linked files are not exported: {path}")
    return fd


def copy_tree(source: Path, destination: Path) -> tuple[int, int, list[str]]:
    total = 0
    count = 0
    entry_count = 0
    manifest: list[str] = []

    def validate_relative_path(relative: Path) -> None:
        if len(relative.parts) > MAX_DEPTH:
            raise ValueError(f"path exceeds export depth limit: {relative}")
        if len(relative.as_posix()) > MAX_RELATIVE_PATH_CHARS:
            raise ValueError(f"path exceeds export length limit: {relative}")

    def walk(src: Path, dst: Path, relative: Path) -> None:
        nonlocal total, count, entry_count
        with os.scandir(src) as iterator:
            entries = sorted(iterator, key=lambda entry: entry.name.casefold())
        for entry in entries:
            validate_component(entry.name)
            entry_count += 1
            if entry_count > MAX_ENTRIES:
                raise ValueError("outbox exceeds export entry limit")
            child_src = src / entry.name
            child_dst = dst / entry.name
            child_rel = relative / entry.name
            validate_relative_path(child_rel)
            metadata = entry.stat(follow_symlinks=False)

            if stat.S_ISLNK(metadata.st_mode):
                raise ValueError(f"symbolic links are not exported: {child_rel}")
            if stat.S_ISDIR(metadata.st_mode):
                child_dst.mkdir(mode=0o700)
                walk(child_src, child_dst, child_rel)
                continue
            if not stat.S_ISREG(metadata.st_mode):
                raise ValueError(f"special files are not exported: {child_rel}")
            if metadata.st_nlink != 1:
                raise ValueError(f"hard-linked files are not exported: {child_rel}")
            if metadata.st_size > MAX_FILE:
                raise ValueError(f"file exceeds export limit: {child_rel}")
            total += metadata.st_size
            if total > MAX_TOTAL:
                raise ValueError("outbox exceeds total export limit")

            fd = open_verified_regular(child_src, metadata)
            digest = hashlib.sha256()
            temp = child_dst.with_name(child_dst.name + ".partial")
            try:
                with os.fdopen(fd, "rb", closefd=True) as source_file, open(temp, "xb") as target_file:
                    while True:
                        block = source_file.read(1024 * 1024)
                        if not block:
                            break
                        target_file.write(block)
                        digest.update(block)
                    target_file.flush()
                    os.fsync(target_file.fileno())
                os.chmod(temp, 0o600)
                os.replace(temp, child_dst)
            finally:
                try:
                    temp.unlink()
                except FileNotFoundError:
                    pass

            count += 1
            manifest.append(f"{digest.hexdigest()}  {child_rel.as_posix()}")

    destination.mkdir(mode=0o700)
    walk(source, destination, Path())
    return count, total, manifest


def main() -> int:
    if os.geteuid() == 0:
        print("Refusing to export as root", file=sys.stderr)
        return 70
    name = os.environ.get("EXPORT_NAME", "")
    if not NAME_RE.fullmatch(name):
        print("EXPORT_NAME is missing or invalid", file=sys.stderr)
        return 71
    if not SOURCE.is_dir():
        print("Outbox does not exist", file=sys.stderr)
        return 72

    destination = EXPORT_ROOT / name
    if destination.exists():
        print(f"Export destination already exists: {destination}", file=sys.stderr)
        return 73

    try:
        count, total, manifest = copy_tree(SOURCE, destination)
        manifest_path = destination / "MANIFEST.sha256"
        manifest_path.write_text("\n".join(manifest) + ("\n" if manifest else ""), encoding="utf-8")
        os.chmod(manifest_path, 0o600)
    except Exception as exc:
        shutil.rmtree(destination, ignore_errors=True)
        print(f"Export rejected: {exc}", file=sys.stderr)
        return 74

    print(f"Exported {count} file(s), {total} byte(s) to {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
