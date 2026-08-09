#!/usr/bin/env python3
"""Safely switch providers in one shared Codex home directory."""

from __future__ import annotations

import argparse
import csv
from contextlib import closing
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid


PROVIDERS = {
    "openai": {
        "display_name": "OpenAI",
        "env_key": None,
        "reasoning_effort": "medium",
        "review_model": None,
    },
    "qilin": {
        "display_name": "Qilin",
        "env_key": "QILIN_API_KEY",
        "reasoning_effort": "xhigh",
        "review_model": "gpt-5.5",
    },
    "vectorengine": {
        "display_name": "VectorEngine",
        "env_key": "VECTORENGINE_API_KEY",
        "reasoning_effort": "xhigh",
        "review_model": "gpt-5.5",
    },
}

CODEX_PROCESS_NAMES = {"chatgpt.exe", "codex.exe", "codex-code-mode-host.exe"}

MANAGED_BASE_URLS = (
    "https://www.qilinapi.com/v1",
    "https://api.vectorengine.ai/v1",
    "https://api.vectorengine.cn/v1",
)

MANAGED_TABLES = '''[model_providers.qilin]
name = "Qilin OpenAI-compatible API"
base_url = "https://www.qilinapi.com/v1"
wire_api = "responses"
env_key = "QILIN_API_KEY"

[model_providers.vectorengine]
name = "VectorEngine OpenAI-compatible API"
base_url = "https://api.vectorengine.cn/v1"
wire_api = "responses"
env_key = "VECTORENGINE_API_KEY"
'''


def _validate_provider(provider: str) -> dict[str, str | None]:
    if provider not in PROVIDERS:
        raise ValueError(f"Unsupported provider: {provider}")
    return PROVIDERS[provider]


def _newline_for(text: str) -> str:
    return "\r\n" if "\r\n" in text else "\n"


def _split_table_blocks(text: str) -> tuple[list[str], list[tuple[str, list[str]]]]:
    lines = text.splitlines(keepends=True)
    table_starts = [
        index for index, line in enumerate(lines) if line.lstrip().startswith("[")
    ]
    if not table_starts:
        return lines, []

    root = lines[: table_starts[0]]
    blocks: list[tuple[str, list[str]]] = []
    header_pattern = re.compile(r"^\s*\[([^]]+)]")
    for position, start in enumerate(table_starts):
        end = table_starts[position + 1] if position + 1 < len(table_starts) else len(lines)
        block = lines[start:end]
        match = header_pattern.match(block[0])
        if match:
            blocks.append((match.group(1).strip(), block))
    return root, blocks


def _is_managed_block(name: str, block: list[str]) -> bool:
    if name in {"model_providers.qilin", "model_providers.vectorengine"}:
        return True
    if name.startswith(("model_providers.qilin.", "model_providers.vectorengine.")):
        return True
    if name == "model_providers.custom":
        rendered = "".join(block).lower()
        return any(url.lower() in rendered for url in MANAGED_BASE_URLS)
    return False


def _replace_root_key(
    lines: list[str], key: str, value: str | None, newline: str
) -> list[str]:
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=")
    result: list[str] = []
    replaced = False
    for line in lines:
        if pattern.match(line):
            if value is not None and not replaced:
                result.append(f"{key} = {value}{newline}")
                replaced = True
            continue
        result.append(line)
    if value is not None and not replaced:
        result.append(f"{key} = {value}{newline}")
    return result


def _set_table_key(
    blocks: list[tuple[str, list[str]]],
    table: str,
    key: str,
    value: str,
    newline: str,
) -> list[tuple[str, list[str]]]:
    key_pattern = re.compile(rf"^\s*{re.escape(key)}\s*=")
    result: list[tuple[str, list[str]]] = []
    found_table = False
    for name, block in blocks:
        if name != table:
            result.append((name, block))
            continue
        found_table = True
        rendered = [block[0]]
        found_key = False
        for line in block[1:]:
            if key_pattern.match(line):
                if not found_key:
                    rendered.append(f"{key} = {value}{newline}")
                    found_key = True
                continue
            rendered.append(line)
        if not found_key:
            rendered.insert(1, f"{key} = {value}{newline}")
        result.append((name, rendered))
    if not found_table:
        result.append((table, [f"[{table}]{newline}", f"{key} = {value}{newline}"]))
    return result


def render_config(original: str, provider: str) -> str:
    definition = _validate_provider(provider)
    newline = _newline_for(original)
    root, blocks = _split_table_blocks(original)
    blocks = [(name, block) for name, block in blocks if not _is_managed_block(name, block)]

    root = _replace_root_key(root, "model", '"gpt-5.6-sol"', newline)
    root = _replace_root_key(root, "model_provider", f'"{provider}"', newline)
    root = _replace_root_key(
        root,
        "model_reasoning_effort",
        f'"{definition["reasoning_effort"]}"',
        newline,
    )
    review_model = definition["review_model"]
    root = _replace_root_key(
        root,
        "review_model",
        f'"{review_model}"' if review_model else None,
        newline,
    )

    blocks = _set_table_key(blocks, "history", "persistence", '"save-all"', newline)

    while root and not root[-1].strip():
        root.pop()
    rendered_parts = root[:]
    if rendered_parts:
        rendered_parts.append(newline)
    for _, block in blocks:
        rendered_parts.extend(block)
        if rendered_parts and rendered_parts[-1].strip():
            rendered_parts.append(newline)

    managed = MANAGED_TABLES.replace("\n", newline)
    rendered_parts.append(managed)
    return "".join(rendered_parts).rstrip() + newline


def _backup_database(source_path: Path, backup_path: Path) -> None:
    with closing(sqlite3.connect(source_path, timeout=10)) as source:
        with closing(sqlite3.connect(backup_path)) as destination:
            source.backup(destination)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _sqlite_content_hash(path: Path) -> str:
    with closing(sqlite3.connect(f"file:{path}?mode=ro", uri=True)) as connection:
        if connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise RuntimeError("State database integrity check failed")
        dump = "\n".join(connection.iterdump()).encode("utf-8")
    return hashlib.sha256(dump).hexdigest()


def _file_hashes(root: Path, suffix: str | None = None) -> dict[str, str]:
    if not root.is_dir():
        return {}
    return {
        path.relative_to(root).as_posix(): _sha256(path)
        for path in sorted(root.rglob("*"))
        if path.is_file() and (suffix is None or path.suffix == suffix)
    }


def _preservation_snapshot(config_dir: Path, state_db_path: Path | None) -> dict[str, object]:
    thread_count = 0
    if state_db_path and state_db_path.exists():
        with closing(sqlite3.connect(f"file:{state_db_path}?mode=ro", uri=True)) as connection:
            thread_count = connection.execute("SELECT COUNT(*) FROM threads").fetchone()[0]
    return {
        "thread_count": thread_count,
        "sessions": _file_hashes(config_dir / "sessions", suffix=".jsonl"),
        "extensions": {
            name: _file_hashes(config_dir / name)
            for name in ("skills", "plugins", "mcp")
        },
    }


def _verify_preservation(before: dict[str, object], after: dict[str, object]) -> None:
    if before != after:
        raise RuntimeError("Conversation or extension preservation verification failed")


def _verify_backup_manifest(manifest_path: Path, artifacts: list[Path]) -> None:
    try:
        expected = json.loads(manifest_path.read_text(encoding="utf-8"))["files"]
    except (OSError, KeyError, json.JSONDecodeError) as error:
        raise RuntimeError("Backup manifest is missing or invalid") from error
    for artifact in artifacts:
        if not artifact.exists() or expected.get(artifact.name) != _sha256(artifact):
            raise RuntimeError(f"Backup verification failed: {artifact.name}")


def _restore_config(config_backup: Path, config_path: Path) -> None:
    temp_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            dir=config_path.parent,
            prefix=".restore-provider-",
            suffix=".toml",
            delete=False,
        ) as handle:
            temp_path = Path(handle.name)
        shutil.copy2(config_backup, temp_path)
        os.replace(temp_path, config_path)
        temp_path = None
    finally:
        if temp_path and temp_path.exists():
            temp_path.unlink()


def _acquire_lock(lock_dir: Path, timeout_seconds: float = 10.0) -> str:
    deadline = time.monotonic() + timeout_seconds
    owner_id = uuid.uuid4().hex
    while True:
        try:
            lock_dir.mkdir()
            try:
                (lock_dir / "owner.json").write_text(
                    json.dumps(
                        {
                            "owner_id": owner_id,
                            "pid": os.getpid(),
                            "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                        },
                        sort_keys=True,
                    ),
                    encoding="utf-8",
                )
            except Exception:
                lock_dir.rmdir()
                raise
            return owner_id
        except FileExistsError:
            if time.monotonic() >= deadline:
                raise RuntimeError("Another provider switch is still in progress")
            time.sleep(0.2)


def _release_lock(lock_dir: Path, owner_id: str) -> None:
    try:
        owner = json.loads((lock_dir / "owner.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError("Provider switch lock ownership was lost") from error
    if owner.get("owner_id") != owner_id:
        raise RuntimeError("Provider switch lock ownership was lost")
    (lock_dir / "owner.json").unlink()
    lock_dir.rmdir()


def _codex_processes() -> tuple[str, ...]:
    if os.name != "nt":
        return ()
    try:
        result = subprocess.run(
            ["tasklist", "/FO", "CSV", "/NH"],
            capture_output=True,
            check=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise RuntimeError("Unable to verify that Codex is not running") from error
    return tuple(
        row[0]
        for row in csv.reader(result.stdout.splitlines())
        if row and row[0].lower() in CODEX_PROCESS_NAMES
    )


def _assert_codex_quiescent() -> None:
    processes = _codex_processes()
    if processes:
        raise RuntimeError("Codex is running; close it before changing providers")


def _thread_columns(connection: sqlite3.Connection) -> set[str]:
    return {row[1] for row in connection.execute("PRAGMA table_info(threads)")}


def _validate_state_db_schema(state_db_path: Path | None) -> None:
    if not state_db_path or not state_db_path.exists():
        return
    with closing(sqlite3.connect(state_db_path, timeout=10)) as connection:
        if "model_provider" not in _thread_columns(connection):
            raise RuntimeError("The threads table has no model_provider column")


def switch_provider(
    provider: str,
    config_path: Path,
    state_db_path: Path | None,
    dry_run: bool = False,
) -> dict[str, object]:
    definition = _validate_provider(provider)
    config_path = Path(config_path)
    state_db_path = Path(state_db_path) if state_db_path else None
    if not config_path.exists():
        raise FileNotFoundError(f"Codex config not found: {config_path}")

    original = config_path.read_text(encoding="utf-8")
    rendered = render_config(original, provider)
    result: dict[str, object] = {
        "provider": provider,
        "display_name": definition["display_name"],
        "env_key": definition["env_key"],
        "config": config_path.name,
        "state_db": state_db_path.name if state_db_path else None,
        "dry_run": dry_run,
        "changed": rendered != original,
        "config_backup": None,
        "state_backup": None,
        "backup_manifest": None,
        "synced_threads": 0,
        "repaired_previews": 0,
        "verified_config": False,
        "verified_threads": None,
    }
    if dry_run:
        return result

    _validate_state_db_schema(state_db_path)
    _assert_codex_quiescent()
    config_dir = config_path.parent
    backup_dir = config_dir / "backups" / "windows-provider-switch"
    lock_dir = config_dir / ".windows-provider-switch.lock"
    lock_owner = _acquire_lock(lock_dir)
    try:
        preservation_before = _preservation_snapshot(config_dir, state_db_path)
        backup_dir.mkdir(parents=True, exist_ok=True)
        timestamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        config_backup = backup_dir / f"config-{timestamp}.toml"
        shutil.copy2(config_path, config_backup)
        result["config_backup"] = config_backup.name

        state_backup: Path | None = None
        if state_db_path and state_db_path.exists():
            state_backup = backup_dir / f"state-{timestamp}.sqlite"
            _backup_database(state_db_path, state_backup)
            result["state_backup"] = state_backup.name

        artifacts = [config_backup] + ([state_backup] if state_backup else [])
        manifest_path = backup_dir / f"manifest-{timestamp}.json"
        manifest_path.write_text(
            json.dumps({"files": {path.name: _sha256(path) for path in artifacts}}, sort_keys=True),
            encoding="utf-8",
        )
        result["backup_manifest"] = manifest_path.name

        state_connection: sqlite3.Connection | None = None
        temp_path: Path | None = None
        config_replaced = False
        try:
            if state_db_path and state_db_path.exists():
                state_connection = sqlite3.connect(state_db_path, timeout=10)
                state_connection.execute("BEGIN IMMEDIATE")
                columns = _thread_columns(state_connection)
                if "model_provider" not in columns:
                    raise RuntimeError("The threads table has no model_provider column")
                cursor = state_connection.execute(
                    "UPDATE threads SET model_provider = ? WHERE model_provider IS NULL OR model_provider <> ?",
                    (provider, provider),
                )
                result["synced_threads"] = cursor.rowcount
                if {"preview", "title"}.issubset(columns):
                    preview_cursor = state_connection.execute(
                        "UPDATE threads SET preview = title WHERE preview = '' AND title <> ''"
                    )
                    result["repaired_previews"] = preview_cursor.rowcount

            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                newline="",
                dir=config_dir,
                prefix=".config-provider-",
                suffix=".toml",
                delete=False,
            ) as handle:
                handle.write(rendered)
                temp_path = Path(handle.name)
            os.replace(temp_path, config_path)
            config_replaced = True
            verification_status = status(config_path, state_db_path)
            if verification_status["current_provider"] != provider:
                raise RuntimeError("Config verification failed after provider switch")
            _verify_preservation(
                preservation_before, _preservation_snapshot(config_dir, state_db_path)
            )
            result["verified_config"] = True
            if state_connection is not None:
                mismatched_threads = state_connection.execute(
                    "SELECT COUNT(*) FROM threads "
                    "WHERE model_provider IS NULL OR model_provider <> ?",
                    (provider,),
                ).fetchone()[0]
                if mismatched_threads:
                    raise RuntimeError(
                        f"Thread verification failed: {mismatched_threads} rows were not switched"
                    )
                result["verified_threads"] = True
                state_connection.commit()
        except Exception:
            if state_connection is not None:
                state_connection.rollback()
            if config_replaced:
                shutil.copy2(config_backup, config_path)
            elif temp_path and temp_path.exists():
                temp_path.unlink()
            raise
        finally:
            if state_connection is not None:
                state_connection.close()
        return result
    finally:
        _release_lock(lock_dir, lock_owner)


def restore_latest(config_path: Path, state_db_path: Path | None) -> dict[str, object]:
    config_path = Path(config_path)
    state_db_path = Path(state_db_path) if state_db_path else None
    backup_dir = config_path.parent / "backups" / "windows-provider-switch"
    backups = sorted(backup_dir.glob("config-*.toml"), reverse=True)
    if not backups:
        raise FileNotFoundError(f"No switcher backup found in {backup_dir}")

    config_backup = backups[0]
    timestamp = config_backup.stem.removeprefix("config-")
    state_backup = backup_dir / f"state-{timestamp}.sqlite"
    artifacts = [config_backup] + ([state_backup] if state_backup.exists() else [])
    _verify_backup_manifest(backup_dir / f"manifest-{timestamp}.json", artifacts)
    _assert_codex_quiescent()
    lock_dir = config_path.parent / ".windows-provider-switch.lock"
    lock_owner = _acquire_lock(lock_dir)
    try:
        pre_restore_stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        if config_path.exists():
            shutil.copy2(
                config_path, backup_dir / f"pre-restore-config-{pre_restore_stamp}.toml"
            )
        _restore_config(config_backup, config_path)
        if _sha256(config_path) != _sha256(config_backup):
            raise RuntimeError("Config restore verification failed")
        restored_state = False
        if state_db_path and state_backup.exists():
            if state_db_path.exists():
                _backup_database(
                    state_db_path,
                    backup_dir / f"pre-restore-state-{pre_restore_stamp}.sqlite",
                )
            with closing(sqlite3.connect(state_backup)) as source:
                with closing(sqlite3.connect(state_db_path)) as destination:
                    source.backup(destination)
            if _sqlite_content_hash(state_db_path) != _sqlite_content_hash(state_backup):
                raise RuntimeError("State database restore verification failed")
            restored_state = True
        return {
            "restored": True,
            "config_backup": config_backup.name,
            "state_backup": state_backup.name if restored_state else None,
        }
    finally:
        _release_lock(lock_dir, lock_owner)


def status(config_path: Path, state_db_path: Path | None) -> dict[str, object]:
    config_path = Path(config_path)
    state_db_path = Path(state_db_path) if state_db_path else None
    text = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
    root, blocks = _split_table_blocks(text)
    match = re.search(r"(?m)^\s*model_provider\s*=\s*['\"]([^'\"]+)['\"]", "".join(root))
    current = match.group(1) if match else None
    inline_token_detected = any(
        "experimental_bearer_token" in "".join(block)
        for name, block in blocks
        if name.startswith("model_providers.")
    )
    return {
        "config": config_path.name,
        "config_exists": config_path.exists(),
        "state_db": state_db_path.name if state_db_path else None,
        "state_db_exists": bool(state_db_path and state_db_path.exists()),
        "current_provider": current,
        "inline_token_detected": inline_token_detected,
        "providers": PROVIDERS,
    }


def _default_paths() -> tuple[Path, Path]:
    codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    return codex_home / "config.toml", codex_home / "state_5.sqlite"


def main() -> int:
    default_config, default_state = _default_paths()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=default_config)
    parser.add_argument("--state-db", type=Path, default=default_state)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("status")
    switch_parser = subparsers.add_parser("switch")
    switch_parser.add_argument("provider", choices=tuple(PROVIDERS))
    switch_parser.add_argument("--dry-run", action="store_true")
    subparsers.add_parser("restore")
    args = parser.parse_args()

    try:
        if args.command == "status":
            result = status(args.config, args.state_db)
        elif args.command == "switch":
            result = switch_provider(
                args.provider, args.config, args.state_db, dry_run=args.dry_run
            )
        else:
            result = restore_latest(args.config, args.state_db)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except Exception as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
