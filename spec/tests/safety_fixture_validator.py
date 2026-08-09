from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path


class FixtureValidationError(ValueError):
    pass


_CREDENTIAL_PATTERN = re.compile(
    r"sk-[A-Za-z0-9_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|"
    r"(?:authorization|api[_-]?key|bearer)[^\n]{0,80}(?:[A-Za-z0-9_-]{16,})",
    re.IGNORECASE,
)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _read_hash_manifest(path: Path) -> dict[Path, str]:
    entries: dict[Path, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        digest, separator, relative = line.partition("  ")
        if not separator or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise FixtureValidationError("invalid extension hash manifest")
        relative_path = Path(relative)
        if relative_path.is_absolute() or ".." in relative_path.parts or relative_path in entries:
            raise FixtureValidationError("unsafe extension hash manifest path")
        entries[relative_path] = digest
    if not entries:
        raise FixtureValidationError("extension hash manifest is empty")
    return entries


def _assert_no_credentials(root: Path) -> None:
    for path in root.rglob("*"):
        if path.is_file() and _CREDENTIAL_PATTERN.search(path.read_text(encoding="utf-8")):
            raise FixtureValidationError("credential-like fixture content")


def validate_fixture(root: Path) -> dict[str, int]:
    root = Path(root)
    home = root / "home"
    expected_path = root / "expected-preservation.json"
    manifest = _read_hash_manifest(root / "extensions.sha256")
    if not home.is_dir() or not expected_path.is_file():
        raise FixtureValidationError("missing synthetic fixture files")

    _assert_no_credentials(home)
    extension_files = {
        path.relative_to(root)
        for directory in (home / "skills", home / "plugins", home / "mcp")
        if directory.is_dir()
        for path in directory.rglob("*")
        if path.is_file()
    }
    if extension_files != set(manifest):
        raise FixtureValidationError("extension tree does not match hash manifest")
    for relative, expected_hash in manifest.items():
        source = root / relative
        if not source.is_file() or _sha256(source) != expected_hash:
            raise FixtureValidationError("extension hash mismatch")

    snapshot = {
        "threadRowCount": len(re.findall(r"(?im)^\s*INSERT\s+INTO\s+threads\b", (home / "threads.sql").read_text(encoding="utf-8"))),
        "sessionJsonlCount": len(list((home / "sessions").rglob("*.jsonl"))),
        "extensionFileCount": len(manifest),
    }
    expected = json.loads(expected_path.read_text(encoding="utf-8"))
    if snapshot != expected:
        raise FixtureValidationError("preservation snapshot mismatch")
    return snapshot
