#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import os
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_env_parser() -> None:
    supervisor = load_module("secure_supervisor", ROOT / "runtime/supervisor.py")
    with tempfile.TemporaryDirectory() as temp:
        path = Path(temp) / "env"
        path.write_text(
            "# comment\n"
            "PLAIN=value\n"
            "HASH=scrypt$16384$8$1$abc$def\n"
            "QUOTED='hello world'\n",
            encoding="utf-8",
        )
        parsed = supervisor.load_env_file(path)
        assert parsed["PLAIN"] == "value"
        assert parsed["HASH"].startswith("scrypt$")
        assert parsed["QUOTED"] == "hello world"


def test_exporter() -> None:
    exporter = load_module("secure_exporter", ROOT / "runtime/export_outbox.py")
    with tempfile.TemporaryDirectory() as temp:
        base = Path(temp)
        source = base / "source"
        destination = base / "destination"
        source.mkdir()
        (source / "nested").mkdir()
        (source / "hello.txt").write_text("hello", encoding="utf-8")
        (source / "nested" / "data.bin").write_bytes(b"abc")
        count, total, manifest = exporter.copy_tree(source, destination)
        assert count == 2
        assert total == 8
        assert (destination / "hello.txt").read_text(encoding="utf-8") == "hello"
        assert len(manifest) == 2

        symlink_source = base / "symlink-source"
        symlink_destination = base / "symlink-destination"
        symlink_source.mkdir()
        try:
            os.symlink(source / "hello.txt", symlink_source / "bad-link")
        except (OSError, NotImplementedError):
            return
        try:
            exporter.copy_tree(symlink_source, symlink_destination)
        except ValueError as exc:
            assert "symbolic links" in str(exc)
        else:
            raise AssertionError("symlink export was not rejected")


def test_exporter_limits() -> None:
    exporter = load_module("secure_exporter_limits", ROOT / "runtime/export_outbox.py")
    with tempfile.TemporaryDirectory() as temp:
        base = Path(temp)

        source = base / "entry-source"
        source.mkdir()
        (source / "one.txt").write_text("1", encoding="utf-8")
        (source / "two.txt").write_text("2", encoding="utf-8")
        old_entries = exporter.MAX_ENTRIES
        try:
            exporter.MAX_ENTRIES = 1
            try:
                exporter.copy_tree(source, base / "entry-destination")
            except ValueError as exc:
                assert "entry limit" in str(exc)
            else:
                raise AssertionError("entry limit was not enforced")
        finally:
            exporter.MAX_ENTRIES = old_entries

        source = base / "depth-source"
        (source / "a" / "b").mkdir(parents=True)
        (source / "a" / "b" / "file.txt").write_text("x", encoding="utf-8")
        old_depth = exporter.MAX_DEPTH
        try:
            exporter.MAX_DEPTH = 1
            try:
                exporter.copy_tree(source, base / "depth-destination")
            except ValueError as exc:
                assert "depth limit" in str(exc)
            else:
                raise AssertionError("depth limit was not enforced")
        finally:
            exporter.MAX_DEPTH = old_depth

        source = base / "path-source"
        source.mkdir()
        (source / "long-name.txt").write_text("x", encoding="utf-8")
        old_path = exporter.MAX_RELATIVE_PATH_CHARS
        try:
            exporter.MAX_RELATIVE_PATH_CHARS = 5
            try:
                exporter.copy_tree(source, base / "path-destination")
            except ValueError as exc:
                assert "length limit" in str(exc)
            else:
                raise AssertionError("path length limit was not enforced")
        finally:
            exporter.MAX_RELATIVE_PATH_CHARS = old_path


if __name__ == "__main__":
    test_env_parser()
    test_exporter()
    test_exporter_limits()
    print("RUNTIME TESTS PASSED")
