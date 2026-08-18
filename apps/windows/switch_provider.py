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
from typing import Callable
from profile_catalog import load_catalog


PROVIDERS = {
    "openai": {
        "display_name": "OpenAI",
        "env_key": None,
        "model": "gpt-5.6-sol",
        "reasoning_effort": "medium",
        "review_model": None,
    },
}

CODEX_PROCESS_NAMES = {"chatgpt.exe", "codex.exe", "codex-code-mode-host.exe"}
PhaseCallback = Callable[[str, str], None]


def _emit_phase(callback: PhaseCallback | None, phase: str, message: str) -> None:
    if callback is not None:
        callback(phase, message)


def _validate_provider(provider: str) -> dict[str, str | None]:
    if provider not in PROVIDERS:
        raise ValueError(f"Unsupported provider: {provider}")
    return PROVIDERS[provider]


def _newline_for(text: str) -> str:
    return "\r\n" if "\r\n" in text else "\n"


def _split_table_blocks(text: str) -> tuple[list[str], list[tuple[str, list[str]]]]:
    if text.startswith("\ufeff"):
        text = text[1:]
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


def _is_invalid_builtin_provider_override(name: str) -> bool:
    """Remove legacy config that makes current Codex reject config.toml outright."""

    return name == "model_providers.openai" or name.startswith("model_providers.openai.")


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
    blocks = [
        (name, block)
        for name, block in blocks
        if not _is_invalid_builtin_provider_override(name)
    ]

    root = _replace_root_key(root, "model", json.dumps(str(definition["model"])), newline)
    root = _replace_root_key(root, "model_provider", f'"{provider}"', newline)
    root = _replace_root_key(root, "model_catalog_json", None, newline)
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

    return "".join(rendered_parts).rstrip() + newline


def render_custom_profile_config(
    original: str,
    profile: dict[str, object],
    *,
    model_catalog_path: Path | None = None,
) -> tuple[str, str]:
    profile_id = uuid.UUID(str(profile["id"]))
    provider = f"custom_{profile_id.hex[:12]}"
    auth_mode = str(profile["authMode"])
    base_url = profile.get("baseUrl")
    wire_api = profile.get("wireApi")
    environment_key = profile.get("apiKeyEnv") if auth_mode == "api_key" else None
    model = str(profile.get("model") or "").strip()
    if not model and auth_mode == "api_key":
        raise ValueError("Custom Provider requires an explicit model; add one manually or fetch it from the upstream /models endpoint")
    if not model:
        model = "gpt-5.6-sol"
    reasoning_effort = profile.get("reasoningEffort")
    review_model = profile.get("reviewModel")
    newline = _newline_for(original)
    root, blocks = _split_table_blocks(original)
    blocks = [
        (name, block)
        for name, block in blocks
        if name != f"model_providers.{provider}"
        and not _is_invalid_builtin_provider_override(name)
    ]
    root = _replace_root_key(root, "model", json.dumps(model), newline)
    root = _replace_root_key(root, "model_provider", json.dumps(provider), newline)
    root = _replace_root_key(
        root,
        "model_catalog_json",
        json.dumps(str(Path(model_catalog_path).resolve())) if model_catalog_path else None,
        newline,
    )
    root = _replace_root_key(
        root, "model_reasoning_effort", json.dumps(str(reasoning_effort)) if reasoning_effort else None, newline
    )
    root = _replace_root_key(root, "review_model", json.dumps(str(review_model)) if review_model else None, newline)
    blocks = _set_table_key(blocks, "history", "persistence", '"save-all"', newline)
    while root and not root[-1].strip():
        root.pop()
    rendered = root[:]
    if rendered:
        rendered.append(newline)
    for _, block in blocks:
        rendered.extend(block)
        if rendered[-1].strip():
            rendered.append(newline)
    rendered.append(f"[model_providers.{provider}]{newline}")
    rendered.append(f"name = {json.dumps(str(profile['name']))}{newline}")
    if base_url:
        rendered.append(f"base_url = {json.dumps(str(base_url))}{newline}")
    if wire_api:
        rendered.append(f"wire_api = {json.dumps(str(wire_api))}{newline}")
    if environment_key:
        rendered.append(f"env_key = {json.dumps(str(environment_key))}{newline}")
    if auth_mode == "chatgpt_login":
        rendered.append(f"requires_openai_auth = true{newline}")
    return provider, "".join(rendered).rstrip() + newline


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


def _count_files(
    root: Path,
    *,
    name: str | None = None,
    suffix: str | None = None,
    excluded_top_level: frozenset[str] = frozenset(),
) -> int:
    if not root.is_dir():
        return 0
    return sum(
        1
        for path in root.rglob("*")
        if path.is_file()
        and path.relative_to(root).parts[0] not in excluded_top_level
        and (name is None or path.name.lower() == name.lower())
        and (suffix is None or path.suffix.lower() == suffix.lower())
    )


def _tree_stats(
    root: Path, *, excluded_top_level: frozenset[str] = frozenset()
) -> tuple[int, int]:
    """Fast preservation snapshot: file count plus total bytes.

    Hashing every session rollout (a real Codex home can hold multiple
    gigabytes) made switches hang for a minute; the count/size pair still
    detects truncated or missing files in seconds.
    """
    if not root.is_dir():
        return (0, 0)
    count = 0
    total = 0
    for path in root.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        if path.relative_to(root).parts[0] in excluded_top_level:
            continue
        count += 1
        try:
            total += path.stat().st_size
        except OSError:
            pass
    return (count, total)


def _mcp_server_count(config_text: str) -> int:
    return len(set(re.findall(r"(?m)^\s*\[mcp_servers\.([^\]]+)\]\s*$", config_text)))


def _toml_string_value(text: str, key: str) -> str | None:
    """Read one quoted TOML scalar without parsing or exposing secret values."""

    match = re.search(rf"(?m)^\s*{re.escape(key)}\s*=\s*['\"]([^'\"]+)['\"]", text)
    return match.group(1) if match else None


def _toml_boolean_value(text: str, key: str) -> bool | None:
    match = re.search(rf"(?mi)^\s*{re.escape(key)}\s*=\s*(true|false)\b", text)
    return match.group(1).casefold() == "true" if match else None


def _connection_details(
    root: list[str], blocks: list[tuple[str, list[str]]], current_provider: str | None
) -> dict[str, object]:
    """Return the active routing metadata only; credential values never leave TOML."""

    root_text = "".join(root)
    provider_text = ""
    if current_provider:
        provider_text = next(
            ("".join(block) for name, block in blocks if name == f"model_providers.{current_provider}"),
            "",
        )
    uses_openai_auth = _toml_boolean_value(provider_text, "requires_openai_auth")
    environment = _toml_string_value(provider_text, "env_key")
    if current_provider == "openai" or uses_openai_auth:
        authentication = "ChatGPT / Codex 登录"
    elif environment:
        authentication = "环境变量 API Key"
    else:
        authentication = "未识别"
    return {
        "model": _toml_string_value(root_text, "model"),
        "provider": current_provider,
        "base_url": _toml_string_value(provider_text, "base_url"),
        "wire_api": _toml_string_value(provider_text, "wire_api") or ("responses" if current_provider else None),
        "api_key_environment": environment,
        "requires_openai_auth": uses_openai_auth,
        "authentication": authentication,
    }


def _read_user_environment_value(name: str | None) -> str | None:
    if not name:
        return None
    value = os.environ.get(name)
    if isinstance(value, str) and value:
        return value
    if os.name != "nt":
        return None
    try:
        import winreg

        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            value, _kind = winreg.QueryValueEx(key, name)
        return value if isinstance(value, str) and value else None
    except (FileNotFoundError, OSError):
        return None


def _clear_user_environment_value(name: str | None) -> str | None:
    previous = _read_user_environment_value(name)
    if not name:
        return previous
    os.environ.pop(name, None)
    if os.name == "nt":
        try:
            import winreg

            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment", 0, winreg.KEY_SET_VALUE) as key:
                try:
                    winreg.DeleteValue(key, name)
                except FileNotFoundError:
                    pass
        except (FileNotFoundError, OSError):
            pass
    return previous


def _restore_user_environment_value(name: str | None, value: str | None) -> None:
    if not name or value is None:
        return
    os.environ[name] = value
    if os.name == "nt":
        try:
            import winreg

            with winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, "Environment", 0, winreg.KEY_SET_VALUE) as key:
                winreg.SetValueEx(key, name, 0, winreg.REG_SZ, value)
        except OSError:
            pass


def _activity_diagnostics(
    config_path: Path,
    state_db_path: Path | None,
    config_text: str,
    current_provider: str | None = None,
) -> dict[str, object]:
    history_error: str | None = None
    thread_count: int | None = None
    current_provider_thread_count: int | None = None
    other_provider_thread_count: int | None = None
    most_recent_thread_provider: str | None = None
    if not state_db_path or not state_db_path.exists():
        history_error = "state_db_missing"
    else:
        try:
            with closing(sqlite3.connect(f"file:{state_db_path}?mode=ro", uri=True)) as connection:
                thread_count = int(connection.execute("SELECT COUNT(*) FROM threads").fetchone()[0])
                columns = _thread_columns(connection)
                if "model_provider" not in columns:
                    history_error = "thread_routing_unavailable"
                else:
                    if current_provider is not None:
                        current_provider_thread_count = int(
                            connection.execute(
                                "SELECT COUNT(*) FROM threads WHERE model_provider = ?", (current_provider,)
                            ).fetchone()[0]
                        )
                        other_provider_thread_count = thread_count - current_provider_thread_count
                    recency_column = next(
                        (
                            column
                            for column in (
                                "recency_at_ms", "updated_at_ms", "recency_at", "updated_at", "created_at_ms", "created_at"
                            )
                            if column in columns
                        ),
                        None,
                    )
                    if recency_column:
                        recent = connection.execute(
                            f'SELECT model_provider FROM threads ORDER BY "{recency_column}" DESC LIMIT 1'
                        ).fetchone()
                        most_recent_thread_provider = recent[0] if recent else None
        except sqlite3.OperationalError as error:
            history_error = "threads_unavailable" if "threads" in str(error).lower() else "state_db_unreadable"
        except sqlite3.Error:
            history_error = "state_db_unreadable"

    config_dir = config_path.parent
    return {
        "thread_count": thread_count,
        "session_file_count": _count_files(config_dir / "sessions", suffix=".jsonl"),
        "skill_count": _count_files(config_dir / "skills", name="SKILL.md"),
        "plugin_count": _count_files(
            config_dir / "plugins", name="plugin.json", excluded_top_level=frozenset({"cache"})
        ),
        "mcp_server_count": _mcp_server_count(config_text),
        "mcp_file_count": _count_files(config_dir / "mcp", suffix=".json"),
        "current_provider_thread_count": current_provider_thread_count,
        "other_provider_thread_count": other_provider_thread_count,
        "most_recent_thread_provider": most_recent_thread_provider,
        "history_error": history_error,
    }


def _thread_routes(state_db_path: Path | None) -> dict[str, str | None]:
    if not state_db_path or not state_db_path.exists():
        return {}
    with closing(sqlite3.connect(f"file:{state_db_path}?mode=ro", uri=True)) as connection:
        if "model_provider" not in _thread_columns(connection):
            raise RuntimeError("The threads table has no model_provider column")
        return {
            str(thread_id): provider
            for thread_id, provider in connection.execute(
                "SELECT id, model_provider FROM threads ORDER BY id"
            )
        }


def _normalize_session_reasoning(config_dir: Path) -> int:
    """Normalize plaintext reasoning.content in rollout logs.

    Third-party /v1/responses sources can return reasoning items with
    plaintext content, which Codex stores verbatim. Strict Responses providers
    reject non-empty reasoning.content when history is replayed, so
    normalizing the stored items keeps existing conversations switchable
    between any user-configured Provider and the official OpenAI login without
    deleting any conversation content. Idempotent; malformed lines are kept.
    """
    sessions = config_dir / "sessions"
    if not sessions.is_dir():
        return 0
    normalized = 0
    for path in sorted(sessions.rglob("*.jsonl")):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        lines = text.splitlines(keepends=True)
        output: list[str] = []
        changed = False
        for line in lines:
            stripped = line.strip()
            if not stripped:
                output.append(line)
                continue
            try:
                obj = json.loads(stripped)
            except ValueError:
                output.append(line)
                continue
            payload = obj.get("payload") if isinstance(obj, dict) else None
            if (
                isinstance(payload, dict)
                and payload.get("type") == "reasoning"
                and payload.get("content") not in (None, [], "")
            ):
                payload["content"] = []
                payload["encrypted_content"] = None
                changed = True
                normalized += 1
                ending = "\r\n" if line.endswith("\r\n") else "\n"
                output.append(json.dumps(obj, ensure_ascii=False, sort_keys=True) + ending)
            else:
                output.append(line)
        if changed:
            try:
                with open(path, "w", encoding="utf-8", newline="") as handle:
                    handle.write("".join(output))
            except OSError:
                continue
    return normalized


def _session_provider_ids(config_dir: Path, state_db_path: Path | None) -> set[str]:
    """Collect historical provider IDs without modifying sessions or the database."""

    providers = set(_thread_routes(state_db_path).values()) if state_db_path and state_db_path.exists() else set()
    sessions = config_dir / "sessions"
    if not sessions.is_dir():
        return {value for value in providers if isinstance(value, str) and value}
    for path in sessions.rglob("*.jsonl"):
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            payload = obj.get("payload") if isinstance(obj, dict) else None
            if isinstance(payload, dict) and payload.get("type") == "session_meta":
                provider = payload.get("model_provider")
                if isinstance(provider, str) and provider.strip():
                    providers.add(provider.strip())
    return providers


def _add_historical_provider_aliases(
    rendered: str,
    target_provider: str,
    historical_ids: set[str],
) -> str:
    """Keep old session provider names resolvable while routing them to target."""

    aliases = {
        value for value in historical_ids
        if re.fullmatch(r"[A-Za-z0-9_-]+", value)
        and value not in {"openai", target_provider}
    }
    if not aliases:
        return rendered
    newline = _newline_for(rendered)
    root, blocks = _split_table_blocks(rendered)
    target_block = next(
        (block for name, block in blocks if name == f"model_providers.{target_provider}"),
        None,
    )
    if target_block is None:
        target_block = [
            f"[model_providers.{target_provider}]{newline}",
            'name = "OpenAI"' + newline,
            "requires_openai_auth = true" + newline,
        ]
    output = root[:]
    for name, block in blocks:
        if name not in {f"model_providers.{alias}" for alias in aliases}:
            output.extend(block)
    for alias in sorted(aliases):
        alias_block = list(target_block)
        alias_block[0] = f"[model_providers.{alias}]{newline}"
        output.extend(alias_block)
    return "".join(output).rstrip() + newline


def _preservation_snapshot(config_dir: Path, state_db_path: Path | None) -> dict[str, object]:
    return {
        "thread_routes": _thread_routes(state_db_path),
        "state_database": _sqlite_content_hash(state_db_path)
        if state_db_path and state_db_path.exists()
        else None,
        "sessions": _tree_stats(config_dir / "sessions"),
        "extensions": {
            "skills": _tree_stats(config_dir / "skills"),
            # Codex updates plugin runtime caches independently. They are never managed by a
            # provider switch, so backing them up or hashing them would create a race with Codex.
            "plugins": _tree_stats(config_dir / "plugins", excluded_top_level=frozenset({"cache"})),
            "mcp": _tree_stats(config_dir / "mcp"),
        },
    }


def _verify_preservation(before: dict[str, object], after: dict[str, object]) -> None:
    if before != after:
        raise RuntimeError("Conversation or extension preservation verification failed")


def _verify_backup_manifest(manifest_path: Path, backup_dir: Path) -> None:
    try:
        expected = json.loads(manifest_path.read_text(encoding="utf-8"))["files"]
    except (OSError, KeyError, json.JSONDecodeError) as error:
        raise RuntimeError("Backup manifest is missing or invalid") from error
    if not isinstance(expected, dict):
        raise RuntimeError("Backup manifest is missing or invalid")
    for relative_path, checksum in expected.items():
        artifact = backup_dir / relative_path
        if not artifact.is_file() or checksum != _sha256(artifact):
            raise RuntimeError(f"Backup verification failed: {relative_path}")


def _backup_artifacts(
    config_backup: Path,
    state_backup: Path | None,
) -> list[Path]:
    return [config_backup] + ([state_backup] if state_backup else [])


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


STALE_LOCK_AGE_SECONDS = 300.0


def _pid_is_alive(pid: object) -> bool:
    if not isinstance(pid, int) or pid <= 0:
        return False
    if os.name == "nt":
        # On Windows, ``os.kill(pid, 0)`` is not the harmless existence probe it is on
        # POSIX: CPython delegates non-console signals to TerminateProcess, so a lock
        # check can terminate the process it is checking. Query the process handle
        # instead and fail closed (alive) when access or the probe itself is uncertain.
        try:
            import ctypes
            from ctypes import wintypes

            process_query_limited_information = 0x1000
            still_active = 259
            kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
            kernel32.OpenProcess.restype = wintypes.HANDLE
            kernel32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
            kernel32.GetExitCodeProcess.restype = wintypes.BOOL
            kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
            kernel32.CloseHandle.restype = wintypes.BOOL

            handle = kernel32.OpenProcess(process_query_limited_information, False, pid)
            if not handle:
                return ctypes.get_last_error() == 5  # ERROR_ACCESS_DENIED means it exists.
            try:
                exit_code = wintypes.DWORD()
                if not kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code)):
                    return True
                return exit_code.value == still_active
            finally:
                kernel32.CloseHandle(handle)
        except (AttributeError, ImportError, OSError, ValueError):
            return True
    try:
        os.kill(pid, 0)
    except PermissionError:
        return True
    except (OSError, ValueError, TypeError):
        return False
    return True


def _reclaim_stale_lock(lock_dir: Path, stale_after_seconds: float) -> bool:
    """Reclaim only locks whose owner is dead, or owner-less locks older than the threshold."""

    owner = None
    try:
        owner_text = (lock_dir / "owner.json").read_text(encoding="utf-8")
        owner = json.loads(owner_text)
        if not isinstance(owner, dict):
            owner = None
    except (OSError, json.JSONDecodeError):
        owner = None
    if owner is not None and _pid_is_alive(owner.get("pid")):
        return False
    if owner is None:
        try:
            age = time.time() - lock_dir.stat().st_mtime
        except OSError:
            return False
        if age < stale_after_seconds:
            return False
    quarantine = lock_dir.with_name(f"{lock_dir.name}.stale-{uuid.uuid4().hex}")
    try:
        os.replace(lock_dir, quarantine)
    except OSError:
        return False
    shutil.rmtree(quarantine, ignore_errors=True)
    return True


def _acquire_lock(lock_dir: Path, timeout_seconds: float = 10.0, *, stale_after_seconds: float = STALE_LOCK_AGE_SECONDS) -> str:
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
            if _reclaim_stale_lock(lock_dir, stale_after_seconds):
                continue
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


_BACKUP_FILE_PREFIXES = (
    "config-",
    "state-",
    "manifest-",
    "pre-restore-config-",
    "pre-restore-state-",
)


def _prune_backups(
    backup_dir: Path,
    *,
    max_count: int = 5,
    max_bytes: int = 20 * 1024**3,
    max_age_days: int = 14,
) -> int:
    """Governed retention for `backups/windows-provider-switch`.

    Backups are grouped by their timestamp prefix. A group is removed when it
    is the oldest and (a) it is older than `max_age_days`, or (b) more than
    `max_count` groups remain, or (c) the surviving groups still exceed
    `max_bytes`. Returns the number of removed groups.
    """
    if not backup_dir.is_dir():
        return 0
    groups: dict[str, list[Path]] = {}
    for path in backup_dir.iterdir():
        if not path.is_file():
            continue
        stem = path.stem
        for prefix in _BACKUP_FILE_PREFIXES:
            if stem.startswith(prefix):
                groups.setdefault(stem[len(prefix):], []).append(path)
                break
    if not groups:
        return 0
    ordered = sorted(groups.items(), key=lambda item: item[0])

    def group_mtime(stamp: str, files: list[Path]) -> float:
        try:
            return dt.datetime.strptime(stamp, "%Y%m%d-%H%M%S-%f").timestamp()
        except ValueError:
            return max((f.stat().st_mtime for f in files), default=time.time())

    cutoff = time.time() - max_age_days * 86_400
    survivors: list[tuple[str, list[Path]]] = []
    removed = 0
    for stamp, files in ordered:
        if group_mtime(stamp, files) < cutoff:
            for path in files:
                path.unlink(missing_ok=True)
            removed += 1
            continue
        survivors.append((stamp, files))

    while True:
        total = sum(path.stat().st_size for _, files in survivors for path in files)
        if len(survivors) <= max_count and total <= max_bytes:
            break
        if not survivors:
            break
        _, files = survivors.pop(0)
        for path in files:
            path.unlink(missing_ok=True)
        removed += 1
    return removed


def list_backups(backup_dir: Path) -> list[dict[str, object]]:
    """Lists switch backup groups newest-first for the management UI."""
    if not backup_dir.is_dir():
        return []
    groups: dict[str, list[Path]] = {}
    for path in backup_dir.iterdir():
        if not path.is_file():
            continue
        stem = path.stem
        for prefix in _BACKUP_FILE_PREFIXES:
            if stem.startswith(prefix):
                groups.setdefault(stem[len(prefix):], []).append(path)
                break
    result: list[dict[str, object]] = []
    for stamp, files in groups.items():
        try:
            created = dt.datetime.strptime(stamp, "%Y%m%d-%H%M%S-%f")
        except ValueError:
            created = None
        result.append(
            {
                "timestamp": stamp,
                "created": created.isoformat() if created else None,
                "bytes": sum(path.stat().st_size for path in files),
                "files": sorted(path.name for path in files),
            }
        )
    result.sort(key=lambda item: str(item["timestamp"]), reverse=True)
    return result


def _log_phase(config_dir: Path, message: str) -> None:
    """Appends one timestamped line to `state/switch.log` under the managed
    Codex home so a failed real-machine switch can be diagnosed from the log
    instead of requiring a live reproduction (same contract as macOS)."""
    log_path = config_dir / "state" / "switch.log"
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        line = f"[{dt.datetime.now(dt.timezone.utc).isoformat()}] {message}\n"
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(line)
    except OSError:
        pass


class _CodexProcessProbeError(RuntimeError):
    """Raised only when one local Windows process probe cannot run."""


class CodexProcessProbeError(RuntimeError):
    """The switcher could not safely determine whether Codex has stopped."""


class CodexRunningError(RuntimeError):
    """Codex still owns the local working files needed by a switch."""


def _codex_processes_from_toolhelp() -> tuple[str, ...]:
    """Read the Windows process snapshot without relying on PATH or a shell."""

    if os.name != "nt":
        return ()
    try:
        import ctypes
        from ctypes import wintypes

        class ProcessEntry32W(ctypes.Structure):
            _fields_ = [
                ("dwSize", wintypes.DWORD),
                ("cntUsage", wintypes.DWORD),
                ("th32ProcessID", wintypes.DWORD),
                ("th32DefaultHeapID", ctypes.c_size_t),
                ("th32ModuleID", wintypes.DWORD),
                ("cntThreads", wintypes.DWORD),
                ("th32ParentProcessID", wintypes.DWORD),
                ("pcPriClassBase", wintypes.LONG),
                ("dwFlags", wintypes.DWORD),
                ("szExeFile", wintypes.WCHAR * 260),
            ]

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
        kernel32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
        kernel32.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessEntry32W)]
        kernel32.Process32FirstW.restype = wintypes.BOOL
        kernel32.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessEntry32W)]
        kernel32.Process32NextW.restype = wintypes.BOOL
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel32.CloseHandle.restype = wintypes.BOOL
        snapshot = kernel32.CreateToolhelp32Snapshot(0x00000002, 0)
        invalid_handle = ctypes.c_void_p(-1).value
        if not snapshot or snapshot == invalid_handle:
            raise OSError(ctypes.get_last_error(), "CreateToolhelp32Snapshot failed")
        try:
            entry = ProcessEntry32W()
            entry.dwSize = ctypes.sizeof(entry)
            if not kernel32.Process32FirstW(snapshot, ctypes.byref(entry)):
                raise OSError(ctypes.get_last_error(), "Process32FirstW failed")
            matches: list[str] = []
            while True:
                if entry.szExeFile.lower() in CODEX_PROCESS_NAMES:
                    matches.append(entry.szExeFile)
                entry.dwSize = ctypes.sizeof(entry)
                if not kernel32.Process32NextW(snapshot, ctypes.byref(entry)):
                    error_code = ctypes.get_last_error()
                    if error_code not in {0, 18}:  # ERROR_NO_MORE_FILES
                        raise OSError(error_code, "Process32NextW failed")
                    break
            return tuple(matches)
        finally:
            kernel32.CloseHandle(snapshot)
    except (AttributeError, ImportError, OSError, ValueError) as error:
        raise _CodexProcessProbeError("Toolhelp process snapshot is unavailable") from error


def _codex_processes_from_tasklist() -> tuple[str, ...]:
    """Fallback probe for Windows hosts where the native snapshot API fails."""

    if os.name != "nt":
        return ()
    system_root = os.environ.get("SystemRoot") or os.environ.get("WINDIR")
    tasklist = str(Path(system_root) / "System32" / "tasklist.exe") if system_root else "tasklist"
    try:
        result = subprocess.run(
            [tasklist, "/FO", "CSV", "/NH"],
            capture_output=True,
            check=True,
            text=True,
            errors="replace",
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError, UnicodeError, ValueError) as error:
        raise _CodexProcessProbeError("tasklist process probe is unavailable") from error
    return tuple(
        row[0]
        for row in csv.reader(result.stdout.splitlines())
        if row and row[0].lower() in CODEX_PROCESS_NAMES
    )


def _codex_processes() -> tuple[str, ...]:
    """Return running Codex process images, or fail closed when both probes fail."""

    if os.name != "nt":
        return ()
    failures: list[_CodexProcessProbeError] = []
    for probe in (_codex_processes_from_toolhelp, _codex_processes_from_tasklist):
        try:
            return probe()
        except _CodexProcessProbeError as error:
            failures.append(error)
    raise CodexProcessProbeError(
        "无法确认 Codex 是否已经关闭。请关闭 Codex 后重试；若仍失败，请以当前登录的 Windows 用户重新启动此程序。"
    ) from failures[-1]


def _assert_codex_quiescent() -> None:
    processes = _codex_processes()
    if processes:
        raise CodexRunningError(
            "Codex 正在运行。请先完成正在进行的会话并关闭 Codex，再切换 Provider。"
        )


def _codex_process_ids_from_toolhelp() -> tuple[int, ...]:
    """Return Codex process IDs for a graceful window-close request on Windows."""

    if os.name != "nt":
        return ()
    try:
        import ctypes
        from ctypes import wintypes

        class ProcessEntry32W(ctypes.Structure):
            _fields_ = [
                ("dwSize", wintypes.DWORD),
                ("cntUsage", wintypes.DWORD),
                ("th32ProcessID", wintypes.DWORD),
                ("th32DefaultHeapID", ctypes.c_size_t),
                ("th32ModuleID", wintypes.DWORD),
                ("cntThreads", wintypes.DWORD),
                ("th32ParentProcessID", wintypes.DWORD),
                ("pcPriClassBase", wintypes.LONG),
                ("dwFlags", wintypes.DWORD),
                ("szExeFile", wintypes.WCHAR * 260),
            ]

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
        kernel32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
        kernel32.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessEntry32W)]
        kernel32.Process32FirstW.restype = wintypes.BOOL
        kernel32.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessEntry32W)]
        kernel32.Process32NextW.restype = wintypes.BOOL
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel32.CloseHandle.restype = wintypes.BOOL
        snapshot = kernel32.CreateToolhelp32Snapshot(0x00000002, 0)
        invalid_handle = ctypes.c_void_p(-1).value
        if not snapshot or snapshot == invalid_handle:
            raise OSError(ctypes.get_last_error(), "CreateToolhelp32Snapshot failed")
        try:
            entry = ProcessEntry32W()
            entry.dwSize = ctypes.sizeof(entry)
            if not kernel32.Process32FirstW(snapshot, ctypes.byref(entry)):
                raise OSError(ctypes.get_last_error(), "Process32FirstW failed")
            matches: list[int] = []
            while True:
                if entry.szExeFile.lower() in CODEX_PROCESS_NAMES:
                    matches.append(int(entry.th32ProcessID))
                entry.dwSize = ctypes.sizeof(entry)
                if not kernel32.Process32NextW(snapshot, ctypes.byref(entry)):
                    error_code = ctypes.get_last_error()
                    if error_code not in {0, 18}:  # ERROR_NO_MORE_FILES
                        raise OSError(error_code, "Process32NextW failed")
                    break
            return tuple(matches)
        finally:
            kernel32.CloseHandle(snapshot)
    except (AttributeError, ImportError, OSError, ValueError) as error:
        raise _CodexProcessProbeError("Toolhelp process snapshot is unavailable") from error


def _post_close_to_codex_windows(process_ids: tuple[int, ...]) -> int:
    """Ask visible Codex windows to close without terminating their processes."""

    if os.name != "nt" or not process_ids:
        return 0
    try:
        import ctypes
        from ctypes import wintypes

        user32 = ctypes.WinDLL("user32", use_last_error=True)
        callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
        enum_windows = user32.EnumWindows
        enum_windows.argtypes = [callback_type, wintypes.LPARAM]
        enum_windows.restype = wintypes.BOOL
        user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
        user32.GetWindowThreadProcessId.restype = wintypes.DWORD
        user32.IsWindowVisible.argtypes = [wintypes.HWND]
        user32.IsWindowVisible.restype = wintypes.BOOL
        user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
        user32.PostMessageW.restype = wintypes.BOOL
        target_ids = set(process_ids)
        requested = 0

        @callback_type
        def close_window(window: int, _lparam: int) -> bool:
            nonlocal requested
            process_id = wintypes.DWORD()
            user32.GetWindowThreadProcessId(window, ctypes.byref(process_id))
            if int(process_id.value) in target_ids and user32.IsWindowVisible(window):
                if user32.PostMessageW(window, 0x0010, 0, 0):  # WM_CLOSE
                    requested += 1
            return True

        if not enum_windows(close_window, 0):
            raise OSError(ctypes.get_last_error(), "EnumWindows failed")
        return requested
    except (AttributeError, OSError, ValueError) as error:
        raise CodexProcessProbeError("无法向 Codex 发送正常关闭请求。请手动关闭 Codex 后重试。") from error


def request_codex_graceful_shutdown(wait_seconds: float = 8.0, *, tick: object | None = None) -> dict[str, object]:
    """Request a normal Codex window close, then fail closed until it has exited.

    This deliberately never uses ``taskkill`` or another force-termination path:
    a running Codex process may still be writing sessions or the history database.
    """

    processes = _codex_processes()
    if not processes:
        return {"requested": False, "closed": True, "windows": 0}
    try:
        process_ids = _codex_process_ids_from_toolhelp()
    except _CodexProcessProbeError as error:
        raise CodexProcessProbeError("无法定位正在运行的 Codex 窗口。请手动关闭 Codex 后重试。") from error
    if not process_ids:
        raise CodexRunningError("Codex 正在运行，但没有可正常关闭的窗口；请手动关闭 Codex 后重试。")
    windows = _post_close_to_codex_windows(process_ids)
    deadline = time.monotonic() + max(0.0, wait_seconds)
    started = time.monotonic()
    while True:
        if not _codex_processes():
            return {"requested": True, "closed": True, "windows": windows}
        if time.monotonic() >= deadline:
            break
        if tick is not None:
            tick(time.monotonic() - started)
        time.sleep(0.2)
    raise CodexRunningError("Codex 未能在等待时间内正常关闭；为保护会话与配置，未执行切换。")


def stop_codex_process_tree(*, tick: object | None = None) -> dict[str, object]:
    """Close every Codex process tree before changing the shared home."""

    if os.name != "nt":
        _assert_codex_quiescent()
        return {"requested": False, "terminated": False, "remaining": 0}
    processes = _codex_processes()
    if not processes:
        return {"requested": False, "terminated": False, "remaining": 0}
    try:
        process_ids = _codex_process_ids_from_toolhelp()
    except _CodexProcessProbeError as error:
        raise CodexProcessProbeError("无法定位 Codex 进程。请关闭 Codex 后重试。") from error
    if not process_ids:
        raise CodexRunningError("发现 Codex 正在运行，但无法取得进程编号。请关闭 Codex 后重试。")
    system_root = os.environ.get("SystemRoot") or os.environ.get("WINDIR")
    taskkill = str(Path(system_root) / "System32" / "taskkill.exe") if system_root else "taskkill.exe"
    for process_id in process_ids:
        subprocess.run(
            [taskkill, "/PID", str(process_id), "/T", "/F"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    deadline = time.monotonic() + 15.0
    started = time.monotonic()
    while True:
        remaining = _codex_processes()
        if not remaining:
            return {"requested": True, "terminated": True, "remaining": 0}
        if time.monotonic() >= deadline:
            raise CodexRunningError("无法关闭全部 Codex 进程；为保护会话与设置，切换已停止。")
        if tick is not None:
            tick(time.monotonic() - started)
        time.sleep(0.2)


def _installed_codex_executable() -> Path | None:
    """Resolve the installed AppX executable without routing through Explorer."""

    if os.name != "nt":
        return None
    for alias in ("Codex.exe", "ChatGPT.exe", "codex.exe", "chatgpt.exe"):
        resolved = shutil.which(alias)
        if resolved:
            return Path(resolved)
    command = (
        "$package = Get-AppxPackage | Where-Object { "
        "$_.Name -like 'OpenAI.Codex*' -or $_.Name -like 'OpenAI.ChatGPT*' -or "
        "$_.PackageFamilyName -like 'OpenAI.Codex*' -or $_.PackageFamilyName -like 'OpenAI.ChatGPT*' } | "
        "Sort-Object Version -Descending | Select-Object -First 1; "
        "if ($package) { $package.InstallLocation }"
    )
    try:
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise RuntimeError("无法定位已安装的 Codex 应用。") from error
    locations = [Path(line.strip()) for line in result.stdout.splitlines() if line.strip()]
    for root in locations:
        if not root.is_dir():
            continue
        manifest = root / "AppxManifest.xml"
        try:
            if manifest.is_file():
                import xml.etree.ElementTree as element_tree

                document = element_tree.parse(manifest)
                for application in document.getroot().iter():
                    executable = application.attrib.get("Executable")
                    if executable:
                        candidate = root / executable
                        if candidate.is_file():
                            return candidate
            for executable_name in ("Codex.exe", "ChatGPT.exe"):
                candidates = sorted(root.rglob(executable_name))
                if candidates:
                    return candidates[0]
        except (OSError, element_tree.ParseError):
            continue
    return None


def _launch_environment(target_env_key: str | None, previous_env_key: str | None) -> dict[str, str]:
    environment = dict(os.environ)
    if previous_env_key and previous_env_key != target_env_key:
        environment.pop(previous_env_key, None)
    if target_env_key:
        value = _read_user_environment_value(target_env_key)
        if value is None:
            raise RuntimeError("当前服务的访问密钥未找到，无法启动 Codex。")
        environment[target_env_key] = value
    return environment


def launch_codex_desktop(
    *,
    target_env_key: str | None = None,
    previous_env_key: str | None = None,
    tick: object | None = None,
) -> dict[str, object]:
    """Launch Codex with a fresh, provider-specific process environment."""

    if os.name != "nt":
        return {"requested": False, "verified": True}
    executable = _installed_codex_executable()
    if executable is None:
        raise RuntimeError("没有找到已安装的 Codex 应用，切换未标记为成功。")
    try:
        subprocess.Popen(
            [str(executable)],
            cwd=str(executable.parent),
            env=_launch_environment(target_env_key, previous_env_key),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise RuntimeError("无法启动 Codex 桌面应用。") from error
    deadline = time.monotonic() + 20.0
    started = time.monotonic()
    while True:
        if _codex_processes():
            return {
                "requested": True,
                "verified": True,
                "environment_verified": True,
                "executable": executable.name,
            }
        if time.monotonic() >= deadline:
            raise RuntimeError("Codex 启动请求已发送，但未检测到 Codex 进程。")
        if tick is not None:
            tick(time.monotonic() - started)
        time.sleep(0.25)


def _thread_columns(connection: sqlite3.Connection) -> set[str]:
    return {row[1] for row in connection.execute("PRAGMA table_info(threads)")}


def _validate_state_db_schema(state_db_path: Path | None) -> None:
    if not state_db_path or not state_db_path.exists():
        return
    with closing(sqlite3.connect(state_db_path, timeout=10)) as connection:
        if "model_provider" not in _thread_columns(connection):
            raise RuntimeError("The threads table has no model_provider column")


def _read_thread_routing(state_db_path: Path | None, provider: str) -> dict[str, object]:
    """Read-only thread routing counts; never mutates the history database."""

    if not state_db_path or not state_db_path.exists():
        return {"verified": None, "total": None, "provider_count": None, "other_count": None}
    try:
        with closing(sqlite3.connect(f"file:{state_db_path}?mode=ro", uri=True)) as connection:
            if "model_provider" not in _thread_columns(connection):
                return {"verified": False, "total": None, "provider_count": None, "other_count": None}
            total = int(connection.execute("SELECT COUNT(*) FROM threads").fetchone()[0])
            provider_count = int(
                connection.execute(
                    "SELECT COUNT(*) FROM threads WHERE model_provider = ?", (provider,)
                ).fetchone()[0]
            )
        return {
            "verified": True,
            "total": total,
            "provider_count": provider_count,
            "other_count": total - provider_count,
        }
    except (sqlite3.Error, OSError):
        return {"verified": False, "total": None, "provider_count": None, "other_count": None}


def switch_provider(
    provider: str,
    config_path: Path,
    state_db_path: Path | None,
    dry_run: bool = False,
    rendered_config: str | None = None,
    *,
    previous_env_key: str | None = None,
    target_env_key: str | None = None,
    target_base_url: str | None = None,
    target_wire_api: str | None = None,
    phase_callback: PhaseCallback | None = None,
) -> dict[str, object]:
    definition = _validate_provider(provider)
    config_path = Path(config_path)
    state_db_path = Path(state_db_path) if state_db_path else None
    if not config_path.exists():
        raise FileNotFoundError(f"Codex config not found: {config_path.name}")

    original = config_path.read_text(encoding="utf-8")
    rendered = rendered_config if rendered_config is not None else render_config(original, provider)
    original_root, original_blocks = _split_table_blocks(original)
    original_provider = _toml_string_value("".join(original_root), "model_provider")
    original_connection = _connection_details(original_root, original_blocks, original_provider)
    previous_env_key = previous_env_key or (
        str(original_connection["api_key_environment"])
        if original_connection.get("api_key_environment")
        else None
    )
    target_env_key = target_env_key or (str(PROVIDERS[provider]["env_key"]) if PROVIDERS[provider].get("env_key") else None)
    previous_env_value = _read_user_environment_value(previous_env_key) if previous_env_key != target_env_key else None
    runtime_stopped = False
    runtime_launched = False
    old_key_cleared = False
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
        "preserved_backup": None,
        "synced_threads": 0,
        "repaired_previews": 0,
        "normalized_session_items": 0,
        "verified_config": False,
        "verified_threads": None,
        "thread_routing": None,
        "connection": None,
        "verified_provider": False,
        "old_api_key_cleared": False,
        "runtime_stopped": False,
        "runtime_launched": False,
        "preflight_verified": False,
        "environment_injection_verified": False,
    }
    if dry_run:
        return result

    _validate_state_db_schema(state_db_path)
    _emit_phase(phase_callback, "stopping", "正在关闭 Codex 及其全部进程…")
    stop_result = stop_codex_process_tree(tick=lambda elapsed: _emit_phase(phase_callback, "stopping", f"正在关闭 Codex（已等待 {int(elapsed)} 秒）…"))
    runtime_stopped = bool(stop_result.get("requested"))
    result["runtime_stopped"] = runtime_stopped
    config_dir = config_path.parent
    historical_provider_ids = _session_provider_ids(config_dir, state_db_path)
    rendered = _add_historical_provider_aliases(rendered, provider, historical_provider_ids)
    result["changed"] = rendered != original
    backup_dir = config_dir / "backups" / "windows-provider-switch"
    lock_dir = config_dir / ".windows-provider-switch.lock"
    lock_owner = _acquire_lock(lock_dir)
    try:
        _log_phase(config_dir, f"switch start: target={provider} display={definition['display_name']}")
        if historical_provider_ids:
            _log_phase(config_dir, f"historical provider aliases preserved: {len(historical_provider_ids)}")
        _emit_phase(phase_callback, "normalizing", "正在整理会话兼容性数据…")
        # Normalize reasoning content before snapshotting so preservation
        # verification sees the repaired session state as the baseline.
        result["normalized_session_items"] = _normalize_session_reasoning(config_dir)
        _log_phase(config_dir, f"normalized {result['normalized_session_items']} reasoning entries")
        preservation_before = _preservation_snapshot(config_dir, state_db_path)
        _emit_phase(phase_callback, "backing_up", "正在备份设置、会话和恢复信息…")
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

        artifacts = _backup_artifacts(config_backup, state_backup)
        manifest_path = backup_dir / f"manifest-{timestamp}.json"
        manifest_path.write_text(
            json.dumps(
                {
                    "files": {
                        path.relative_to(backup_dir).as_posix(): _sha256(path)
                        for path in artifacts
                    }
                },
                sort_keys=True,
            ),
            encoding="utf-8",
        )
        result["backup_manifest"] = manifest_path.name
        _log_phase(config_dir, f"backup created: {manifest_path.name}")

        temp_path: Path | None = None
        config_replaced = False
        try:
            _emit_phase(phase_callback, "applying", "正在应用新的服务设置…")
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
            _emit_phase(phase_callback, "verifying", "正在验证当前服务和访问凭据…")
            connection = verification_status.get("connection", {})
            if not isinstance(connection, dict):
                raise RuntimeError("无法读取当前服务设置，切换已回滚。")
            if target_env_key and connection.get("api_key_environment") != target_env_key:
                raise RuntimeError("目标访问密钥变量未注入当前服务设置，切换已回滚。")
            if target_base_url and connection.get("base_url") != target_base_url:
                raise RuntimeError("目标服务地址未注入当前服务设置，切换已回滚。")
            if target_wire_api and connection.get("wire_api") != target_wire_api:
                raise RuntimeError("目标接口方式未注入当前服务设置，切换已回滚。")
            if os.name == "nt" and target_env_key and _read_user_environment_value(target_env_key) is None:
                raise RuntimeError("当前服务的访问密钥未找到，切换已回滚。")
            result["verified_provider"] = True
            if previous_env_key and previous_env_key != target_env_key:
                _clear_user_environment_value(previous_env_key)
                old_key_cleared = True
                result["old_api_key_cleared"] = True
            _verify_preservation(
                preservation_before, _preservation_snapshot(config_dir, state_db_path)
            )
            result["verified_config"] = True
            thread_routing = _read_thread_routing(state_db_path, provider)
            result["verified_threads"] = thread_routing["verified"]
            result["thread_routing"] = thread_routing
            result["connection"] = verification_status["connection"]
            _emit_phase(phase_callback, "launching", "正在重新启动 Codex…")
            launch_result = launch_codex_desktop(
                target_env_key=target_env_key,
                previous_env_key=previous_env_key,
                tick=lambda elapsed: _emit_phase(phase_callback, "launching", f"正在启动 Codex（已等待 {int(elapsed)} 秒）…")
            )
            runtime_launched = bool(launch_result.get("requested"))
            result["runtime_launched"] = runtime_launched
            result["environment_injection_verified"] = bool(launch_result.get("environment_verified", True))
            _log_phase(config_dir, f"switch complete: target={provider}")
            _emit_phase(phase_callback, "complete", "服务已切换，Codex 已重新启动并完成验证。")
            pruned = _prune_backups(backup_dir)
            if pruned:
                _log_phase(config_dir, f"pruned {pruned} old backup groups")
        except Exception:
            if config_replaced:
                _restore_config(config_backup, config_path)
            elif temp_path and temp_path.exists():
                temp_path.unlink()
            _verify_preservation(
                preservation_before, _preservation_snapshot(config_dir, state_db_path)
            )
            if old_key_cleared:
                _restore_user_environment_value(previous_env_key, previous_env_value)
            if runtime_stopped and not runtime_launched:
                try:
                    launch_codex_desktop(target_env_key=previous_env_key)
                except Exception:
                    pass
            _log_phase(config_dir, f"switch failed: target={provider} (rolled back)")
            raise
        return result
    finally:
        _release_lock(lock_dir, lock_owner)


def switch_custom_profile(
    profile: dict[str, object],
    config_path: Path,
    state_db_path: Path | None,
    dry_run: bool = False,
    *,
    model_catalog_path: Path | None = None,
    phase_callback: PhaseCallback | None = None,
) -> dict[str, object]:
    if not profile.get("enabled", False):
        raise ValueError("Custom Provider profile is disabled")
    provider, rendered = render_custom_profile_config(
        Path(config_path).read_text(encoding="utf-8"),
        profile,
        model_catalog_path=model_catalog_path,
    )
    PROVIDERS[provider] = {
        "display_name": str(profile["name"]),
        "env_key": str(profile["apiKeyEnv"]) if profile["authMode"] == "api_key" else None,
        "model": str(profile["model"]),
        "reasoning_effort": str(profile.get("reasoningEffort") or "medium"),
        "review_model": str(profile["reviewModel"]) if profile.get("reviewModel") else None,
    }
    return switch_provider(
        provider,
        config_path,
        state_db_path,
        dry_run,
        rendered,
        target_env_key=str(profile["apiKeyEnv"]) if profile["authMode"] == "api_key" else None,
        target_base_url=str(profile["baseUrl"]) if profile.get("baseUrl") else None,
        target_wire_api=str(profile["wireApi"]) if profile.get("wireApi") else None,
        phase_callback=phase_callback,
    )


def restore_latest(config_path: Path, state_db_path: Path | None) -> dict[str, object]:
    config_path = Path(config_path)
    state_db_path = Path(state_db_path) if state_db_path else None
    backup_dir = config_path.parent / "backups" / "windows-provider-switch"
    backups = sorted(backup_dir.glob("config-*.toml"), reverse=True)
    if not backups:
        raise FileNotFoundError(f"No switcher backup found in backups/{backup_dir.name}")

    config_backup = backups[0]
    timestamp = config_backup.stem.removeprefix("config-")
    state_backup = backup_dir / f"state-{timestamp}.sqlite"
    _verify_backup_manifest(backup_dir / f"manifest-{timestamp}.json", backup_dir)
    _assert_codex_quiescent()
    lock_dir = config_path.parent / ".windows-provider-switch.lock"
    lock_owner = _acquire_lock(lock_dir)
    try:
        _log_phase(config_path.parent, f"restore start: backup={timestamp}")
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
        _prune_backups(backup_dir)
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
    if text.startswith("\ufeff"):
        text = text[1:]
    root, blocks = _split_table_blocks(text)
    match = re.search(r"(?m)^\s*model_provider\s*=\s*['\"]([^'\"]+)['\"]", "".join(root))
    current = match.group(1) if match else None
    connection = _connection_details(root, blocks, current)
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
        "connection": connection,
        "diagnostics": _activity_diagnostics(config_path, state_db_path, text, current),
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
    switch_parser.add_argument("provider", nargs="?")
    switch_parser.add_argument("--catalog", type=Path)
    switch_parser.add_argument("--profile-id")
    switch_parser.add_argument("--dry-run", action="store_true")
    subparsers.add_parser("restore")
    args = parser.parse_args()

    try:
        if args.command == "status":
            result = status(args.config, args.state_db)
        elif args.command == "switch":
            if args.catalog and args.profile_id:
                profile = next(
                    (item for item in load_catalog(args.catalog)["profiles"] if item["id"] == args.profile_id),
                    None,
                )
                if profile is None: raise ValueError("Custom Provider profile was not found")
                result = switch_custom_profile(profile, args.config, args.state_db, dry_run=args.dry_run)
            else:
                if args.provider not in PROVIDERS: raise ValueError("A built-in provider or catalog profile is required")
                result = switch_provider(args.provider, args.config, args.state_db, dry_run=args.dry_run)
        else:
            result = restore_latest(args.config, args.state_db)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except Exception as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
