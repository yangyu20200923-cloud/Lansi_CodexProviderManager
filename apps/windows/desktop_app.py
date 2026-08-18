#!/usr/bin/env python3
"""Native Windows desktop UI for Lansi Codex Provider Manager.

The application is deliberately standard-library-only.  It keeps profile
catalogue, credential, switching, and recovery work in local Python code and
does not start a browser, HTTP listener, or local web server.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
from pathlib import Path
import queue
import secrets
import sys
import threading
import uuid

try:
    from profile_catalog import (
        MAX_MANAGED_MODELS,
        ProfileCatalogError,
        build_managed_model_catalog,
        codex_reasoning_efforts,
        fetch_models,
        load_catalog,
        save_catalog,
        save_codex_model_catalog,
    )
    from switch_provider import (
        CodexRunningError,
        _prune_backups,
        list_backups,
        request_codex_graceful_shutdown,
        restore_latest,
        status,
        switch_custom_profile,
        switch_provider,
    )
except ModuleNotFoundError:  # Supports package-style imports in tests.
    from .profile_catalog import (
        MAX_MANAGED_MODELS,
        ProfileCatalogError,
        build_managed_model_catalog,
        codex_reasoning_efforts,
        fetch_models,
        load_catalog,
        save_catalog,
        save_codex_model_catalog,
    )
    from .switch_provider import (
        CodexRunningError,
        _prune_backups,
        list_backups,
        request_codex_graceful_shutdown,
        restore_latest,
        status,
        switch_custom_profile,
        switch_provider,
    )


_ALLOWED_PROFILE_FIELDS = {
    "id", "name", "enabled", "authMode", "baseUrl", "wireApi", "apiKeyEnv", "model", "models",
    "reasoningEffort", "reviewModel", "configOverrides",
}
_MAX_API_KEY_LENGTH = 16 * 1024
_BUILTIN_OPENAI = {
    "id": "openai", "name": "OpenAI", "kind": "builtin", "enabled": True, "authMode": "chatgpt_login",
}

_COLORS = {
    "window": "#F3F3F3",
    "surface": "#FFFFFF",
    "border": "#D1D1D1",
    "text": "#1B1B1B",
    "muted": "#616161",
    "accent": "#0F6CBD",
    "accent_hover": "#115EA3",
    "accent_pressed": "#0F548C",
    "accent_soft": "#DCEEFF",
    "info": "#E7F2FB",
    "error": "#FDE7E9",
    "danger": "#C50F1F",
}
_UI_FONT = "Segoe UI Variable Text"
_UI_FONT_FALLBACK = "Segoe UI"
APP_BUILD = "设置只保存在这台电脑上"
_REASONING_DEFAULT_LABEL = "默认（由模型决定）"
_AUTH_KEY_LABEL = "访问密钥"
_AUTH_LOGIN_LABEL = "ChatGPT 登录"


class DesktopAppError(ValueError):
    """A safe message suitable for the local desktop UI."""


def _default_catalog_path() -> Path:
    appdata = os.environ.get("APPDATA")
    if appdata:
        return Path(appdata) / "Lansi_CodexProviderManager" / "profiles.json"
    return Path.home() / "AppData" / "Roaming" / "Lansi_CodexProviderManager" / "profiles.json"


def _default_codex_home() -> Path:
    return Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))


def _application_resource_path(name: str) -> Path:
    """Resolve an asset both from source and a PyInstaller one-file build."""

    bundle_root = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
    return bundle_root / name


def _apply_window_icon(window: object) -> None:
    """Use the supplied Lansi icon instead of Tk's default title-bar icon."""

    if tk is None:
        return
    icon_path = _application_resource_path("LansiObserve.ico")
    if not icon_path.is_file():
        return
    try:
        window.iconbitmap(str(icon_path))
        window.iconbitmap(default=str(icon_path))
    except tk.TclError:
        # A missing/incompatible icon must never block profile management.
        return


def _has_configured_user_environment_key(environment: object) -> bool:
    """Report key presence without reading or exposing the key value."""

    if not isinstance(environment, str) or not environment.strip():
        return False
    if bool(os.environ.get(environment)):
        return True
    if sys.platform != "win32":
        return False
    try:
        import winreg

        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            value, _kind = winreg.QueryValueEx(key, environment)
        return isinstance(value, str) and bool(value.strip())
    except (FileNotFoundError, OSError):
        return False


def _configured_user_environment_value(environment: object) -> str | None:
    if not isinstance(environment, str) or not environment.strip():
        return None
    value = os.environ.get(environment)
    if isinstance(value, str) and value:
        return value
    if sys.platform != "win32":
        return None
    try:
        import winreg

        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            value, _kind = winreg.QueryValueEx(key, environment)
        return value if isinstance(value, str) and value else None
    except (FileNotFoundError, OSError):
        return None


def _public_profile(profile: dict[str, object]) -> dict[str, object]:
    return {name: profile[name] for name in _ALLOWED_PROFILE_FIELDS if name in profile}


def _normalise_profile(payload: object, *, existing: dict[str, object] | None = None) -> dict[str, object]:
    if not isinstance(payload, dict):
        raise DesktopAppError("服务信息格式不正确。")
    if set(payload) - _ALLOWED_PROFILE_FIELDS or "apiKey" in payload or "secret" in payload:
        raise DesktopAppError("只能保存服务设置，不能保存访问密钥本身。")
    source = existing or {}
    profile_id = payload.get("id", source.get("id", str(uuid.uuid4())))
    try:
        profile_id = str(uuid.UUID(str(profile_id)))
    except (ValueError, TypeError, AttributeError) as error:
        raise DesktopAppError("服务标识无效。") from error
    name = payload.get("name", source.get("name"))
    if not isinstance(name, str) or not name.strip():
        raise DesktopAppError("缺少必填字段：名称。")
    values: dict[str, object] = {
        "id": profile_id,
        "name": name.strip(),
        "enabled": bool(payload.get("enabled", source.get("enabled", True))),
        "authMode": str(payload.get("authMode", source.get("authMode", "api_key"))),
        "configOverrides": {},
    }
    if values["authMode"] not in {"api_key", "chatgpt_login"}:
        raise DesktopAppError("认证方式不受支持。")
    for field in ("baseUrl", "wireApi", "apiKeyEnv", "model", "reasoningEffort", "reviewModel"):
        value = payload.get(field, source.get(field))
        if value is None or value == "":
            continue
        if not isinstance(value, str) or not value.strip():
            raise DesktopAppError(f"字段 {field} 必须是文本。")
        values[field] = value.strip()
    models = payload.get("models", source.get("models", []))
    if models is None:
        models = []
    if not isinstance(models, list) or any(not isinstance(model, str) or not model.strip() for model in models):
        raise DesktopAppError("模型列表必须是非空文本列表。")
    values["models"] = list(dict.fromkeys(model.strip() for model in models))
    if len(values["models"]) > MAX_MANAGED_MODELS:
        raise DesktopAppError(f"模型列表最多保留 {MAX_MANAGED_MODELS} 项。")
    if values.get("wireApi") not in {None, "responses"}:
        raise DesktopAppError("当前 Codex 版本仅支持 Responses API。")
    if values["authMode"] == "api_key":
        for field in ("baseUrl", "wireApi", "apiKeyEnv", "model"):
            if field not in values:
                raise DesktopAppError(f"使用访问密钥时还需要填写：{field}。")
    overrides = payload.get("configOverrides", source.get("configOverrides", {}))
    if not isinstance(overrides, dict) or overrides:
        raise DesktopAppError("当前设置包含不支持的高级选项。")
    return values


def _broadcast_windows_environment_change() -> None:
    if sys.platform != "win32":
        return
    try:
        import ctypes

        result = ctypes.c_ulong()
        ctypes.windll.user32.SendMessageTimeoutW(  # type: ignore[attr-defined]
            0xFFFF, 0x001A, 0, "Environment", 0x0002, 5000, ctypes.byref(result)
        )
    except (AttributeError, OSError):
        return


def _store_user_environment_key(environment: str, api_key: str) -> None:
    """Store an API key without sending it to a command line or profile JSON."""

    if sys.platform == "win32":
        import winreg

        with winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, "Environment", 0, winreg.KEY_SET_VALUE) as key:
            winreg.SetValueEx(key, environment, 0, winreg.REG_SZ, api_key)
    os.environ[environment] = api_key
    _broadcast_windows_environment_change()


def _enable_windows_dpi_awareness() -> None:
    """Opt into per-monitor DPI before Tk creates its first native window."""

    if sys.platform != "win32":
        return
    try:
        import ctypes

        user32 = ctypes.windll.user32  # type: ignore[attr-defined]
        context = ctypes.c_void_p(-4)  # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
        if hasattr(user32, "SetProcessDpiAwarenessContext") and user32.SetProcessDpiAwarenessContext(context):
            return
        shcore = getattr(ctypes.windll, "shcore", None)  # type: ignore[attr-defined]
        if shcore is not None and shcore.SetProcessDpiAwareness(2) == 0:
            return
        user32.SetProcessDPIAware()
    except (AttributeError, OSError):
        return


def _set_windows_app_user_model_id() -> None:
    """Give the windowed process a stable taskbar identity so Windows shows the
    packaged family icon instead of the Python host icon."""

    if sys.platform != "win32":
        return
    try:
        import ctypes

        ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID(  # type: ignore[attr-defined]
            "Lansi.CodexProviderManager"
        )
    except (AttributeError, OSError):
        return


class DesktopProviderManager:
    """Non-UI operations shared by the native desktop surface and unit tests."""

    def __init__(self, catalog_path: Path, codex_home: Path):
        self.catalog_path = Path(catalog_path)
        self.codex_home = Path(codex_home)
        self.config_path = self.codex_home / "config.toml"
        self.state_db_path = self.codex_home / "state_5.sqlite"

    def _load(self) -> dict[str, object]:
        return load_catalog(self.catalog_path) if self.catalog_path.exists() else {"profiles": []}

    def _save(self, catalog: dict[str, object]) -> None:
        save_catalog(self.catalog_path, catalog)

    def _profile(self, profile_id: str) -> dict[str, object]:
        profile = next((item for item in self._load()["profiles"] if item["id"] == profile_id), None)
        if profile is None:
            raise DesktopAppError("找不到这个服务。")
        return profile

    def _model_catalog_path(self, profile_id: str) -> Path:
        canonical_id = str(uuid.UUID(profile_id))
        return self.catalog_path.parent / "model-catalogs" / f"{canonical_id}.json"

    def profile_for_edit(self, profile_id: str) -> dict[str, object]:
        """Reload the saved non-secret profile immediately before it is edited."""

        return _public_profile(self._profile(profile_id))

    def state(self) -> dict[str, object]:
        catalog = self._load()
        runtime: dict[str, object] = {}
        try:
            runtime = status(self.config_path, self.state_db_path)
            current_provider = runtime.get("current_provider")
            diagnostics = runtime.get("diagnostics", {})
        except Exception:
            runtime = {}
            current_provider, diagnostics = None, {"history_error": "status_unavailable"}
        selected_id = "openai" if current_provider == "openai" else None
        if isinstance(current_provider, str) and current_provider.startswith("custom_"):
            for profile in catalog["profiles"]:
                if f"custom_{uuid.UUID(str(profile['id'])).hex[:12]}" == current_provider:
                    selected_id = str(profile["id"])
                    break
        profiles = [_public_profile(profile) for profile in catalog["profiles"]]
        return {
            "choices": [dict(_BUILTIN_OPENAI)] + [
                {"id": p["id"], "name": p["name"], "kind": "custom", "enabled": p["enabled"], "authMode": p["authMode"]}
                for p in profiles
            ],
            "profiles": profiles,
            "credentialStatus": {
                str(profile["id"]): _has_configured_user_environment_key(profile.get("apiKeyEnv"))
                for profile in catalog["profiles"] if profile.get("authMode") == "api_key"
            },
            "currentProvider": current_provider,
            "selectedId": selected_id,
            "connection": runtime.get("connection", {}),
            "diagnostics": diagnostics,
            "latestBackup": self._has_latest_backup(),
        }

    def _has_latest_backup(self) -> bool:
        """Report whether a managed switch backup exists without exposing its contents."""

        backup_dir = self.codex_home / "backups" / "windows-provider-switch"
        try:
            return backup_dir.is_dir() and any(backup_dir.iterdir())
        except OSError:
            return False

    def upsert(self, payload: object) -> dict[str, object]:
        catalog = self._load()
        existing = None
        if isinstance(payload, dict) and payload.get("id"):
            existing = next((item for item in catalog["profiles"] if item["id"] == payload["id"]), None)
        profile = _normalise_profile(payload, existing=existing)
        catalog["profiles"] = [item for item in catalog["profiles"] if item["id"] != profile["id"]] + [profile]
        self._save(catalog)
        return _public_profile(profile)

    def store_key(self, profile_id: str, api_key: str) -> None:
        if not api_key.strip():
            raise DesktopAppError("访问密钥不能为空。")
        if len(api_key) > _MAX_API_KEY_LENGTH:
            raise DesktopAppError("访问密钥过长。")
        profile = self._profile(profile_id)
        if profile.get("authMode") != "api_key":
            raise DesktopAppError("只有使用访问密钥的服务可以保存访问密钥。")
        environment = profile.get("apiKeyEnv")
        if not isinstance(environment, str) or not environment:
            raise DesktopAppError("服务还没有填写密钥变量名。")
        try:
            _store_user_environment_key(environment, api_key)
        except (OSError, ValueError):
            raise DesktopAppError("无法保存当前 Windows 用户的访问密钥。") from None

    def remove(self, profile_id: str) -> None:
        if self._active_custom_profile_id() == profile_id:
            raise DesktopAppError("请先启用其他服务，再删除当前正在使用的服务。")
        catalog = self._load()
        profiles = [item for item in catalog["profiles"] if item["id"] != profile_id]
        if len(profiles) == len(catalog["profiles"]):
            raise DesktopAppError("找不到这个服务。")
        catalog["profiles"] = profiles
        self._save(catalog)

    def toggle(self, profile_id: str, enabled: bool) -> None:
        if not enabled and self._active_custom_profile_id() == profile_id:
            raise DesktopAppError("请先启用其他服务，再停用当前正在使用的服务。")
        profile = self._profile(profile_id)
        profile["enabled"] = bool(enabled)
        catalog = self._load()
        catalog["profiles"] = [profile if item["id"] == profile_id else item for item in catalog["profiles"]]
        self._save(catalog)

    def import_profiles(self, payload: object) -> list[str]:
        if not isinstance(payload, dict):
            raise DesktopAppError("导入内容必须是 JSON 对象。")
        raw_profiles = payload.get("profiles", [payload])
        if not isinstance(raw_profiles, list) or not raw_profiles:
            raise DesktopAppError("导入内容中没有可用的服务。")
        catalog = self._load()
        imported = [_normalise_profile(item) for item in raw_profiles]
        ids = {item["id"] for item in imported}
        catalog["profiles"] = [item for item in catalog["profiles"] if item["id"] not in ids] + imported
        self._save(catalog)
        return [str(item["id"]) for item in imported]

    def export_profile(self, profile_id: str) -> dict[str, object]:
        return {"profiles": [_public_profile(self._profile(profile_id))]}

    def fetch_models(self, base_url: str, api_key: str) -> list[str]:
        return fetch_models(base_url, api_key)

    def check(self, provider_id: str) -> dict[str, object]:
        preflight_verified = self._preflight_provider(provider_id)
        result = self._switch(provider_id, dry_run=True)
        result["preflight_verified"] = preflight_verified
        result["verified_provider"] = True
        return result

    def switch(self, provider_id: str, *, phase_callback: object | None = None) -> dict[str, object]:
        if callable(phase_callback):
            phase_callback("preflight", "正在检查目标服务和访问密钥…")
        preflight_verified = self._preflight_provider(provider_id)
        result = self._switch(provider_id, dry_run=False, phase_callback=phase_callback)
        result["preflight_verified"] = preflight_verified
        return result

    def _preflight_provider(self, provider_id: str) -> bool:
        if provider_id == "openai":
            return True
        profile = self._profile(provider_id)
        if profile.get("authMode") == "api_key":
            key = _configured_user_environment_value(profile.get("apiKeyEnv"))
            if key is None:
                raise DesktopAppError("没有找到这个服务的访问密钥，请先保存后再检查。")
            try:
                self.fetch_models(str(profile.get("baseUrl") or ""), key)
            except (DesktopAppError, ProfileCatalogError, OSError, RuntimeError, ValueError) as error:
                raise DesktopAppError(f"目标服务检查失败：{error}") from error
        return True

    def _switch(self, provider_id: str, *, dry_run: bool, phase_callback: object | None = None) -> dict[str, object]:
        if provider_id == "openai":
            result = switch_provider(
                "openai", self.config_path, self.state_db_path, dry_run=dry_run, phase_callback=phase_callback
            )
        else:
            profile = self._profile(provider_id)
            model_catalog = build_managed_model_catalog(
                list(profile.get("models", [])),
                str(profile.get("model") or ""),
            )
            model_catalog_path = self._model_catalog_path(provider_id)
            if not dry_run:
                save_codex_model_catalog(model_catalog_path, model_catalog)
            result = switch_custom_profile(
                profile,
                self.config_path,
                self.state_db_path,
                dry_run=dry_run,
                model_catalog_path=model_catalog_path,
                phase_callback=phase_callback,
            )
        allowed = {"provider", "display_name", "changed", "dry_run", "preflight_verified", "verified_config", "verified_provider", "verified_threads", "thread_routing", "connection", "synced_threads", "normalized_session_items", "old_api_key_cleared", "runtime_stopped", "runtime_launched", "environment_injection_verified", "restored", "config_backup", "state_backup", "backup_manifest"}
        return {name: value for name, value in result.items() if name in allowed}

    def restore(self) -> dict[str, object]:
        return restore_latest(self.config_path, self.state_db_path)

    def request_codex_graceful_shutdown(self, *, tick: object | None = None) -> dict[str, object]:
        return request_codex_graceful_shutdown(tick=tick) if tick is not None else request_codex_graceful_shutdown()

    def _active_custom_profile_id(self) -> str | None:
        try:
            current = status(self.config_path, self.state_db_path).get("current_provider")
        except Exception as error:
            raise DesktopAppError("无法确认当前服务；为保护设置，暂时不能执行此操作。") from error
        if not isinstance(current, str) or not current.startswith("custom_"):
            return None
        for profile in self._load()["profiles"]:
            if f"custom_{uuid.UUID(str(profile['id'])).hex[:12]}" == current:
                return str(profile["id"])
        return None


try:
    import tkinter as tk
    from tkinter import filedialog, ttk
except ImportError:  # A packaged Windows build includes Tcl/Tk through PyInstaller.
    tk = None


def _clipboard_copy(widget: object, text: object) -> None:
    """Copy text through the owning window while ignoring empty values."""

    if tk is None:
        return
    value = str(text or "")
    if not value:
        return
    try:
        top = widget.winfo_toplevel()
        top.clipboard_clear()
        top.clipboard_append(value)
        top.update_idletasks()
    except tk.TclError:
        return


def _label_copy_text(widget: object) -> str:
    """Return the current displayed text for a label, including textvariable labels."""

    if tk is None:
        return ""
    try:
        return str(widget.cget("text") or "")
    except (tk.TclError, ValueError):
        return ""


def _show_copy_only_menu(widget: object, event: object, text: object | None = None) -> None:
    if tk is None:
        return
    value = str(text) if text is not None else _label_copy_text(widget)
    menu = tk.Menu(widget, tearoff=0)
    menu.add_command(
        label="复制",
        command=lambda: _clipboard_copy(widget, value),
        state="normal" if value else "disabled",
    )
    try:
        menu.tk_popup(int(event.x_root), int(event.y_root))
    finally:
        menu.grab_release()


def _entry_is_readonly(widget: object) -> bool:
    if tk is None:
        return True
    try:
        state = str(widget.cget("state"))
    except tk.TclError:
        return True
    return "readonly" in state or "disabled" in state


def _entry_selection(widget: object) -> str:
    try:
        if widget.selection_present():
            return str(widget.selection_get())
    except (tk.TclError, ValueError):
        pass
    return ""


def _entry_copy(widget: object) -> None:
    selected = _entry_selection(widget)
    try:
        value = selected if selected else str(widget.get() or "")
    except (tk.TclError, ValueError):
        value = selected
    _clipboard_copy(widget, value)


def _entry_paste(widget: object) -> None:
    if tk is None or _entry_is_readonly(widget):
        return
    try:
        top = widget.winfo_toplevel()
        value = top.clipboard_get()
    except tk.TclError:
        return
    if not value:
        return
    try:
        widget.focus_set()
        if widget.selection_present():
            widget.delete("sel.first", "sel.last")
        widget.insert("insert", value)
    except (tk.TclError, ValueError):
        return


def _entry_select_all(widget: object) -> None:
    try:
        widget.focus_set()
        widget.selection_range(0, "end")
    except tk.TclError:
        return


def _show_editable_menu(widget: object, event: object) -> None:
    if tk is None:
        return
    menu = tk.Menu(widget, tearoff=0)
    menu.add_command(label="复制", command=lambda: _entry_copy(widget))
    if not _entry_is_readonly(widget):
        menu.add_command(label="粘贴", command=lambda: _entry_paste(widget))
    menu.add_separator()
    menu.add_command(label="全选", command=lambda: _entry_select_all(widget))
    try:
        menu.tk_popup(int(event.x_root), int(event.y_root))
    finally:
        menu.grab_release()


def _show_tree_menu(widget: object, event: object) -> None:
    if tk is None:
        return
    value = ""
    try:
        row = widget.identify_row(int(event.y))
        if row:
            widget.selection_set(row)
            value = str(widget.item(row, "text") or "")
    except tk.TclError:
        value = ""
    _show_copy_only_menu(widget, event, value)


def _text_selection(widget: object) -> str:
    try:
        if widget.tag_ranges("sel"):
            return str(widget.get("sel.first", "sel.last"))
    except tk.TclError:
        pass
    return ""


def _text_copy(widget: object) -> None:
    selected = _text_selection(widget)
    if selected:
        _clipboard_copy(widget, selected)
        return
    try:
        value = widget.get("1.0", "end-1c")
    except tk.TclError:
        value = ""
    _clipboard_copy(widget, value)


def _text_select_all(widget: object) -> None:
    try:
        widget.tag_add("sel", "1.0", "end-1c")
        widget.mark_set("insert", "1.0")
        widget.see("1.0")
    except tk.TclError:
        return


def _show_text_menu(widget: object, event: object) -> None:
    if tk is None:
        return
    menu = tk.Menu(widget, tearoff=0)
    menu.add_command(label="复制", command=lambda: _text_copy(widget))
    menu.add_separator()
    menu.add_command(label="全选", command=lambda: _text_select_all(widget))
    try:
        menu.tk_popup(int(event.x_root), int(event.y_root))
    finally:
        menu.grab_release()


def _bind_context_menus(widget: object) -> None:
    """Install right-click copy/paste menus on every text-bearing control."""

    if tk is None:
        return
    if isinstance(widget, ttk.Treeview):
        widget.bind("<Button-3>", lambda event: _show_tree_menu(widget, event))
    elif isinstance(widget, tk.Text):
        widget.bind("<Button-3>", lambda event: _show_text_menu(widget, event))
    elif isinstance(widget, (ttk.Entry, tk.Entry)):
        widget.bind("<Button-3>", lambda event: _show_editable_menu(widget, event))
    elif isinstance(widget, (ttk.Label, tk.Label)):
        widget.bind("<Button-3>", lambda event: _show_copy_only_menu(widget, event))
    for child in widget.winfo_children():
        _bind_context_menus(child)


class WindowsButton(tk.Button if tk is not None else object):
    """A predictable Windows 11-style button independent of ttk theme quirks."""

    def __init__(self, parent: object, text: str, command: object, *, kind: str = "secondary"):
        if tk is None:
            raise RuntimeError("Python Tcl/Tk is required for the Windows desktop UI.")
        self.kind = kind
        self.palette = self._palette(kind)
        super().__init__(
            parent,
            text=text,
            command=command,
            font=(_UI_FONT, 10, "bold" if kind == "primary" else "normal"),
            anchor="center",
            cursor="hand2",
            relief="flat",
            borderwidth=0,
            padx=14,
            pady=8,
            takefocus=True,
            highlightthickness=1,
            highlightbackground=self.palette["border"],
            highlightcolor=_COLORS["accent"],
            disabledforeground=self.palette["disabled_text"],
        )
        self._apply("normal")
        self.bind("<Enter>", lambda _event: self._apply("hover"))
        self.bind("<Leave>", lambda _event: self._apply("normal"))
        self.bind("<ButtonPress-1>", lambda _event: self._apply("pressed"))
        self.bind("<ButtonRelease-1>", lambda _event: self._apply("hover"))

    @staticmethod
    def _palette(kind: str) -> dict[str, str]:
        if kind == "primary":
            return {
                "normal": _COLORS["accent"], "hover": _COLORS["accent_hover"], "pressed": _COLORS["accent_pressed"],
                "foreground": "#FFFFFF", "disabled": "#C8C6C4", "disabled_text": "#FFFFFF", "border": _COLORS["accent"],
            }
        if kind == "danger":
            return {
                "normal": _COLORS["danger"], "hover": "#A4262C", "pressed": "#8E0B16",
                "foreground": "#FFFFFF", "disabled": "#E7E7E7", "disabled_text": "#A19F9D", "border": _COLORS["danger"],
            }
        return {
            "normal": _COLORS["surface"], "hover": "#F0F6FF", "pressed": _COLORS["accent_soft"],
            "foreground": _COLORS["text"], "disabled": "#F3F3F3", "disabled_text": "#A19F9D", "border": _COLORS["border"],
        }

    def _apply(self, state: str) -> None:
        if self.cget("state") == "disabled":
            self.configure(background=self.palette["disabled"], foreground=self.palette["disabled_text"], activebackground=self.palette["disabled"])
            return
        background = self.palette[state]
        self.configure(background=background, foreground=self.palette["foreground"], activebackground=self.palette["pressed"], activeforeground=self.palette["foreground"])

    def configure(self, cnf: object | None = None, **kwargs: object) -> object:
        result = super().configure(cnf, **kwargs)
        if kwargs.get("state") == "disabled":
            self._apply("normal")
        elif kwargs.get("state") == "normal":
            self._apply("normal")
        return result

    config = configure


def _copyable_dialog(
    parent: object,
    title: str,
    message: str,
    *,
    confirm: bool = False,
) -> bool:
    """Show a native-looking dialog whose message can be selected and copied."""

    if tk is None:
        return False
    top = tk.Toplevel(parent)
    top.title(title)
    top.transient(parent)
    try:
        top.grab_set()
    except tk.TclError:
        pass
    top.configure(background=_COLORS["window"])
    _apply_window_icon(top)
    top.resizable(True, True)
    top.minsize(420, 180)
    top.columnconfigure(0, weight=1)
    top.rowconfigure(0, weight=1)

    body = ttk.Frame(top, style="App.TFrame", padding=(20, 18, 20, 14))
    body.grid(row=0, column=0, sticky="nsew")
    body.columnconfigure(0, weight=1)
    body.rowconfigure(0, weight=1)

    line_count = max(3, min(14, message.count("\n") + 1))
    text = tk.Text(
        body,
        width=68,
        height=line_count,
        wrap="word",
        relief="flat",
        borderwidth=0,
        highlightthickness=0,
        background=_COLORS["window"],
        foreground=_COLORS["text"],
        font=(_UI_FONT_FALLBACK, 10),
        padx=2,
        pady=2,
    )
    text.insert("1.0", message)
    text.configure(state="disabled")
    text.grid(row=0, column=0, sticky="nsew")
    _bind_context_menus(text)

    actions = ttk.Frame(body, style="App.TFrame")
    actions.grid(row=1, column=0, sticky="e", pady=(14, 0))
    result: dict[str, object] = {"value": False}

    def close(value: bool) -> None:
        result["value"] = value
        top.destroy()

    if confirm:
        WindowsButton(actions, "否", lambda: close(False)).grid(row=0, column=0, padx=(0, 8))
        WindowsButton(actions, "是", lambda: close(True), kind="primary").grid(row=0, column=1)
        top.protocol("WM_DELETE_WINDOW", lambda: close(False))
        top.bind("<Escape>", lambda _event: close(False))
        top.bind("<Return>", lambda _event: close(True))
    else:
        WindowsButton(actions, "确定", lambda: close(True), kind="primary").grid(row=0, column=0)
        top.protocol("WM_DELETE_WINDOW", lambda: close(True))
        top.bind("<Escape>", lambda _event: close(True))
        top.bind("<Return>", lambda _event: close(True))

    _center_toplevel(top, parent)
    top.wait_window()
    return bool(result["value"])


def _askyesno(parent: object, title: str, message: str) -> bool:
    """Ask a copyable confirmation dialog instead of a fixed tkinter messagebox."""

    return _copyable_dialog(parent, title, message, confirm=True)


def _showerror(parent: object, title: str, message: str) -> bool:
    """Show a copyable error dialog instead of a fixed tkinter messagebox."""

    return _copyable_dialog(parent, title, message, confirm=False)


def _center_toplevel(window: object, parent: object) -> None:
    """Center a Toplevel over its parent without forcing it off-screen."""

    try:
        window.update_idletasks()
        parent.update_idletasks()
        parent_x = int(parent.winfo_rootx())
        parent_y = int(parent.winfo_rooty())
        parent_w = max(1, int(parent.winfo_width()))
        parent_h = max(1, int(parent.winfo_height()))
        width = max(1, int(window.winfo_reqwidth()))
        height = max(1, int(window.winfo_reqheight()))
        x = max(0, parent_x + (parent_w - width) // 2)
        y = max(0, parent_y + (parent_h - height) // 2)
        window.geometry(f"+{x}+{y}")
    except tk.TclError:
        return


def _format_bytes(bytes_count: int) -> str:
    """Compact human-readable byte size, e.g. 3.5 GB."""
    value = float(bytes_count)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} {unit}"
        value /= 1024
    return f"{int(bytes_count)} B"


class ProviderDesktopApp:
    """Windows 11-inspired blue and white Tk desktop surface."""

    def __init__(self, root: object, manager: DesktopProviderManager):
        if tk is None:
            raise RuntimeError("Python Tcl/Tk is required for the Windows desktop UI.")
        self.root = root
        self.manager = manager
        self.state: dict[str, object] = {}
        self.selected_id: str | None = None
        self._initial_window_fitted = False
        self._content_scrollbar_visible = True
        self._detail_columns = 2
        self._style()
        self._build()
        self.refresh()
        _bind_context_menus(self.root)
        self.provider_tree.bind("<Button-3>", self._on_tree_menu)
        self.root.bind("<Control-r>", lambda _event: self.refresh())
        self.root.bind("<F5>", lambda _event: self.refresh())

    def _style(self) -> None:
        self.root.title("Lansi Codex Provider Manager")
        self.root.geometry("1120x640")
        self.root.minsize(820, 540)
        self.root.configure(background=_COLORS["window"])
        _apply_window_icon(self.root)
        style = ttk.Style(self.root)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("App.TFrame", background=_COLORS["window"])
        style.configure("Sidebar.TFrame", background=_COLORS["surface"])
        style.configure("Card.TFrame", background=_COLORS["surface"], relief="solid", borderwidth=1)
        style.configure("CardBody.TFrame", background=_COLORS["surface"])
        style.configure("Metric.TFrame", background=_COLORS["surface"])
        style.configure("Title.TLabel", background=_COLORS["window"], foreground=_COLORS["text"], font=(_UI_FONT, 20, "bold"))
        style.configure("Subtle.TLabel", background=_COLORS["window"], foreground=_COLORS["muted"], font=(_UI_FONT_FALLBACK, 10))
        style.configure("SidebarTitle.TLabel", background=_COLORS["surface"], foreground=_COLORS["text"], font=(_UI_FONT, 16, "bold"))
        style.configure("Sidebar.TLabel", background=_COLORS["surface"], foreground=_COLORS["muted"], font=(_UI_FONT_FALLBACK, 10))
        style.configure("SidebarCaption.TLabel", background=_COLORS["surface"], foreground=_COLORS["muted"], font=(_UI_FONT_FALLBACK, 9, "bold"))
        style.configure("Build.TLabel", background=_COLORS["surface"], foreground=_COLORS["muted"], font=(_UI_FONT_FALLBACK, 8))
        style.configure("CardTitle.TLabel", background=_COLORS["surface"], foreground=_COLORS["text"], font=(_UI_FONT, 11, "bold"))
        style.configure("Value.TLabel", background=_COLORS["surface"], foreground=_COLORS["text"], font=(_UI_FONT_FALLBACK, 10))
        style.configure("FieldLabel.TLabel", background=_COLORS["surface"], foreground=_COLORS["muted"], font=(_UI_FONT_FALLBACK, 10))
        style.configure("DialogField.TLabel", background=_COLORS["window"], foreground=_COLORS["muted"], font=(_UI_FONT_FALLBACK, 10))
        style.configure("KeyStatus.TLabel", background=_COLORS["window"], foreground="#107C10", font=(_UI_FONT_FALLBACK, 9))
        style.configure("KeyStatusWarning.TLabel", background=_COLORS["window"], foreground="#A4262C", font=(_UI_FONT_FALLBACK, 9))
        style.configure("InfoBar.TLabel", background=_COLORS["info"], foreground="#0F548C", font=(_UI_FONT_FALLBACK, 10), padding=(12, 8))
        style.configure("ErrorBar.TLabel", background=_COLORS["error"], foreground="#A4262C", font=(_UI_FONT_FALLBACK, 10), padding=(12, 8))
        style.configure("Field.TEntry", fieldbackground=_COLORS["surface"], foreground=_COLORS["text"], padding=(8, 6), font=(_UI_FONT_FALLBACK, 10))
        style.configure("Field.TCombobox", fieldbackground=_COLORS["surface"], foreground=_COLORS["text"], padding=(7, 5), font=(_UI_FONT_FALLBACK, 10))
        style.map("Field.TEntry", bordercolor=[("focus", _COLORS["accent"])])
        style.map("Field.TCombobox", fieldbackground=[("readonly", _COLORS["surface"])], bordercolor=[("focus", _COLORS["accent"])])
        style.configure("Provider.Treeview", background=_COLORS["surface"], fieldbackground=_COLORS["surface"], foreground=_COLORS["text"], borderwidth=0, rowheight=44, font=(_UI_FONT_FALLBACK, 9))
        style.map("Provider.Treeview", background=[("selected", _COLORS["accent"]), ("focus", _COLORS["accent_soft"])], foreground=[("selected", "#FFFFFF"), ("focus", _COLORS["text"])])

    def _build(self) -> None:
        shell = ttk.Frame(self.root, style="App.TFrame", padding=0)
        shell.grid(row=0, column=0, sticky="nsew")
        self.root.rowconfigure(0, weight=1)
        self.root.columnconfigure(0, weight=1)
        shell.rowconfigure(0, weight=1)
        shell.columnconfigure(1, weight=1)
        sidebar = ttk.Frame(shell, style="Sidebar.TFrame", width=240, padding=(18, 22))
        sidebar.grid(row=0, column=0, sticky="nsew")
        sidebar.grid_propagate(False)
        # A fixed-height list keeps the action buttons and build label visible
        # on short displays instead of allowing the list to consume the footer.
        sidebar.rowconfigure(3, weight=0)
        sidebar.columnconfigure(0, weight=1)
        ttk.Label(sidebar, text="兰司观察", style="SidebarTitle.TLabel").grid(row=0, column=0, sticky="w")
        ttk.Label(sidebar, text="Codex Provider Manager", style="Sidebar.TLabel").grid(row=1, column=0, sticky="w", pady=(2, 22))
        ttk.Label(sidebar, text="服务列表", style="SidebarCaption.TLabel").grid(row=2, column=0, sticky="w", pady=(0, 8))
        provider_list = ttk.Frame(sidebar, style="Sidebar.TFrame")
        provider_list.grid(row=3, column=0, sticky="nsew")
        provider_list.rowconfigure(0, weight=1)
        provider_list.columnconfigure(0, weight=1)
        self.provider_tree = ttk.Treeview(provider_list, style="Provider.Treeview", show="tree", selectmode="browse", height=4)
        self.provider_tree.grid(row=0, column=0, sticky="nsew")
        self._provider_scrollbar = ttk.Scrollbar(
            provider_list, orient="vertical", command=self.provider_tree.yview
        )
        self._provider_scrollbar.grid(row=0, column=1, sticky="ns", padx=(8, 0))
        self._provider_scrollbar.grid_remove()
        self.provider_tree.configure(yscrollcommand=self._provider_scrollbar.set)
        self.provider_tree.bind("<<TreeviewSelect>>", lambda _event: self._on_select())
        self.provider_tree.bind("<Double-1>", self._on_tree_double_click)
        bottom = ttk.Frame(sidebar, style="Sidebar.TFrame")
        bottom.grid(row=4, column=0, sticky="ew", pady=(14, 0))
        bottom.columnconfigure(0, weight=1)
        add_button = WindowsButton(bottom, "＋ 添加服务", lambda: self._open_editor("new"), kind="primary")
        add_button.grid(row=0, column=0, sticky="ew")
        add_button.bind("<Button-3>", self._on_add_provider_menu)
        ttk.Label(
            sidebar,
            text="访问密钥只保存在当前 Windows 用户账户中，不会显示或导出。",
            style="Sidebar.TLabel",
            justify="left",
            wraplength=200,
        ).grid(row=5, column=0, sticky="w", pady=(12, 0))
        ttk.Label(sidebar, text=APP_BUILD, style="Build.TLabel", justify="left", wraplength=200).grid(
            row=6, column=0, sticky="w", pady=(8, 0)
        )

        main = ttk.Frame(shell, style="App.TFrame", padding=(28, 18))
        main.grid(row=0, column=1, sticky="nsew")
        self.main = main
        main.rowconfigure(2, weight=1)
        main.columnconfigure(0, weight=1)
        main.bind("<Configure>", self._on_main_resize)
        header = ttk.Frame(main, style="App.TFrame")
        header.grid(row=0, column=0, sticky="ew")
        header.columnconfigure(0, weight=1)
        text = ttk.Frame(header, style="App.TFrame")
        text.grid(row=0, column=0, sticky="ew")
        self.title_label = ttk.Label(text, text="服务管理", style="Title.TLabel", justify="left")
        self.title_label.grid(row=0, column=0, sticky="w")
        self.subtitle_label = ttk.Label(text, text="选择一个服务，查看设置后即可启用。", style="Subtle.TLabel", justify="left")
        self.subtitle_label.grid(row=1, column=0, sticky="w", pady=(3, 0))
        self.status_badge = tk.StringVar(value="")
        self.status_label = ttk.Label(header, textvariable=self.status_badge, style="KeyStatus.TLabel", anchor="e")
        self.status_label.grid(
            row=0, column=1, sticky="e"
        )
        self.notice = tk.StringVar(value="访问密钥只保存在当前 Windows 用户账户中。")
        self.notice_label = ttk.Label(main, textvariable=self.notice, style="InfoBar.TLabel")
        self.notice_label.grid(row=1, column=0, sticky="ew", pady=(10, 8))
        content_shell = ttk.Frame(main, style="App.TFrame")
        content_shell.grid(row=2, column=0, sticky="nsew")
        self.content_shell = content_shell
        content_shell.rowconfigure(0, weight=1)
        content_shell.columnconfigure(0, weight=1)
        self._content_canvas = tk.Canvas(
            content_shell,
            background=_COLORS["window"],
            borderwidth=0,
            highlightthickness=0,
        )
        self._content_canvas.grid(row=0, column=0, sticky="nsew")
        self._content_scrollbar = ttk.Scrollbar(
            content_shell, orient="vertical", command=self._content_canvas.yview
        )
        self._content_scrollbar.grid(row=0, column=1, sticky="ns", padx=(10, 0))
        self._content_canvas.configure(yscrollcommand=self._content_scrollbar.set)
        self.content = ttk.Frame(self._content_canvas, style="App.TFrame")
        self._content_window = self._content_canvas.create_window((0, 0), window=self.content, anchor="nw")
        self.content.bind("<Configure>", self._on_content_configure)
        self._content_canvas.bind("<Configure>", self._on_content_canvas_configure)
        main.bind("<MouseWheel>", self._on_content_mousewheel, add="+")
        main.bind("<Button-4>", lambda _event: self._scroll_content(-1), add="+")
        main.bind("<Button-5>", lambda _event: self._scroll_content(1), add="+")
        self.content.columnconfigure(0, weight=1)
        self.details = ttk.Frame(self.content, style="Card.TFrame", padding=14)
        self.details.grid(row=0, column=0, sticky="nsew")
        self.details.columnconfigure(0, weight=1)
        self.details.rowconfigure(1, weight=1)
        card_header = ttk.Frame(self.details, style="CardBody.TFrame")
        card_header.grid(row=0, column=0, sticky="ew", pady=(0, 8))
        card_header.columnconfigure(0, weight=1)
        ttk.Label(card_header, text="服务详情", style="CardTitle.TLabel").grid(row=0, column=0, sticky="w")
        self.check_button = WindowsButton(card_header, "检查服务", self._check)
        self.check_button.grid(row=0, column=1, sticky="e")
        self.detail_rows = ttk.Frame(self.details, style="CardBody.TFrame")
        self.detail_rows.grid(row=1, column=0, sticky="nsew")
        card = ttk.Frame(self.content, style="Card.TFrame", padding=14)
        card.grid(row=1, column=0, sticky="ew", pady=(10, 0))
        self.diagnostics_card = card
        card.columnconfigure(0, weight=1)
        ttk.Label(card, text="系统状态", style="CardTitle.TLabel").grid(row=0, column=0, sticky="w", pady=(0, 6))
        self.diagnostics = ttk.Frame(card, style="CardBody.TFrame")
        self.diagnostics.grid(row=1, column=0, sticky="ew")

        actions = ttk.Frame(main, style="App.TFrame")
        actions.grid(row=3, column=0, sticky="ew", pady=(12, 10))
        self.action_frame = actions
        actions.columnconfigure(0, weight=1)
        self._action_rows = 1
        self.edit_button = WindowsButton(actions, "编辑服务", lambda: self._open_editor("edit"))
        self.refresh_button = WindowsButton(actions, "刷新状态", self.refresh)
        self.backup_button = WindowsButton(actions, "备份管理", self._backup_management)
        self.restore_button = WindowsButton(actions, "恢复最近备份", self._restore)
        self.toggle_button = WindowsButton(actions, "停用", self._toggle)
        self.delete_button = WindowsButton(actions, "删除", self._delete, kind="danger")
        self.switch_button = WindowsButton(actions, "应用设置并重启 ChatGPT", self._switch, kind="primary")
        self._action_buttons = (
            self.edit_button,
            self.refresh_button,
            self.backup_button,
            self.restore_button,
            self.toggle_button,
            self.delete_button,
            self.switch_button,
        )
        for column, button in enumerate(self._action_buttons, start=1):
            actions.columnconfigure(column, weight=0)
            button.grid(row=0, column=column, sticky="e", padx=(8, 0))

    def _fit_open_window(self) -> None:
        """Open large enough to show the two main cards before scrolling."""

        if self._initial_window_fitted:
            return
        try:
            self.root.update_idletasks()
            screen_width = max(1, int(self.root.winfo_screenwidth()))
            screen_height = max(1, int(self.root.winfo_screenheight()))
            usable_width = max(1, screen_width - 48)
            usable_height = max(1, screen_height - 72)
            minimum_width = min(820, usable_width)
            minimum_height = min(540, usable_height)
            target_width = max(minimum_width, min(1120, usable_width))
            self.root.geometry(f"{target_width}x{min(usable_height, max(minimum_height, self.root.winfo_height()))}")
            self.root.update_idletasks()
            content_height = max(
                self.content.winfo_reqheight(),
                self.details.winfo_reqheight() + 16 + self.diagnostics_card.winfo_reqheight(),
            )
            non_content_height = max(0, self.root.winfo_height() - self.content_shell.winfo_height())
            preferred_height = min(content_height + non_content_height + 8, 760)
            target_height = min(usable_height, max(minimum_height, preferred_height))
            self.root.geometry(f"{target_width}x{target_height}")
            self._initial_window_fitted = True
            self.root.after_idle(self._sync_content_scrollbar)
        except tk.TclError:
            return

    def _sync_content_scrollbar(self) -> None:
        """Only reserve scroll chrome when the viewport cannot show both cards."""

        content_height = max(self.content.winfo_reqheight(), self.content.winfo_height())
        viewport_height = max(1, self._content_canvas.winfo_height())
        should_show = content_height > viewport_height + 1
        if should_show == self._content_scrollbar_visible:
            return
        self._content_scrollbar_visible = should_show
        if should_show:
            self._content_scrollbar.grid()
        else:
            self._content_scrollbar.grid_remove()

    def _on_main_resize(self, event: object) -> None:
        main_width = int(getattr(event, "width", 720))
        self._layout_action_bar(main_width)
        width = max(420, main_width - 68)
        header_text_width = max(260, main_width - 220)
        self.title_label.configure(wraplength=header_text_width)
        self.subtitle_label.configure(wraplength=header_text_width)
        self.notice_label.configure(wraplength=width)
        # Keep complete URLs and profile names readable. Two detail pairs are
        # only useful once both value columns have a genuinely wide viewport.
        detail_columns = 2 if main_width >= 720 else 1
        if detail_columns != self._detail_columns:
            self._detail_columns = detail_columns
            if self.state:
                self.root.after_idle(self._render)
        detail_value_width = self._detail_value_wraplength(main_width, detail_columns)
        for label in getattr(self, "_detail_value_labels", []):
            label.configure(wraplength=detail_value_width)

    def _layout_action_bar(self, main_width: int) -> None:
        """Keep every bottom-bar button fully visible: one right-aligned row when
        it fits, otherwise two right-aligned rows. The apply button stays last."""

        available = max(0, int(main_width) - 56)
        try:
            widths = [int(button.winfo_reqwidth()) for button in self._action_buttons]
        except tk.TclError:
            return
        single_row_width = sum(widths) + 8 * max(0, len(widths) - 1)
        rows = 1 if single_row_width <= available else 2
        if rows == self._action_rows:
            return
        self._action_rows = rows
        for column in range(7):
            self.action_frame.columnconfigure(column, weight=1 if column == 0 else 0)
        for index, button in enumerate(self._action_buttons):
            if rows == 1:
                button.grid(row=0, column=index + 1, sticky="e", padx=(8, 0))
            elif index < 3:
                button.grid(row=0, column=index + 1, sticky="e", padx=(8, 0))
            else:
                button.grid(row=1, column=index - 2, sticky="e", padx=(8, 0), pady=(8, 0))

    def _detail_value_wraplength(
        self, main_width: int | None = None, detail_columns: int | None = None
    ) -> int:
        """Use the same safe wrap width during initial rendering and resize."""

        if main_width is None:
            try:
                main_width = int(self.main.winfo_width())
            except tk.TclError:
                main_width = 420
        columns = self._detail_columns if detail_columns is None else detail_columns
        content_width = max(420, int(main_width) - 68)
        return max(160, (content_width - (110 * columns)) // columns)

    def _on_content_configure(self, _event: object) -> None:
        self._content_canvas.configure(scrollregion=self._content_canvas.bbox("all"))
        self.root.after_idle(self._sync_content_scrollbar)

    def _on_content_canvas_configure(self, event: object) -> None:
        self._content_canvas.itemconfigure(self._content_window, width=int(getattr(event, "width", 1)))
        self.root.after_idle(self._sync_content_scrollbar)

    def _scroll_content(self, units: int) -> str:
        self._content_canvas.yview_scroll(units, "units")
        return "break"

    def _on_content_mousewheel(self, event: object) -> str | None:
        delta = int(getattr(event, "delta", 0))
        if not delta:
            return None
        return self._scroll_content(-1 if delta > 0 else 1)

    def refresh(self, select_id: str | None = None) -> None:
        try:
            self.state = self.manager.state()
        except (DesktopAppError, ProfileCatalogError, OSError, RuntimeError) as error:
            self._set_notice(str(error), error=True)
            return
        choices = self.state["choices"]
        wanted = select_id or self.selected_id or self.state.get("selectedId") or "openai"
        self.provider_tree.delete(*self.provider_tree.get_children())
        ids = {str(item["id"]) for item in choices}
        for item in choices:
            # Keep the selectable list readable at narrow window widths. The
            # selected Profile's authentication and enabled state are shown in
            # the fully expanded detail card instead of truncating its name.
            self.provider_tree.insert("", "end", iid=str(item["id"]), text=str(item["name"]))
        self.selected_id = wanted if wanted in ids else "openai"
        self.provider_tree.selection_set(self.selected_id)
        self.provider_tree.focus(self.selected_id)
        self._render()
        self._sync_provider_scrollbar()
        self._content_canvas.yview_moveto(0)
        if not self._initial_window_fitted:
            self.root.after_idle(self._fit_open_window)

    def _sync_provider_scrollbar(self) -> None:
        """Show the provider-list scrollbar only when the fixed list overflows."""

        item_count = len(self.provider_tree.get_children())
        visible_rows = max(1, int(self.provider_tree.cget("height") or 4))
        should_show = item_count > visible_rows
        if should_show:
            self._provider_scrollbar.grid()
        else:
            self._provider_scrollbar.grid_remove()

    def _selected_profile(self) -> dict[str, object] | None:
        return next((item for item in self.state.get("profiles", []) if item["id"] == self.selected_id), None)

    def _selected_choice(self) -> dict[str, object] | None:
        return next((item for item in self.state.get("choices", []) if item["id"] == self.selected_id), None)

    def _sync_tree_selection(self) -> str | None:
        """Read the live native control before an action, not just its last event."""

        selection = self.provider_tree.selection()
        if selection:
            self.selected_id = str(selection[0])
        return self.selected_id

    def _on_select(self) -> None:
        if self._sync_tree_selection():
            self._render()

    def _on_tree_double_click(self, _event: object) -> None:
        self._sync_tree_selection()
        self._open_editor("edit")

    def _render(self) -> None:
        choice, profile = self._selected_choice(), self._selected_profile()
        if choice is None:
            return
        self.title_label.configure(text=str(choice["name"]))
        self.subtitle_label.configure(text="OpenAI 官方登录" if choice.get("kind") == "builtin" else "设置只保存在这台电脑上。")
        active_selected = self.selected_id == self.state.get("selectedId")
        if active_selected:
            self.status_badge.set("当前使用")
            self.status_label.configure(style="KeyStatus.TLabel")
        elif profile is not None and not bool(profile.get("enabled")):
            self.status_badge.set("已停用")
            self.status_label.configure(style="KeyStatusWarning.TLabel")
        else:
            self.status_badge.set("")
        for widget in self.detail_rows.winfo_children():
            widget.destroy()
        self._detail_value_labels: list[object] = []
        rows = [("名称", choice["name"]), ("登录方式", _AUTH_LOGIN_LABEL if choice.get("kind") == "builtin" else _AUTH_KEY_LABEL)]
        if profile:
            rows += [("模型", profile.get("model", "未设置")), ("模型列表", ", ".join(profile.get("models", [])) or "未设置")]
            if profile.get("reasoningEffort"):
                rows.append(("推理强度", profile["reasoningEffort"]))
            if profile.get("reviewModel"):
                rows.append(("审阅模型", profile["reviewModel"]))
            for label, field in (("服务地址", "baseUrl"), ("接口方式", "wireApi"), ("密钥变量名", "apiKeyEnv")):
                if profile.get(field):
                    rows.append((label, profile[field]))
            if profile.get("authMode") == "api_key":
                configured = self.state.get("credentialStatus", {}).get(profile["id"], False)
                rows.append(("访问密钥", "已配置" if configured else "未配置"))
            rows.append(("状态", "已启用" if profile.get("enabled") else "已停用"))
        connection = self.state.get("connection", {})
        if not isinstance(connection, dict):
            connection = {}
        if connection.get("provider"):
            rows.append(("当前服务", connection.get("provider", "未读取")))
        if connection.get("model"):
            rows.append(("当前模型", connection.get("model", "未读取")))
        if connection.get("base_url"):
            rows.append(("服务地址", connection.get("base_url")))
        if connection.get("wire_api"):
            rows.append(("接口方式", connection.get("wire_api")))
        detail_columns = self._detail_columns
        detail_value_width = self._detail_value_wraplength()
        for column in range(detail_columns * 2):
            self.detail_rows.columnconfigure(column, weight=1 if column % 2 else 0)
        for index, (label, value) in enumerate(rows):
            row, pair = divmod(index, detail_columns)
            label_column = pair * 2
            value_column = label_column + 1
            ttk.Label(self.detail_rows, text=str(label), style="FieldLabel.TLabel").grid(
                row=row, column=label_column, sticky="nw", padx=(0, 8), pady=2
            )
            value_label = ttk.Label(
                self.detail_rows,
                text=str(value),
                style="Value.TLabel",
                justify="left",
                wraplength=detail_value_width,
            )
            value_label.grid(
                row=row, column=value_column, sticky="ew", padx=(0, 16 if pair < detail_columns - 1 else 0), pady=2
            )
            self._detail_value_labels.append(value_label)
        diagnostics = self.state.get("diagnostics", {})
        if not isinstance(diagnostics, dict):
            diagnostics = {}
        for widget in self.diagnostics.winfo_children():
            widget.destroy()
        thread_count = diagnostics.get("thread_count", "不可用")
        skill_count = diagnostics.get("skill_count", "不可用")
        mcp_count = diagnostics.get("mcp_server_count", "不可用")
        backup = "可用" if self.state.get("latestBackup") else "未检测到"
        metrics = [
            ("会话历史", f"{thread_count} 个会话" if isinstance(thread_count, int) else "不可用"),
            ("工具和扩展", f"技能 {skill_count} · 工具服务 {mcp_count}"),
            ("最近备份", backup),
        ]
        for column in range(3):
            self.diagnostics.columnconfigure(column, weight=1)
        for column, (label, value) in enumerate(metrics):
            metric = ttk.Frame(self.diagnostics, style="Metric.TFrame", padding=(0, 4))
            metric.grid(row=0, column=column, sticky="ew", padx=(0 if column == 0 else 16, 0), pady=2)
            ttk.Label(metric, text=label, style="FieldLabel.TLabel").grid(row=0, column=0, sticky="w")
            ttk.Label(metric, text=str(value), style="Value.TLabel").grid(row=1, column=0, sticky="w", pady=(2, 0))
        custom = profile is not None
        active = custom and self.selected_id == self.state.get("selectedId")
        self.edit_button.configure(state="normal" if custom else "disabled")
        self.delete_button.configure(state="normal" if custom and not active else "disabled")
        self.toggle_button.configure(state="normal" if custom and not (profile.get("enabled") and active) else "disabled")
        self.toggle_button.configure(text="停用" if profile and profile.get("enabled") else "启用")
        enabled = bool(choice.get("enabled"))
        self.check_button.configure(state="normal" if enabled else "disabled")
        self.switch_button.configure(state="normal" if enabled else "disabled")
        _bind_context_menus(self.root)

    def _set_notice(self, message: str, *, error: bool = False) -> None:
        self.notice.set(("错误：" if error else "") + message)
        self.notice_label.configure(style="ErrorBar.TLabel" if error else "InfoBar.TLabel")

    def _open_editor(self, mode: str) -> None:
        profile = self._selected_profile()
        if mode != "new" and profile is None:
            return
        if profile is not None:
            try:
                profile = self.manager.profile_for_edit(str(profile["id"]))
            except (DesktopAppError, ProfileCatalogError, OSError, RuntimeError) as error:
                self._set_notice(str(error), error=True)
                return
        ProfileDialog(self, mode, profile)

    def _toggle(self) -> None:
        profile = self._selected_profile()
        if not profile:
            return
        try:
            self.manager.toggle(str(profile["id"]), not bool(profile["enabled"]))
            self.refresh(str(profile["id"]))
        except (DesktopAppError, ProfileCatalogError, OSError, RuntimeError) as error:
            self._set_notice(str(error), error=True)

    def _delete(self) -> None:
        profile = self._selected_profile()
        if not profile or not _askyesno(self.root, "删除服务", f"确定删除“{profile['name']}”？\n不会删除已保存的访问密钥。"):
            return
        try:
            self.manager.remove(str(profile["id"]))
            self.refresh("openai")
        except (DesktopAppError, ProfileCatalogError, OSError, RuntimeError) as error:
            self._set_notice(str(error), error=True)

    def _on_tree_menu(self, event: object) -> None:
        """Family-aligned Provider context menu: copy, duplicate, export, paste."""

        try:
            row = self.provider_tree.identify_row(int(event.y))
            if row:
                self.provider_tree.selection_set(row)
                self._sync_tree_selection()
        except tk.TclError:
            pass
        profile = self._selected_profile()
        menu = tk.Menu(self.provider_tree, tearoff=0)
        menu.add_command(
            label="编辑服务",
            command=lambda: self._open_editor("edit"),
            state="normal" if profile else "disabled",
        )
        menu.add_command(
            label="复制到剪贴板",
            command=self._copy_profile_json,
            state="normal" if profile else "disabled",
        )
        menu.add_command(
            label="复制服务",
            command=lambda: self._open_editor("copy"),
            state="normal" if profile else "disabled",
        )
        menu.add_command(
            label="导出服务",
            command=self._export,
            state="normal" if profile else "disabled",
        )
        menu.add_separator()
        menu.add_command(label="粘贴服务", command=self._paste)
        try:
            menu.tk_popup(int(event.x_root), int(event.y_root))
        finally:
            menu.grab_release()

    def _on_add_provider_menu(self, event: object) -> None:
        menu = tk.Menu(self.root, tearoff=0)
        menu.add_command(label="导入服务", command=self._import)
        menu.add_command(label="粘贴服务", command=self._paste)
        try:
            menu.tk_popup(int(event.x_root), int(event.y_root))
        finally:
            menu.grab_release()

    def _copy_profile_json(self) -> None:
        profile = self._selected_profile()
        if not profile:
            return
        payload = self.manager.export_profile(str(profile["id"]))
        _clipboard_copy(self.provider_tree, json.dumps(payload, ensure_ascii=False, indent=2))
        self._set_notice("服务已复制到剪贴板（不包含访问密钥）。")

    def _paste(self) -> None:
        try:
            value = self.root.clipboard_get()
        except tk.TclError:
            self._set_notice("剪贴板中没有可导入的服务信息。", error=True)
            return
        try:
            payload = json.loads(value)
            imported = self.manager.import_profiles(payload)
            self.refresh(imported[0])
            self._set_notice("服务已粘贴（不包含访问密钥）。")
        except (DesktopAppError, ProfileCatalogError, json.JSONDecodeError) as error:
            self._set_notice(f"粘贴失败：{error}", error=True)

    def _import(self) -> None:
        path = filedialog.askopenfilename(parent=self.root, title="导入服务", filetypes=[("服务设置", "*.json"), ("所有文件", "*.*")])
        if not path:
            return
        try:
            imported = self.manager.import_profiles(json.loads(Path(path).read_text(encoding="utf-8")))
            self.refresh(imported[0])
            self._set_notice("服务已导入。")
        except (DesktopAppError, ProfileCatalogError, OSError, RuntimeError, json.JSONDecodeError) as error:
            self._set_notice(str(error), error=True)

    def _export(self) -> None:
        profile = self._selected_profile()
        if not profile:
            return
        path = filedialog.asksaveasfilename(parent=self.root, title="导出服务", defaultextension=".json", initialfile=f"{profile['name']}.lansi-profile.json", filetypes=[("服务设置", "*.json")])
        if not path:
            return
        try:
            Path(path).write_text(json.dumps(self.manager.export_profile(str(profile["id"])), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            self._set_notice("服务已导出（不包含访问密钥）。")
        except (DesktopAppError, OSError) as error:
            self._set_notice(str(error), error=True)

    def _check(self) -> None:
        self._sync_tree_selection()
        if not self.selected_id:
            return
        try:
            self.manager.check(self.selected_id)
            self._set_notice("检查通过，可以安全启用。")
        except (DesktopAppError, ProfileCatalogError, OSError, RuntimeError, ValueError) as error:
            self._set_notice(str(error), error=True)

    def _switch(self) -> None:
        self._sync_tree_selection()
        choice = self._selected_choice()
        if not choice or not _askyesno(
            self.root,
            "应用设置并重启 ChatGPT",
            f"确认启用“{choice['name']}”？\n继续前会自动备份你的设置和会话。\n\n已有任务保持原样；重启后请新建任务确认服务和模型。",
        ):
            return
        self._switch_selected(str(choice["id"]), offer_graceful_close=True)

    def _switch_selected(self, provider_id: str, *, offer_graceful_close: bool) -> None:
        try:
            self.switch_button.configure(state="disabled")

            def on_phase(_phase: str, message: str) -> None:
                self._set_notice(message)
                self.root.update_idletasks()

            result = self.manager.switch(provider_id, phase_callback=on_phase)
            if not result.get("verified_config"):
                raise DesktopAppError("操作完成，但设置校验未通过。")
            self.refresh(provider_id)
            routing = result.get("thread_routing")
            preserved = routing.get("other_count") if isinstance(routing, dict) else None
            message = "默认服务已启用，访问密钥、设置和 Codex 重启均已验证。已有任务保持原样。"
            if result.get("old_api_key_cleared"):
                message += " 上一个服务的访问密钥已清除。"
            if isinstance(preserved, int) and preserved:
                message += f" 当前有 {preserved} 个已有任务保持原服务。"
            self._set_notice(message)
        except CodexRunningError as error:
            if offer_graceful_close and _askyesno(
                self.root,
                "ChatGPT 正在运行",
                f"{error}\n\n是否先正常关闭 ChatGPT，再继续操作？\n不会强制结束进程。",
            ):
                self._set_notice("正在请求 ChatGPT 正常关闭；关闭后继续操作。")
                self.root.update_idletasks()

                def wait_tick(elapsed_seconds: float) -> None:
                    self._set_notice(f"正在等待 Codex 关闭（已等待 {int(elapsed_seconds)} 秒）…")
                    self.root.update()

                self.switch_button.configure(state="disabled")
                try:
                    self.manager.request_codex_graceful_shutdown(tick=wait_tick)
                except (DesktopAppError, OSError, RuntimeError) as close_error:
                    self._set_notice(str(close_error), error=True)
                    return
                finally:
                    self.switch_button.configure(state="normal")
                self._switch_selected(provider_id, offer_graceful_close=False)
                return
            self._set_notice(str(error), error=True)
        except (DesktopAppError, ProfileCatalogError, OSError, RuntimeError, ValueError) as error:
            self._set_notice(str(error), error=True)
        finally:
            self.switch_button.configure(state="normal")

    def _restore(self) -> None:
        if not _askyesno(self.root, "恢复最近备份", "确认恢复最近一次操作前的设置和会话？"):
            return
        try:
            self.manager.restore()
            self.refresh()
            self._set_notice("已恢复最近备份。")
        except (DesktopAppError, OSError, RuntimeError) as error:
            self._set_notice(str(error), error=True)

    def _backup_management(self) -> None:
        backup_dir = self.manager.codex_home / "backups" / "windows-provider-switch"
        window = tk.Toplevel(self.root)
        window.title("备份管理")
        window.configure(background=_COLORS["window"])
        window.transient(self.root)
        window.minsize(520, 320)

        header = ttk.Frame(window, style="App.TFrame")
        header.pack(fill="x", padx=14, pady=(12, 6))
        ttk.Label(header, text="备份管理", style="Title.TLabel").pack(side="left")

        body = ttk.Frame(window, style="App.TFrame")
        body.pack(fill="both", expand=True, padx=14, pady=6)
        rows = list_backups(backup_dir)
        if not rows:
            ttk.Label(body, text="暂无备份", style="Subtle.TLabel").pack(anchor="w")
        else:
            total_bytes = sum(int(row["bytes"]) for row in rows)
            summary = f"{len(rows)} 份备份 · {_format_bytes(total_bytes)}"
            ttk.Label(body, text=summary, style="FieldLabel.TLabel").pack(anchor="w", pady=(0, 6))
            frame = ttk.Frame(body, style="Card.TFrame", padding=8)
            frame.pack(fill="both", expand=True)
            for row in rows:
                created = row["created"] or row["timestamp"]
                line = f"{created}  ·  {_format_bytes(int(row['bytes']))}"
                ttk.Label(frame, text=line, style="Value.TLabel").pack(anchor="w", pady=1)

        actions = ttk.Frame(window, style="App.TFrame")
        actions.pack(fill="x", padx=14, pady=(6, 12))
        ttk.Button(actions, text="清理旧备份", command=lambda: self._prune_backup_dialog(backup_dir, window)).pack(side="left")
        ttk.Button(actions, text="关闭", command=window.destroy).pack(side="right")
        _center_toplevel(window, self.root)

    def _prune_backup_dialog(self, backup_dir: Path, window: object) -> None:
        if not _askyesno(self.root, "清理旧备份", "按保留策略删除过期与超量备份？最近备份会保留。"):
            return
        try:
            removed = _prune_backups(backup_dir)
            window.destroy()
            self.refresh()
            self._set_notice(f"已清理 {removed} 组旧备份。")
        except (DesktopAppError, OSError, RuntimeError) as error:
            self._set_notice(str(error), error=True)


class ProfileDialog:
    def __init__(self, app: ProviderDesktopApp, mode: str, source: dict[str, object] | None):
        self.app, self.mode, self.source = app, mode, source or {}
        self.window = tk.Toplevel(app.root)
        self.window.title({"new": "添加服务", "edit": "编辑服务", "copy": "复制服务"}[mode])
        self.window.transient(app.root)
        self.window.grab_set()
        self.window.configure(background=_COLORS["window"])
        _apply_window_icon(self.window)
        self.window.geometry("800x720")
        self.window.minsize(600, 520)
        self.window.resizable(True, True)
        self.window.rowconfigure(0, weight=1)
        self.window.columnconfigure(0, weight=1)
        self._initial_dialog_fitted = False
        self._form_scrollbar_visible = True
        shell = ttk.Frame(self.window, style="App.TFrame", padding=(24, 20, 24, 18))
        shell.grid(row=0, column=0, sticky="nsew")
        shell.rowconfigure(0, weight=1)
        shell.columnconfigure(0, weight=1)

        self._form_canvas = tk.Canvas(
            shell,
            background=_COLORS["window"],
            borderwidth=0,
            highlightthickness=0,
        )
        self._form_canvas.grid(row=0, column=0, sticky="nsew")
        self._form_scrollbar = ttk.Scrollbar(
            shell, orient="vertical", command=self._form_canvas.yview
        )
        self._form_scrollbar.grid(row=0, column=1, sticky="ns", padx=(10, 0))
        self._form_canvas.configure(yscrollcommand=self._form_scrollbar.set)
        self.form = ttk.Frame(self._form_canvas, style="App.TFrame", padding=(0, 0, 8, 0))
        self._form_window = self._form_canvas.create_window((0, 0), window=self.form, anchor="nw")
        self.form.bind("<Configure>", self._on_form_configure)
        self._form_canvas.bind("<Configure>", self._on_canvas_configure)
        self.values: dict[str, object] = {}
        self._field_variables: dict[str, tk.StringVar] = {}
        self._managed_models = self._unique_models(self.source.get("models", []))
        self._upstream_models: list[str] = []
        self._managed_visible: list[str] = []
        self._upstream_visible: list[str] = []
        self._model_search = tk.StringVar()
        self._model_draft = tk.StringVar()
        self._model_fetch_cancel: threading.Event | None = None
        self._model_fetch_queue: queue.Queue[tuple[str, object]] | None = None
        self._is_fetching_models = False
        name = f"{self.source.get('name', '')} 副本" if mode == "copy" else self.source.get("name", "")
        self._field(self.form, "名称", "name", name)
        self.auth = tk.StringVar(value=_AUTH_KEY_LABEL if self.source.get("authMode", "api_key") == "api_key" else _AUTH_LOGIN_LABEL)
        ttk.Label(self.form, text="登录方式", style="DialogField.TLabel").grid(row=1, column=0, sticky="w", pady=6)
        auth_box = ttk.Combobox(self.form, textvariable=self.auth, state="readonly", values=(_AUTH_KEY_LABEL, _AUTH_LOGIN_LABEL), style="Field.TCombobox")
        auth_box.grid(row=1, column=1, sticky="ew", padx=(18, 0), pady=6)
        auth_box.bind("<<ComboboxSelected>>", lambda _event: self._sync_auth())
        self._model_field(self.form, self.source.get("model", ""), row=2)
        self._model_catalog_field(self.form, row=3)
        self._field(self.form, "服务地址", "baseUrl", self.source.get("baseUrl", ""), row=4)
        self._field(self.form, "接口方式", "wireApi", self.source.get("wireApi", "responses"), row=5, readonly=True)
        self._field(self.form, "密钥变量名", "apiKeyEnv", self.source.get("apiKeyEnv", ""), row=6)
        self._api_key_field(self.form, row=7)
        self._reasoning_field(self.form, self.source.get("reasoningEffort", ""), row=9)
        self._field(self.form, "审阅模型（可选）", "reviewModel", self.source.get("reviewModel", ""), row=10)
        self.form.columnconfigure(1, weight=1)
        self._field_variables["apiKeyEnv"].trace_add("write", lambda *_args: self._refresh_api_key_status())
        self._field_variables["apiKey"].trace_add("write", lambda *_args: self._refresh_api_key_status())

        buttons = ttk.Frame(shell, style="App.TFrame")
        buttons.grid(row=1, column=0, columnspan=2, sticky="ew", pady=(16, 0))
        for column in range(4):
            buttons.columnconfigure(column, weight=1)
        self.fetch_models_button = WindowsButton(buttons, "获取可用模型", self._fetch_models)
        self.fetch_models_button.grid(row=0, column=0, sticky="ew", padx=(0, 8))
        self.cancel_fetch_button = ttk.Button(buttons, text="取消获取", command=self._cancel_model_fetch, state="disabled")
        self.cancel_fetch_button.grid(row=0, column=1, sticky="ew", padx=(0, 8))
        WindowsButton(buttons, "取消", self.window.destroy).grid(row=0, column=2, sticky="ew", padx=(0, 8))
        WindowsButton(buttons, "保存服务", self._save, kind="primary").grid(row=0, column=3, sticky="ew")
        self._sync_auth()
        self._refresh_model_choices()
        self._refresh_model_catalog_views()
        self._sync_reasoning_choices()
        self._refresh_api_key_status()
        _bind_context_menus(self.window)
        self.window.after_idle(self._fit_open_dialog)
        self.window.bind("<Escape>", lambda _event: self.window.destroy())
        self.window.bind("<Control-s>", lambda _event: self._save())
        self.window.bind("<Control-Return>", lambda _event: self._save())
        self.window.bind("<MouseWheel>", self._on_mousewheel, add="+")
        self.window.bind("<Button-4>", lambda _event: self._scroll_form(-1), add="+")
        self.window.bind("<Button-5>", lambda _event: self._scroll_form(1), add="+")
        self.values["name"].focus_set()

    def _fit_open_dialog(self) -> None:
        """Prefer a full editor on open, with scrolling only on smaller displays."""

        if self._initial_dialog_fitted:
            return
        try:
            self.window.update_idletasks()
            usable_width = max(1, int(self.window.winfo_screenwidth()) - 48)
            usable_height = max(1, int(self.window.winfo_screenheight()) - 72)
            minimum_width = min(600, usable_width)
            minimum_height = min(520, usable_height)
            target_width = max(minimum_width, min(800, usable_width))
            self.window.geometry(f"{target_width}x{min(usable_height, max(minimum_height, self.window.winfo_height()))}")
            self.window.update_idletasks()
            non_form_height = max(0, self.window.winfo_height() - self._form_canvas.winfo_height())
            target_height = min(usable_height, max(minimum_height, self.form.winfo_reqheight() + non_form_height + 8))
            self.window.geometry(f"{target_width}x{target_height}")
            self._initial_dialog_fitted = True
            self.window.after_idle(self._sync_form_scrollbar)
        except tk.TclError:
            return

    def _sync_form_scrollbar(self) -> None:
        """Keep the editor form completely visible whenever the display allows it."""

        form_height = max(self.form.winfo_reqheight(), self.form.winfo_height())
        viewport_height = max(1, self._form_canvas.winfo_height())
        should_show = form_height > viewport_height + 1
        if should_show == self._form_scrollbar_visible:
            return
        self._form_scrollbar_visible = should_show
        if should_show:
            self._form_scrollbar.grid()
        else:
            self._form_scrollbar.grid_remove()

    def _on_form_configure(self, _event: object) -> None:
        self._form_canvas.configure(scrollregion=self._form_canvas.bbox("all"))
        self.window.after_idle(self._sync_form_scrollbar)

    def _on_canvas_configure(self, event: object) -> None:
        self._form_canvas.itemconfigure(self._form_window, width=int(getattr(event, "width", 1)))
        self.window.after_idle(self._sync_form_scrollbar)

    def _scroll_form(self, units: int) -> str:
        self._form_canvas.yview_scroll(units, "units")
        return "break"

    def _on_mousewheel(self, event: object) -> str | None:
        delta = int(getattr(event, "delta", 0))
        if not delta:
            return None
        return self._scroll_form(-1 if delta > 0 else 1)

    def _field(self, frame: object, label: str, name: str, value: object, *, row: int | None = None, secret: bool = False, readonly: bool = False) -> None:
        actual_row = row if row is not None else 0
        ttk.Label(frame, text=label, style="DialogField.TLabel").grid(row=actual_row, column=0, sticky="w", pady=6)
        variable = tk.StringVar(value=str(value))
        entry = ttk.Entry(frame, textvariable=variable, show="•" if secret else "", style="Field.TEntry")
        if readonly:
            entry.state(["readonly"])
        entry.grid(row=actual_row, column=1, sticky="ew", padx=(18, 0), pady=6)
        self.values[name] = entry
        self._field_variables[name] = variable

    def _api_key_field(self, frame: object, *, row: int) -> None:
        ttk.Label(frame, text="访问密钥（不会显示）", style="DialogField.TLabel").grid(row=row, column=0, sticky="w", pady=6)
        variable = tk.StringVar(value="")
        entry = ttk.Entry(frame, textvariable=variable, show="•", style="Field.TEntry")
        entry.grid(row=row, column=1, sticky="ew", padx=(18, 0), pady=6)
        self.values["apiKey"] = entry
        self._field_variables["apiKey"] = variable
        self.api_key_status = tk.StringVar(value="")
        self.api_key_status_label = ttk.Label(frame, textvariable=self.api_key_status, style="KeyStatus.TLabel")
        self.api_key_status_label.grid(row=row + 1, column=1, sticky="w", padx=(18, 0), pady=(0, 6))

    def _model_field(self, frame: object, value: object, *, row: int) -> None:
        ttk.Label(frame, text="模型", style="DialogField.TLabel").grid(row=row, column=0, sticky="w", pady=6)
        variable = tk.StringVar(value=str(value))
        selector = ttk.Combobox(
            frame,
            textvariable=variable,
            values=tuple(self.source.get("models", [])),
            state="normal",
            style="Field.TCombobox",
        )
        selector.grid(row=row, column=1, sticky="ew", padx=(18, 0), pady=6)
        selector.bind("<<ComboboxSelected>>", lambda _event: self._sync_reasoning_choices())
        selector.bind("<FocusOut>", lambda _event: self._sync_reasoning_choices())
        self.values["model"] = selector
        self._field_variables["model"] = variable

    @staticmethod
    def _unique_models(values: object) -> list[str]:
        if not isinstance(values, (list, tuple)):
            return []
        result: list[str] = []
        seen: set[str] = set()
        for value in values:
            if not isinstance(value, str):
                continue
            model = value.strip()
            if model and model not in seen:
                seen.add(model)
                result.append(model)
        return result

    @staticmethod
    def _split_model_names(value: str) -> list[str]:
        return [
            item.strip()
            for item in value.replace(";", ",").replace("\n", ",").split(",")
            if item.strip()
        ]

    def _model_catalog_field(self, frame: object, *, row: int) -> None:
        ttk.Label(frame, text="模型", style="DialogField.TLabel").grid(row=row, column=0, sticky="nw", pady=6)
        catalog = ttk.Frame(frame, style="Card.TFrame", padding=10)
        catalog.grid(row=row, column=1, sticky="ew", padx=(18, 0), pady=6)
        catalog.columnconfigure(0, weight=1)
        catalog.columnconfigure(1, weight=1)
        ttk.Label(
            catalog,
            text=f"最多可保留 {MAX_MANAGED_MODELS} 个模型；获取结果需由你确认添加。",
            style="Subtle.TLabel",
        ).grid(row=0, column=0, columnspan=2, sticky="w")
        manual = ttk.Frame(catalog, style="Card.TFrame")
        manual.grid(row=1, column=0, columnspan=2, sticky="ew", pady=(8, 4))
        manual.columnconfigure(0, weight=1)
        ttk.Entry(manual, textvariable=self._model_draft, style="Field.TEntry").grid(row=0, column=0, sticky="ew")
        ttk.Button(manual, text="添加模型", command=self._add_manual_models).grid(row=0, column=1, padx=(8, 0))
        search = ttk.Frame(catalog, style="Card.TFrame")
        search.grid(row=2, column=0, columnspan=2, sticky="ew", pady=(0, 8))
        search.columnconfigure(1, weight=1)
        ttk.Label(search, text="搜索", style="Subtle.TLabel").grid(row=0, column=0, sticky="w", padx=(0, 8))
        ttk.Entry(search, textvariable=self._model_search, style="Field.TEntry").grid(row=0, column=1, sticky="ew")
        self._model_search.trace_add("write", lambda *_args: self._refresh_model_catalog_views())

        managed = ttk.LabelFrame(catalog, text="已选模型", padding=8)
        managed.grid(row=3, column=0, sticky="nsew", padx=(0, 5))
        managed.columnconfigure(0, weight=1)
        self._managed_model_list = tk.Listbox(
            managed, height=7, exportselection=False, selectmode=tk.EXTENDED
        )
        self._managed_model_list.grid(row=0, column=0, sticky="nsew")
        managed_actions = ttk.Frame(managed)
        managed_actions.grid(row=1, column=0, sticky="ew", pady=(6, 0))
        ttk.Button(managed_actions, text="全选", command=self._select_all_managed).pack(side="left")
        ttk.Button(managed_actions, text="移除选中", command=self._remove_selected_managed).pack(side="left", padx=5)
        ttk.Button(managed_actions, text="清空", command=self._clear_managed).pack(side="right")

        upstream = ttk.LabelFrame(catalog, text="可用模型", padding=8)
        upstream.grid(row=3, column=1, sticky="nsew", padx=(5, 0))
        upstream.columnconfigure(0, weight=1)
        self._upstream_model_list = tk.Listbox(
            upstream, height=7, exportselection=False, selectmode=tk.EXTENDED
        )
        self._upstream_model_list.grid(row=0, column=0, sticky="nsew")
        upstream_actions = ttk.Frame(upstream)
        upstream_actions.grid(row=1, column=0, sticky="ew", pady=(6, 0))
        ttk.Button(upstream_actions, text="添加选中", command=self._add_selected_upstream).pack(side="left")
        ttk.Button(upstream_actions, text="全部添加", command=self._add_all_upstream).pack(side="left", padx=5)
        ttk.Button(upstream_actions, text="忽略", command=self._ignore_upstream).pack(side="right")

    def _refresh_model_choices(self) -> list[str]:
        current_model = self._field_variables["model"].get().strip()
        models = self._unique_models([current_model, *self._managed_models])
        self.values["model"].configure(values=models)
        self._sync_reasoning_choices()
        return models

    def _refresh_model_catalog_views(self) -> None:
        query = self._model_search.get().strip().casefold()
        self._managed_visible = [model for model in self._managed_models if query in model.casefold()]
        self._upstream_visible = [model for model in self._upstream_models if query in model.casefold()]
        self._managed_model_list.delete(0, "end")
        self._upstream_model_list.delete(0, "end")
        for model in self._managed_visible:
            self._managed_model_list.insert("end", model)
        for model in self._upstream_visible:
            self._upstream_model_list.insert("end", model)

    def _add_models_to_managed(self, candidates: list[str]) -> tuple[int, int]:
        previous_models = list(self._managed_models)
        added = 0
        existing = set(self._managed_models)
        for model in self._unique_models(candidates):
            if model in existing:
                continue
            if len(self._managed_models) >= MAX_MANAGED_MODELS:
                break
            self._managed_models.append(model)
            existing.add(model)
            added += 1
        skipped = len(self._unique_models(candidates)) - added
        if added and not self._persist_managed_models():
            self._managed_models = previous_models
            self._refresh_model_choices()
            self._refresh_model_catalog_views()
            return 0, len(self._unique_models(candidates))
        self._refresh_model_choices()
        self._refresh_model_catalog_views()
        return added, skipped

    def _persist_managed_models(self) -> bool:
        if self.mode != "edit" or not self.source.get("id"):
            return True
        profile = dict(self.source)
        profile["model"] = self._field_variables["model"].get().strip() or profile.get("model")
        profile["models"] = list(self._managed_models)
        try:
            self.source = self.app.manager.upsert(profile)
            return True
        except (DesktopAppError, ProfileCatalogError, OSError, RuntimeError, ValueError) as error:
            _showerror(self.window, "保存模型列表失败", str(error))
            return False

    def _add_manual_models(self) -> None:
        candidates = self._split_model_names(self._model_draft.get())
        if not candidates:
            return
        added, skipped = self._add_models_to_managed(candidates)
        self._model_draft.set("")
        if skipped:
            self.app._set_notice(f"已添加 {added} 个模型；其余已存在或超过 {MAX_MANAGED_MODELS} 项上限。")
        else:
            self.app._set_notice(f"已添加 {added} 个模型到已选模型。")

    def _selected_models(self, widget: object, visible: list[str]) -> list[str]:
        return [visible[index] for index in widget.curselection() if index < len(visible)]

    def _select_all_managed(self) -> None:
        if self._managed_visible:
            self._managed_model_list.selection_set(0, "end")

    def _remove_selected_managed(self) -> None:
        selected = set(self._selected_models(self._managed_model_list, self._managed_visible))
        if not selected:
            return
        previous_models = list(self._managed_models)
        previous_model = self._field_variables["model"].get()
        self._managed_models = [model for model in self._managed_models if model not in selected]
        current_model = self._field_variables["model"].get().strip()
        if current_model in selected and self._managed_models:
            self._field_variables["model"].set(self._managed_models[0])
        if not self._persist_managed_models():
            self._managed_models = previous_models
            self._field_variables["model"].set(previous_model)
            self._refresh_model_choices()
            self._refresh_model_catalog_views()
            return
        self._refresh_model_choices()
        self._refresh_model_catalog_views()
        self.app._set_notice("已移除选中的模型；当前模型保持不变。")

    def _clear_managed(self) -> None:
        if not self._managed_models:
            return
        if not _askyesno(self.window, "清空已选模型", "确认清空已选模型？当前模型会保持不变。"):
            return
        previous_models = list(self._managed_models)
        self._managed_models = []
        if not self._persist_managed_models():
            self._managed_models = previous_models
            self._refresh_model_choices()
            self._refresh_model_catalog_views()
            return
        self._refresh_model_choices()
        self._refresh_model_catalog_views()
        self.app._set_notice("已清空已选模型；当前模型保持不变。")

    def _add_selected_upstream(self) -> None:
        selected = self._selected_models(self._upstream_model_list, self._upstream_visible)
        if not selected:
            return
        added, skipped = self._add_models_to_managed(selected)
        if skipped:
            self.app._set_notice(f"已添加 {added} 个可用模型；其余已存在或超过 {MAX_MANAGED_MODELS} 项上限。")
        else:
            self.app._set_notice(f"已添加 {added} 个可用模型到已选模型。")

    def _add_all_upstream(self) -> None:
        if not self._upstream_models:
            return
        added, skipped = self._add_models_to_managed(self._upstream_models)
        if skipped:
            self.app._set_notice(f"已添加 {added} 个可用模型；其余已存在或超过 {MAX_MANAGED_MODELS} 项上限。")
        else:
            self.app._set_notice(f"已将 {added} 个可用模型添加到已选模型。")

    def _ignore_upstream(self) -> None:
        self._upstream_models = []
        self._refresh_model_catalog_views()
        self.app._set_notice("已忽略本次获取结果；服务尚未保存。")

    def _reasoning_field(self, frame: object, value: object, *, row: int) -> None:
        ttk.Label(frame, text="推理强度", style="DialogField.TLabel").grid(row=row, column=0, sticky="w", pady=6)
        initial = str(value) if value else _REASONING_DEFAULT_LABEL
        variable = tk.StringVar(value=initial)
        selector = ttk.Combobox(frame, textvariable=variable, state="readonly", style="Field.TCombobox")
        selector.grid(row=row, column=1, sticky="ew", padx=(18, 0), pady=6)
        self.values["reasoningEffort"] = selector
        self._field_variables["reasoningEffort"] = variable

    def _sync_reasoning_choices(self) -> tuple[str, ...]:
        model_variable = self._field_variables.get("model")
        selected_model = model_variable.get().strip() if model_variable is not None else ""
        choices = codex_reasoning_efforts(selected_model)
        current = self.values["reasoningEffort"].get()
        options = [_REASONING_DEFAULT_LABEL, *choices]
        if current and current not in options:
            options.append(current)
        self.values["reasoningEffort"].configure(values=options)
        if not current:
            self._field_variables["reasoningEffort"].set(_REASONING_DEFAULT_LABEL)
        return choices

    def _sync_auth(self) -> None:
        api_mode = self.auth.get() == _AUTH_KEY_LABEL
        for name in ("baseUrl", "wireApi", "apiKeyEnv", "apiKey"):
            widget = self.values[name]
            widget.state(["!disabled"] if api_mode else ["disabled"])
        if not api_mode:
            self.values["apiKey"].delete(0, "end")
        self._refresh_api_key_status()

    def _refresh_api_key_status(self) -> None:
        """Show credential presence while keeping the key value unreadable."""

        if self.auth.get() != _AUTH_KEY_LABEL:
            self.api_key_status.set("当前登录方式不需要访问密钥。")
            self.api_key_status_label.configure(style="KeyStatus.TLabel")
            return
        environment = self.values["apiKeyEnv"].get().strip()
        pending_key = bool(self.values["apiKey"].get())
        if pending_key and environment:
            self.api_key_status.set(f"已输入新的访问密钥；保存后写入 {environment}。")
            self.api_key_status_label.configure(style="KeyStatus.TLabel")
        elif pending_key:
            self.api_key_status.set("已输入新的访问密钥；请同时填写密钥变量名。")
            self.api_key_status_label.configure(style="KeyStatusWarning.TLabel")
        elif environment and _has_configured_user_environment_key(environment):
            self.api_key_status.set(f"已配置：{environment}（留空会保留现有值）。")
            self.api_key_status_label.configure(style="KeyStatus.TLabel")
        elif environment:
            self.api_key_status.set(f"未配置：{environment}。填写访问密钥后保存。")
            self.api_key_status_label.configure(style="KeyStatusWarning.TLabel")
        else:
            self.api_key_status.set("请填写密钥变量名；访问密钥不会显示或导出。")
            self.api_key_status_label.configure(style="KeyStatusWarning.TLabel")

    def _draft(self) -> dict[str, object]:
        return {
            "id": self.source.get("id") if self.mode == "edit" else None,
            "name": self.values["name"].get(),
            "authMode": "api_key" if self.auth.get() == _AUTH_KEY_LABEL else "chatgpt_login",
            "baseUrl": self.values["baseUrl"].get() or None,
            "wireApi": self.values["wireApi"].get() or None,
            "apiKeyEnv": self.values["apiKeyEnv"].get() or None,
            "model": self.values["model"].get() or None,
            "models": list(self._managed_models),
            "reasoningEffort": (
                None
                if self.values["reasoningEffort"].get() in {"", _REASONING_DEFAULT_LABEL}
                else self.values["reasoningEffort"].get()
            ),
            "reviewModel": self.values["reviewModel"].get() or None,
        }

    def _fetch_models(self) -> None:
        if self._is_fetching_models:
            return
        draft = self._draft()
        if draft["authMode"] != "api_key":
            _showerror(self.window, "无法获取模型", "只有使用访问密钥的服务可以获取可用模型。")
            return
        api_key = self.values["apiKey"].get() or os.environ.get(str(draft["apiKeyEnv"] or ""), "")
        cancel = threading.Event()
        results: queue.Queue[tuple[str, object]] = queue.Queue(maxsize=1)
        self._model_fetch_cancel = cancel
        self._model_fetch_queue = results
        self._is_fetching_models = True
        self.fetch_models_button.configure(state="disabled")
        self.cancel_fetch_button.configure(state="normal")
        self.app._set_notice("正在获取可用模型；可随时取消。")

        def fetch() -> None:
            try:
                models = self.app.manager.fetch_models(str(draft["baseUrl"] or ""), api_key)
                results.put(("models", models))
            except (DesktopAppError, ProfileCatalogError, OSError, RuntimeError, ValueError) as error:
                results.put(("error", error))

        threading.Thread(target=fetch, name="provider-model-fetch", daemon=True).start()
        self.window.after(50, lambda: self._poll_model_fetch(cancel, results))

    def _cancel_model_fetch(self) -> None:
        cancel = self._model_fetch_cancel
        if cancel is None:
            return
        cancel.set()
        self._finish_model_fetch(cancel)
        self.app._set_notice("已取消模型获取；当前上游列表保持不变。")

    def _poll_model_fetch(
        self,
        cancel: threading.Event,
        results: queue.Queue[tuple[str, object]],
    ) -> None:
        if cancel.is_set():
            return
        try:
            kind, payload = results.get_nowait()
        except queue.Empty:
            self.window.after(50, lambda: self._poll_model_fetch(cancel, results))
            return
        if cancel.is_set():
            return
        self._finish_model_fetch(cancel)
        if kind == "models":
            self._upstream_models = self._unique_models(payload)
            self._refresh_model_catalog_views()
            self.app._set_notice(
                f"已获取 {len(self._upstream_models)} 个可用模型；选择后点击“添加选中”。"
            )
            return
        _showerror(self.window, "获取模型失败", str(payload))

    def _finish_model_fetch(self, cancel: threading.Event) -> None:
        if self._model_fetch_cancel is not cancel:
            return
        self._model_fetch_cancel = None
        self._model_fetch_queue = None
        self._is_fetching_models = False
        self.fetch_models_button.configure(state="normal")
        self.cancel_fetch_button.configure(state="disabled")

    def _save(self) -> None:
        try:
            draft = {name: value for name, value in self._draft().items() if value is not None}
            profile = self.app.manager.upsert(draft)
            api_key = self.values["apiKey"].get()
            if api_key:
                self.app.manager.store_key(str(profile["id"]), api_key)
                self.values["apiKey"].delete(0, "end")
            self.app.refresh(str(profile["id"]))
            self.window.destroy()
            self.app._set_notice("服务已保存。")
        except (DesktopAppError, ProfileCatalogError, OSError, RuntimeError, ValueError) as error:
            _showerror(self.window, "保存服务失败", str(error))


def _configure_logging(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(filename=path, level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", encoding="utf-8")


def _parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path)
    parser.add_argument("--codex-home", type=Path)
    parser.add_argument("--debug-log", type=Path)
    parser.add_argument("--isolated-acceptance", action="store_true")
    args = parser.parse_args(argv)
    if args.isolated_acceptance and (args.catalog is None or args.codex_home is None):
        parser.error("--isolated-acceptance requires explicit --catalog and --codex-home paths")
    return args


def main(argv: list[str] | None = None) -> int:
    args = _parse_arguments(argv)
    if args.debug_log:
        _configure_logging(args.debug_log)
    if tk is None:
        raise RuntimeError("Python Tcl/Tk is not installed; rebuild the Windows package with a standard Python 3 installation.")
    _enable_windows_dpi_awareness()
    _set_windows_app_user_model_id()
    root = tk.Tk()
    ProviderDesktopApp(root, DesktopProviderManager(args.catalog or _default_catalog_path(), args.codex_home or _default_codex_home()))
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
