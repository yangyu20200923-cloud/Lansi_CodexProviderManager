#!/usr/bin/env python3
"""Local-browser Windows UI for Lansi Codex Provider Manager.

The server is deliberately standard-library-only. It listens on loopback,
keeps a random write token in memory, and delegates all catalog and switching
work to the existing validated Python core.
"""

from __future__ import annotations

import argparse
import json
import logging
import mimetypes
import os
from pathlib import Path
import secrets
import sys
import threading
import uuid
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

try:
    from profile_catalog import ProfileCatalogError, fetch_models, load_catalog, save_catalog
    from switch_provider import restore_latest, status, switch_custom_profile, switch_provider
except ModuleNotFoundError:  # Supports package-style imports in cross-platform tests.
    from .profile_catalog import ProfileCatalogError, fetch_models, load_catalog, save_catalog
    from .switch_provider import restore_latest, status, switch_custom_profile, switch_provider


_ALLOWED_PROFILE_FIELDS = {
    "id",
    "name",
    "enabled",
    "authMode",
    "baseUrl",
    "wireApi",
    "apiKeyEnv",
    "model",
    "models",
    "reasoningEffort",
    "reviewModel",
    "configOverrides",
}
_BUILTIN_CHOICES = ({
    "id": "openai",
    "name": "OpenAI",
    "kind": "builtin",
    "enabled": True,
    "authMode": "chatgpt_login",
},)
_MAX_API_KEY_LENGTH = 16 * 1024


class WebAppError(ValueError):
    """A safe, user-displayable request error."""


def _default_catalog_path() -> Path:
    appdata = os.environ.get("APPDATA")
    if appdata:
        return Path(appdata) / "Lansi_CodexProviderManager" / "profiles.json"
    return Path.home() / "AppData" / "Roaming" / "Lansi_CodexProviderManager" / "profiles.json"


def _default_codex_home() -> Path:
    return Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))


def _public_profile(profile: dict[str, object]) -> dict[str, object]:
    """Return only non-secret catalog fields, never an apiKey value."""

    return {key: profile[key] for key in _ALLOWED_PROFILE_FIELDS if key in profile}


def _api_key_is_configured(profile: dict[str, object]) -> bool:
    """Expose only whether an API-key environment variable has a value."""

    environment = profile.get("apiKeyEnv")
    return bool(
        profile.get("authMode") == "api_key"
        and isinstance(environment, str)
        and environment
        and os.environ.get(environment)
    )


def _broadcast_windows_environment_change() -> None:
    """Tell newly started Windows processes to refresh their environment settings."""

    if sys.platform != "win32":
        return
    try:
        import ctypes

        result = ctypes.c_ulong()
        user32 = ctypes.windll.user32
        user32.SendMessageTimeoutW(  # type: ignore[attr-defined]
            0xFFFF, 0x001A, 0, "Environment", 0x0002, 5000, ctypes.byref(result)
        )
    except (AttributeError, OSError):
        # Registry persistence is complete even when an unrelated window does not respond.
        return


def _store_user_environment_key(environment: str, api_key: str) -> None:
    """Persist a key for the current Windows user without placing it on a command line."""

    if sys.platform == "win32":
        import winreg

        with winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, "Environment", 0, winreg.KEY_SET_VALUE) as key:
            winreg.SetValueEx(key, environment, 0, winreg.REG_SZ, api_key)
    os.environ[environment] = api_key
    _broadcast_windows_environment_change()


def _normalise_profile(payload: object, *, existing: dict[str, object] | None = None) -> dict[str, object]:
    if not isinstance(payload, dict):
        raise WebAppError("Provider 数据必须是对象。")
    forbidden = set(payload) - _ALLOWED_PROFILE_FIELDS
    if forbidden or "apiKey" in payload or "secret" in payload:
        raise WebAppError("只允许保存 Provider 的非秘密字段。")
    source = existing or {}
    profile_id = payload.get("id", source.get("id", str(uuid.uuid4())))
    try:
        profile_id = str(uuid.UUID(str(profile_id)))
    except (ValueError, TypeError, AttributeError) as error:
        raise WebAppError("Provider ID 必须是 UUID。") from error
    values: dict[str, object] = {"id": profile_id}
    name = payload.get("name", source.get("name"))
    if not isinstance(name, str) or not name.strip():
        raise WebAppError("缺少必填字段：name。")
    values["name"] = name.strip()
    values["enabled"] = bool(payload.get("enabled", source.get("enabled", True)))
    values["authMode"] = str(payload.get("authMode", source.get("authMode", "api_key")))
    if values["authMode"] not in {"api_key", "chatgpt_login"}:
        raise WebAppError("认证方式不受支持。")
    for field in ("baseUrl", "wireApi", "apiKeyEnv", "model"):
        value = payload.get(field, source.get(field))
        if value is None or value == "":
            continue
        if not isinstance(value, str) or not value.strip():
            raise WebAppError(f"字段 {field} 必须是文本。")
        values[field] = value.strip()
    models = payload.get("models", source.get("models", []))
    if models is None:
        models = []
    if not isinstance(models, list) or any(not isinstance(model, str) or not model.strip() for model in models):
        raise WebAppError("字段 models 必须是非空字符串列表。")
    normalized_models: list[str] = []
    for model in models:
        normalized = model.strip()
        if normalized not in normalized_models:
            normalized_models.append(normalized)
    if values.get("model") and normalized_models and values["model"] not in normalized_models:
        raise WebAppError("字段 model 必须存在于 models 列表中。")
    values["models"] = normalized_models
    if "wireApi" in values and values["wireApi"] != "responses":
        raise WebAppError("当前 Codex 版本仅支持 Responses API。")
    if values["authMode"] == "api_key":
        for field in ("baseUrl", "wireApi", "apiKeyEnv", "model"):
            if field not in values:
                raise WebAppError(f"缺少必填字段：{field}。")
    for field in ("reasoningEffort", "reviewModel"):
        value = payload.get(field, source.get(field))
        if value is not None:
            if not isinstance(value, str) or not value.strip():
                raise WebAppError(f"字段 {field} 必须是文本。")
            values[field] = value.strip()
    config_overrides = payload.get("configOverrides", source.get("configOverrides", {}))
    if not isinstance(config_overrides, dict) or config_overrides:
        raise WebAppError("没有获批准的配置覆盖项。")
    values["configOverrides"] = {}
    return values


def _safe_operation_result(result: dict[str, object]) -> dict[str, object]:
    allowed = {
        "provider", "display_name", "changed", "dry_run", "verified_config",
        "verified_threads", "synced_threads", "repaired_previews", "restored",
        "config_backup", "state_backup", "backup_manifest", "preserved_backup",
    }
    return {key: value for key, value in result.items() if key in allowed}


class LocalWebApp:
    """Application state and validated operations, independent of HTTP."""

    def __init__(self, catalog_path: Path, codex_home: Path, *, isolated_acceptance: bool = False):
        self.catalog_path = Path(catalog_path)
        self.codex_home = Path(codex_home)
        self.config_path = self.codex_home / "config.toml"
        self.state_db_path = self.codex_home / "state_5.sqlite"
        self.session_token = secrets.token_urlsafe(32)
        self.isolated_acceptance = isolated_acceptance
        self.logger = logging.getLogger("lansi-web")

    def _load(self) -> dict[str, object]:
        if not self.catalog_path.exists():
            return {"profiles": []}
        return load_catalog(self.catalog_path)

    def _save(self, catalog: dict[str, object]) -> None:
        save_catalog(self.catalog_path, catalog)

    def _profile(self, profile_id: str) -> dict[str, object]:
        profile = next((p for p in self._load()["profiles"] if p["id"] == profile_id), None)
        if profile is None:
            raise WebAppError("Provider 不存在。")
        return profile

    def choices(self) -> list[dict[str, object]]:
        choices: list[dict[str, object]] = [dict(_BUILTIN_CHOICES[0])]
        for profile in self._load()["profiles"]:
            choices.append({
                "id": profile["id"],
                "name": profile["name"],
                "kind": "custom",
                "enabled": profile["enabled"],
                "authMode": profile["authMode"],
            })
        return choices

    def state(self) -> dict[str, object]:
        catalog = self._load()
        try:
            diagnostics = status(self.config_path, self.state_db_path)
            current_provider = diagnostics.get("current_provider")
            activity = diagnostics.get("diagnostics", {})
        except Exception as error:  # diagnostics must never block catalog editing
            current_provider = None
            activity = {"history_error": "status_unavailable", "status_message": str(error)}
        selected_id = None
        if isinstance(current_provider, str) and current_provider.startswith("custom_"):
            for profile in catalog["profiles"]:
                try:
                    if f"custom_{uuid.UUID(str(profile['id'])).hex[:12]}" == current_provider:
                        selected_id = profile["id"]
                        break
                except (ValueError, TypeError, AttributeError):
                    continue
        return {
            "sessionToken": self.session_token,
            "choices": self.choices(),
            "profiles": [_public_profile(profile) for profile in catalog["profiles"]],
            "credentialStatus": {
                str(profile["id"]): {"apiKeyConfigured": _api_key_is_configured(profile)}
                for profile in catalog["profiles"]
                if profile.get("authMode") == "api_key"
            },
            "currentProvider": current_provider,
            "selectedId": selected_id or ("openai" if current_provider == "openai" else None),
            "diagnostics": activity,
            "isolatedAcceptance": self.isolated_acceptance,
        }

    def upsert(self, payload: object) -> dict[str, object]:
        catalog = self._load()
        existing = None
        if isinstance(payload, dict) and payload.get("id"):
            existing = next((p for p in catalog["profiles"] if p["id"] == payload["id"]), None)
        profile = _normalise_profile(payload, existing=existing)
        catalog["profiles"] = [p for p in catalog["profiles"] if p["id"] != profile["id"]] + [profile]
        self._save(catalog)
        return {"profile": _public_profile(profile)}

    def remove(self, profile_id: str) -> dict[str, object]:
        catalog = self._load()
        if profile_id in {choice["id"] for choice in _BUILTIN_CHOICES}:
            raise WebAppError("内置 Provider 不可删除。")
        if self._active_custom_profile_id() == profile_id:
            raise WebAppError("请先切换到其他 Provider，再删除当前生效的 Provider。")
        before = len(catalog["profiles"])
        catalog["profiles"] = [p for p in catalog["profiles"] if p["id"] != profile_id]
        if len(catalog["profiles"]) == before:
            raise WebAppError("Provider 不存在。")
        self._save(catalog)
        return {"removedProfileId": profile_id}

    def toggle(self, profile_id: str, enabled: bool) -> dict[str, object]:
        profile = self._profile(profile_id)
        if not enabled and self._active_custom_profile_id() == profile_id:
            raise WebAppError("请先切换到其他 Provider，再停用当前生效的 Provider。")
        profile["enabled"] = bool(enabled)
        catalog = self._load()
        catalog["profiles"] = [profile if p["id"] == profile_id else p for p in catalog["profiles"]]
        self._save(catalog)
        return {"profile": _public_profile(profile)}

    def import_profiles(self, payload: object) -> dict[str, object]:
        if not isinstance(payload, dict):
            raise WebAppError("导入内容必须是 JSON 对象。")
        raw_profiles = payload.get("profiles", [payload])
        if not isinstance(raw_profiles, list) or not raw_profiles:
            raise WebAppError("导入内容没有 Provider。")
        catalog = self._load()
        imported = [_normalise_profile(item) for item in raw_profiles]
        imported_ids = {p["id"] for p in imported}
        catalog["profiles"] = [p for p in catalog["profiles"] if p["id"] not in imported_ids] + imported
        self._save(catalog)
        return {"importedProfileIds": [p["id"] for p in imported]}

    def export_profile(self, profile_id: str) -> dict[str, object]:
        return {"profiles": [_public_profile(self._profile(profile_id))]}

    def store_profile_key(self, profile_id: str, api_key: object) -> dict[str, object]:
        """Write an API key outside the portable profile catalog and HTTP response."""

        if not isinstance(api_key, str) or not api_key.strip():
            raise WebAppError("API Key 不能为空。")
        if len(api_key) > _MAX_API_KEY_LENGTH:
            raise WebAppError("API Key 过长。")
        profile = self._profile(profile_id)
        if profile.get("authMode") != "api_key":
            raise WebAppError("只有 API Key Provider 可以保存 API Key。")
        environment = profile.get("apiKeyEnv")
        if not isinstance(environment, str) or not environment:
            raise WebAppError("Provider 缺少 API Key 环境变量名。")
        try:
            _store_user_environment_key(environment, api_key)
        except (OSError, ValueError):
            raise WebAppError("无法写入当前 Windows 用户的 API Key 环境变量。") from None
        return {"stored": True}

    def fetch_profile_models(self, profile_id: str) -> dict[str, object]:
        profile = self._profile(profile_id)
        if profile.get("authMode") != "api_key":
            raise WebAppError("只有 API Key Provider 可以从上游获取模型。")
        environment = profile.get("apiKeyEnv")
        if not isinstance(environment, str) or not environment:
            raise WebAppError("Provider 缺少 API Key 环境变量名。")
        api_key = os.environ.get(environment, "")
        models = fetch_models(str(profile.get("baseUrl", "")), api_key)
        profile["models"] = models
        if profile.get("model") not in models:
            profile["model"] = models[0]
        catalog = self._load()
        catalog["profiles"] = [profile if item["id"] == profile_id else item for item in catalog["profiles"]]
        self._save(catalog)
        return {"profile": _public_profile(profile), "models": models}

    def check(self, provider_id: str) -> dict[str, object]:
        return self._switch(provider_id, dry_run=True)

    def switch(self, provider_id: str) -> dict[str, object]:
        return self._switch(provider_id, dry_run=False)

    def _switch(self, provider_id: str, *, dry_run: bool) -> dict[str, object]:
        if provider_id == "openai":
            result = switch_provider("openai", self.config_path, self.state_db_path, dry_run=dry_run)
        else:
            result = switch_custom_profile(
                self._profile(provider_id), self.config_path, self.state_db_path, dry_run=dry_run
            )
        return _safe_operation_result(result)

    def _active_custom_profile_id(self) -> str | None:
        try:
            current_provider = status(self.config_path, self.state_db_path).get("current_provider")
        except Exception as error:
            raise WebAppError("无法确认当前 Provider；为保护配置，暂不允许删除或停用。") from error
        if not isinstance(current_provider, str) or not current_provider.startswith("custom_"):
            return None
        for profile in self._load()["profiles"]:
            try:
                provider = f"custom_{uuid.UUID(str(profile['id'])).hex[:12]}"
            except (ValueError, TypeError, AttributeError):
                continue
            if provider == current_provider:
                return str(profile["id"])
        return None

    def restore(self) -> dict[str, object]:
        return _safe_operation_result(restore_latest(self.config_path, self.state_db_path))


HTML = r'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>兰司观察 · Codex Provider Manager</title><link rel="icon" href="/assets/LansiObserve.ico">
<style>
:root{font-family:"Segoe UI Variable Text","Segoe UI",system-ui,sans-serif;color:#1f1f1f;background:#f5f7fb;line-height:1.4}
*{box-sizing:border-box}body{margin:0;min-height:100vh}button,input,select{font:inherit}button{cursor:pointer}
.shell{display:grid;grid-template-columns:280px 1fr;min-height:100vh}.sidebar{background:#fff;border-right:1px solid #e1e5ea;padding:28px 18px;display:flex;flex-direction:column;gap:22px}
.brand{display:flex;gap:12px;align-items:center}.brand-mark{width:38px;height:38px;border-radius:10px;object-fit:cover}.brand h1{font-size:16px;margin:0}.brand p{font-size:12px;color:#697586;margin:2px 0 0}
.section-label{font-size:12px;color:#697586;text-transform:uppercase;letter-spacing:.04em;margin:0 8px}.provider-list{display:flex;flex-direction:column;gap:5px;overflow:auto}.provider-item{width:100%;border:0;border-radius:8px;background:transparent;text-align:left;padding:11px 12px;color:#343a40;display:flex;align-items:center;justify-content:space-between}.provider-item:hover{background:#f0f4f8}.provider-item.selected{background:#e8f2fc;color:#07599e}.provider-item.disabled{opacity:.55}.provider-name{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.pill{font-size:11px;color:#687482;background:#eef1f4;border-radius:999px;padding:2px 7px}.selected .pill{background:#d6e9fb;color:#07599e}
.sidebar-actions{display:grid;gap:8px;margin-top:auto}.button{border:1px solid #d2d9e0;border-radius:7px;background:#fff;color:#263442;padding:9px 12px;text-align:center}.button:hover{background:#f2f6f9}.button.primary{background:#0f6cbd;color:#fff;border-color:#0f6cbd}.button.primary:hover{background:#0b5da7}.button.danger{color:#b42318}.button:disabled{opacity:.45;cursor:not-allowed}
.main{padding:34px 42px;max-width:1240px;width:100%}.topbar{display:flex;align-items:flex-start;justify-content:space-between;gap:20px;margin-bottom:24px}.topbar h2{margin:0;font-size:26px;font-weight:650}.subtitle{color:#697586;margin:4px 0 0}.toolbar{display:flex;gap:8px;flex-wrap:wrap;justify-content:flex-end}.grid{display:grid;grid-template-columns:minmax(0,1fr) 330px;gap:18px}.panel{background:#fff;border:1px solid #e1e5ea;border-radius:10px;padding:22px;box-shadow:0 2px 8px #172b4d0a}.panel h3{font-size:15px;margin:0 0 15px}.fields{display:grid;grid-template-columns:1fr 1fr;gap:16px}.field{display:grid;gap:6px}.field.full{grid-column:1/-1}.field label{font-size:12px;font-weight:600;color:#596575}.field input,.field select{width:100%;border:1px solid #ccd4dc;border-radius:7px;background:#fff;padding:9px 10px;color:#1f1f1f}.field input:focus,.field select:focus{outline:2px solid #9bc5ee;outline-offset:1px}.value{font-size:13px;color:#333d48;padding:9px 0;border-bottom:1px solid #edf0f3}.value:last-child{border-bottom:0}.notice{border-radius:8px;padding:10px 12px;background:#f3f6f9;color:#52606d;font-size:13px;margin-bottom:18px}.notice.success{background:#eaf7ef;color:#176b3a}.notice.error{background:#fdf0ef;color:#9b2419}.metrics{display:grid;gap:4px}.metric{display:flex;justify-content:space-between;font-size:13px;color:#596575}.metric strong{color:#252b32;font-weight:600}.action-row{display:flex;gap:8px;flex-wrap:wrap;margin-top:22px}.empty{color:#697586;padding:18px 8px;font-size:13px}.footer-note{font-size:12px;color:#7b8794;margin-top:15px}.dialog{border:0;border-radius:12px;padding:0;width:min(650px,calc(100vw - 32px));box-shadow:0 18px 60px #172b4d4d}.dialog::backdrop{background:#172b4d66}.dialog-inner{padding:25px}.dialog h3{margin:0 0 18px;font-size:19px}.dialog-actions{display:flex;justify-content:flex-end;gap:8px;margin-top:22px}.toast{position:fixed;right:24px;bottom:22px;background:#232b34;color:#fff;border-radius:8px;padding:12px 16px;max-width:420px;box-shadow:0 8px 30px #172b4d33;display:none}.toast.show{display:block}
@media(max-width:900px){.shell{grid-template-columns:1fr}.sidebar{border-right:0;border-bottom:1px solid #e1e5ea;padding:18px}.provider-list{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr))}.sidebar-actions{margin-top:0;display:flex;flex-wrap:wrap}.main{padding:24px 18px}.grid{grid-template-columns:1fr}}
@media(max-width:560px){.topbar{display:grid}.toolbar{justify-content:flex-start}.fields{grid-template-columns:1fr}.field.full{grid-column:auto}}
</style></head><body>
<div class="shell"><aside class="sidebar"><div class="brand"><img class="brand-mark" src="/assets/LansiObserve.ico" alt="兰司观察"><div><h1>兰司观察</h1><p>Codex Provider Manager</p></div></div><p class="section-label">Provider 列表</p><div id="providerList" class="provider-list"><div class="empty">正在读取...</div></div><div class="sidebar-actions"><button id="add" class="button primary">新增 Provider</button><button id="import" class="button">导入 Provider</button><button id="export" class="button" disabled>导出所选</button></div></aside>
<main class="main"><div class="topbar"><div><h2 id="title">Provider 工作区</h2><p id="subtitle" class="subtitle">选择一个 Provider 查看详情并执行受控切换。</p></div><div class="toolbar"><button id="edit" class="button" disabled>编辑</button><button id="copy" class="button" disabled>复制</button><button id="toggle" class="button" disabled>停用</button><button id="delete" class="button danger" disabled>删除</button></div></div><div id="notice" class="notice">仅本机浏览器可访问；API Key 仅写入当前 Windows 用户环境变量，不会保存到 Provider、导出文件或日志。</div><div class="grid"><section class="panel"><h3>Provider 详情</h3><div id="details" class="fields"><div class="empty">请选择 Provider。</div></div><div class="action-row"><button id="check" class="button" disabled>仅检查</button><button id="switch" class="button primary" disabled>切换 Provider</button><button id="restore" class="button">恢复最近备份</button></div><p class="footer-note">切换前会自动备份并校验会话、Skills、MCP、插件和不相关配置；失败会自动恢复。</p></section><aside class="panel"><h3>运行诊断</h3><div id="metrics" class="metrics"><div class="empty">正在读取...</div></div></aside></div></main></div>
<dialog id="profileDialog" class="dialog"><form id="profileForm" method="dialog" class="dialog-inner"><h3 id="dialogTitle">新增 Provider</h3><div class="fields"><div class="field"><label for="name">名称</label><input id="name" name="name" required maxlength="120"></div><div class="field"><label for="authMode">认证方式</label><select id="authMode" name="authMode"><option value="api_key">API key 环境变量</option><option value="chatgpt_login">ChatGPT / Codex 登录</option></select></div><div class="field"><label for="model">模型</label><input id="model" name="model" required maxlength="160"></div><div class="field"><label for="models">模型列表</label><input id="models" name="models" placeholder="deepseek-chat, deepseek-reasoner"><small>可手动填写多个模型，或从供应商 /models 获取。</small></div><div class="field full"><label for="baseUrl">Base URL</label><input id="baseUrl" name="baseUrl" type="url" placeholder="https://api.example.com/v1" required></div><div class="field"><label for="wireApi">Wire API</label><input id="wireApi" name="wireApi" value="responses" readonly aria-describedby="wireApiHelp"><small id="wireApiHelp">当前 Codex 版本仅支持 Responses API。</small></div><div class="field"><label for="apiKeyEnv">API key 环境变量名</label><input id="apiKeyEnv" name="apiKeyEnv" pattern="[A-Z][A-Z0-9_]{0,127}" placeholder="MY_PROVIDER_API_KEY" required></div><div id="apiKeyField" class="field"><label for="apiKey">API Key（仅当前 Windows 用户）</label><input id="apiKey" name="apiKey" type="password" autocomplete="new-password" maxlength="16384"><small>留空保留现有环境变量值；只写入当前用户环境变量。</small></div><div class="field"><label for="reasoningEffort">推理强度（可选）</label><input id="reasoningEffort" name="reasoningEffort"></div><div class="field"><label for="reviewModel">审阅模型（可选）</label><input id="reviewModel" name="reviewModel"></div></div><div class="dialog-actions"><button id="fetchModels" class="button" type="button">从上游获取模型</button><button id="cancelDialog" class="button" value="cancel">取消</button><button id="saveDialog" class="button primary" value="default">保存 Provider</button></div></form></dialog>
<input id="importFile" type="file" accept="application/json,.json" hidden><div id="toast" class="toast"></div>
<script>
const $=id=>document.getElementById(id); let state=null, selectedId=null, dialogMode='new', editingId=null;
function toast(message, error=false){const n=$('notice');n.textContent=message;n.className='notice '+(error?'error':'success');window.clearTimeout(toast.timer);toast.timer=window.setTimeout(()=>{n.className='notice';n.textContent='仅本机浏览器可访问；API Key 仅写入当前 Windows 用户环境变量，不会保存到 Provider、导出文件或日志。'},5000)}
async function api(path, options={}){options.headers=Object.assign({'Content-Type':'application/json','X-Lansi-Session':state?.sessionToken||''},options.headers||{});const r=await fetch(path,options);const body=await r.json().catch(()=>({error:'服务器返回了无效响应。'}));if(!r.ok)throw new Error(body.error||('请求失败（'+r.status+'）'));return body}
function closeWhenOwnerTabCloses(event){if(event.persisted||!state?.sessionToken)return;fetch('/api/close',{method:'POST',headers:{'Content-Type':'application/json','X-Lansi-Session':state.sessionToken},body:'{}',keepalive:true}).catch(()=>{})}
window.addEventListener('pagehide',closeWhenOwnerTabCloses);
async function reload(selectId=null){state=await api('/api/state',{headers:{'X-Lansi-Session':''}});selectedId=selectId||state.selectedId||(state.choices[0]&&state.choices[0].id);render()}
function selected(){return state?.choices.find(x=>x.id===selectedId)||null} function profile(){return state?.profiles.find(x=>x.id===selectedId)||null}
function render(){const list=$('providerList');list.replaceChildren();for(const item of state.choices){const b=document.createElement('button');b.className='provider-item '+(item.id===selectedId?'selected ':'')+(!item.enabled?'disabled':'');b.dataset.providerId=item.id;b.innerHTML='<span class="provider-name"></span><span class="pill"></span>';b.querySelector('.provider-name').textContent=item.name;b.querySelector('.pill').textContent=item.kind==='builtin'?'内置':(item.enabled?'已启用':'已停用');b.onclick=()=>{selectedId=item.id;render()};list.appendChild(b)}const item=selected(), p=profile(), activeCustom=!!p&&selectedId===state.selectedId;$('title').textContent=item?item.name:'Provider 工作区';$('subtitle').textContent=item?.kind==='builtin'?'ChatGPT / Codex Plus 登录状态':'非秘密配置由本地 catalog 管理。';const custom=!!p;for(const id of ['edit','copy','export'])$(id).disabled=!custom; $('toggle').disabled=!custom||(p?.enabled&&activeCustom);$('delete').disabled=!custom||activeCustom;$('toggle').textContent=p?.enabled?'停用':'启用';for(const id of ['check','switch'])$(id).disabled=!item||item.enabled===false;const d=$('details');d.replaceChildren();if(!item){d.innerHTML='<div class="empty">请选择 Provider。</div>'}else{const rows=custom?[['名称',p.name],['认证方式',p.authMode],['模型',p.model],...(p.models?.length?[['模型列表',p.models.join(', ')]]:[]),...(p.baseUrl?[['Base URL',p.baseUrl]]:[]),...(p.wireApi?[['Wire API',p.wireApi]]:[]),...(p.apiKeyEnv?[['API key 环境变量名',p.apiKeyEnv]]:[]),...(p.authMode==='api_key'?[['API Key',state.credentialStatus?.[p.id]?.apiKeyConfigured?'已配置':'未配置']]:[]),['状态',p.enabled?'已启用':'已停用']]:[['名称','OpenAI'],['认证方式','ChatGPT / Codex Plus 登录']];for(const [label,value] of rows){const el=document.createElement('div');el.className='field full';el.innerHTML='<label></label><div class="value"></div>';el.querySelector('label').textContent=label;el.querySelector('.value').textContent=value;d.appendChild(el)}}const m=state.diagnostics||{};$('metrics').innerHTML='';const metrics=[['当前 Provider',state.currentProvider||'未读取'],['会话线程',m.thread_count??'不可用'],['会话文件',m.session_file_count??'不可用'],['Skill',m.skill_count??'不可用'],['插件',m.plugin_count??'不可用'],['MCP 服务',m.mcp_server_count??'不可用'],['MCP 文件',m.mcp_file_count??'不可用']];for(const [label,value] of metrics){const el=document.createElement('div');el.className='metric';el.innerHTML='<span></span><strong></strong>';el.querySelector('span').textContent=label;el.querySelector('strong').textContent=value;m&&$('metrics').appendChild(el)}}
function syncAuthFields(){const api=$('authMode').value==='api_key';for(const id of ['baseUrl','wireApi','apiKeyEnv'])$(id).required=api;if(!api)$('apiKey').value='';$('apiKey').disabled=!api;$('apiKeyField').hidden=!api}
function openDialog(mode, source=null){dialogMode=mode;editingId=mode==='edit'?source.id:null;$('dialogTitle').textContent=mode==='new'?'新增 Provider':(mode==='copy'?'复制 Provider':'编辑 Provider');const p=source||{};$('name').value=mode==='copy'?(p.name+' 副本'): (p.name||'');$('authMode').value=p.authMode||'api_key';$('baseUrl').value=p.baseUrl||'';$('wireApi').value=p.wireApi||'responses';$('apiKeyEnv').value=p.apiKeyEnv||'';$('apiKey').value='';$('model').value=p.model||'';$('models').value=(p.models||[]).join(', ');$('reasoningEffort').value=p.reasoningEffort||'';$('reviewModel').value=p.reviewModel||'';syncAuthFields();$('profileDialog').showModal();$('name').focus()}
function profileDraft(){return {name:$('name').value,authMode:$('authMode').value,baseUrl:$('baseUrl').value||undefined,wireApi:$('wireApi').value||undefined,apiKeyEnv:$('apiKeyEnv').value||undefined,model:$('model').value||undefined,models:$('models').value.split(/[,;\n]/).map(x=>x.trim()).filter(Boolean),reasoningEffort:$('reasoningEffort').value||undefined,reviewModel:$('reviewModel').value||undefined}}
$('profileForm').addEventListener('submit',async e=>{e.preventDefault();const data=profileDraft();if(dialogMode==='edit')data.id=editingId;let savedProfile=null;try{const result=await api('/api/profile',{method:'POST',body:JSON.stringify(data)});savedProfile=result.profile;const apiKey=$('apiKey').value;if(apiKey){await api('/api/profile/key',{method:'POST',body:JSON.stringify({id:result.profile.id,key:apiKey})});$('apiKey').value=''}$('profileDialog').close();await reload(result.profile.id);toast(dialogMode==='edit'?'Provider 已更新。':'Provider 已保存。')}catch(err){toast((savedProfile?'Provider 已保存，但 API Key 未写入：':'')+err.message,true)}});$('authMode').onchange=syncAuthFields;$('cancelDialog').onclick=()=>{$('apiKey').value='';$('profileDialog').close()};$('add').onclick=()=>openDialog('new');$('edit').onclick=()=>{const p=profile();if(p)openDialog('edit',p)};$('copy').onclick=()=>{const p=profile();if(p)openDialog('copy',p)};
$('fetchModels').onclick=async()=>{if(dialogMode==='new'||dialogMode==='copy'){toast('请先保存 Provider，再从上游获取模型。',true);return}try{const result=await api('/api/profile/models',{method:'POST',body:JSON.stringify({id:editingId})});$('models').value=(result.models||[]).join(', ');$('model').value=result.profile.model||'';toast('已获取上游模型列表，请点击保存 Provider。')}catch(err){toast(err.message,true)}};
$('delete').onclick=async()=>{const p=profile();if(!p||!window.confirm('确定删除 '+p.name+'？此操作只删除 catalog 中的非秘密 Profile。'))return;try{await api('/api/profile/delete',{method:'POST',body:JSON.stringify({id:p.id})});await reload('openai');toast('Provider 已删除。')}catch(err){toast(err.message,true)}};$('toggle').onclick=async()=>{const p=profile();if(!p)return;try{await api('/api/profile/toggle',{method:'POST',body:JSON.stringify({id:p.id,enabled:!p.enabled})});await reload(p.id);toast(p.enabled?'Provider 已启用。':'Provider 已停用。')}catch(err){toast(err.message,true)}};
$('check').onclick=async()=>{try{const result=await api('/api/check',{method:'POST',body:JSON.stringify({id:selectedId})});toast('检查通过：配置可安全切换。 '+JSON.stringify(result))}catch(err){toast(err.message,true)}};$('switch').onclick=async()=>{if(!window.confirm('确认切换到 '+(selected()?.name||'所选 Provider')+'？'))return;try{const result=await api('/api/switch',{method:'POST',body:JSON.stringify({id:selectedId})});await reload(selectedId);toast(result.verified_config?'切换并校验成功。请重新启动 Codex；ChatGPT 的登录提示并不代表当前 Provider。':'切换完成，但校验未通过。',!result.verified_config)}catch(err){toast(err.message,true)}};$('restore').onclick=async()=>{if(!window.confirm('确认恢复最近一次受控备份？'))return;try{await api('/api/restore',{method:'POST',body:'{}'});await reload();toast('已恢复最近备份。')}catch(err){toast(err.message,true)}};
$('import').onclick=()=>$('importFile').click();$('importFile').onchange=async e=>{const file=e.target.files[0];if(!file)return;try{const result=await api('/api/profile/import',{method:'POST',body:await file.text()});await reload(result.importedProfileIds[0]);toast('Provider 已导入。')}catch(err){toast(err.message,true)}e.target.value=''};$('export').onclick=async()=>{const p=profile();if(!p)return;try{const data=await api('/api/profile/export?id='+encodeURIComponent(p.id),{headers:{'X-Lansi-Session':''}});const blob=new Blob([JSON.stringify(data,null,2)],{type:'application/json'});const link=document.createElement('a');link.href=URL.createObjectURL(blob);link.download=p.name.replace(/[^\w\u4e00-\u9fff.-]+/g,'_')+'.lansi-profile.json';link.click();URL.revokeObjectURL(link.href);toast('Provider 已导出。')}catch(err){toast(err.message,true)}};reload().catch(err=>toast(err.message,true));
</script></body></html>'''


class _Handler(BaseHTTPRequestHandler):
    server: "_AppServer"

    def log_message(self, format: str, *args: object) -> None:
        self.server.app.logger.info("http " + format, *args)

    @property
    def app(self) -> LocalWebApp:
        return self.server.app

    def _json(self, payload: object, status_code: int = 200, *, headers: dict[str, str] | None = None) -> None:
        encoded = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(encoded)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(encoded)

    def _error(self, error: Exception, status_code: int = 400) -> None:
        self.app.logger.warning("request error: %s", str(error))
        self._json({"error": str(error)}, status_code)

    def _body(self) -> object:
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length > 256 * 1024:
                raise WebAppError("请求过大。")
            return json.loads(self.rfile.read(length).decode("utf-8")) if length else {}
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise WebAppError("请求必须是 UTF-8 JSON。") from error

    def _require_token(self) -> None:
        if not secrets.compare_digest(self.headers.get("X-Lansi-Session", ""), self.app.session_token):
            raise WebAppError("本地会话令牌无效。")

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        try:
            if parsed.path == "/":
                body = HTML.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if parsed.path == "/api/state":
                self._json(self.app.state())
                return
            if parsed.path == "/assets/LansiObserve.ico":
                icon = Path(__file__).with_name("LansiObserve.ico")
                body = icon.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "image/x-icon")
                self.send_header("Cache-Control", "public, max-age=86400")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if parsed.path == "/api/profile/export":
                profile_id = parse_qs(parsed.query).get("id", [""])[0]
                payload = self.app.export_profile(profile_id)
                self._json(payload, headers={"Content-Disposition": "attachment; filename=provider.lansi-profile.json"})
                return
            self._json({"error": "Not found"}, 404)
        except (WebAppError, ProfileCatalogError, OSError, RuntimeError) as error:
            self._error(error, 400)

    def do_POST(self) -> None:  # noqa: N802
        try:
            self._require_token()
            parsed = urlparse(self.path)
            payload = self._body()
            close_after_response = False
            if parsed.path == "/api/profile":
                result = self.app.upsert(payload)
            elif parsed.path == "/api/profile/delete":
                if not isinstance(payload, dict) or not isinstance(payload.get("id"), str):
                    raise WebAppError("缺少 Provider ID。")
                result = self.app.remove(payload["id"])
            elif parsed.path == "/api/profile/toggle":
                if not isinstance(payload, dict) or not isinstance(payload.get("id"), str):
                    raise WebAppError("缺少 Provider ID。")
                result = self.app.toggle(payload["id"], bool(payload.get("enabled")))
            elif parsed.path == "/api/profile/import":
                result = self.app.import_profiles(payload)
            elif parsed.path == "/api/profile/models":
                if not isinstance(payload, dict) or not isinstance(payload.get("id"), str):
                    raise WebAppError("缺少 Provider ID。")
                result = self.app.fetch_profile_models(payload["id"])
            elif parsed.path == "/api/profile/key":
                if (
                    not isinstance(payload, dict)
                    or set(payload) != {"id", "key"}
                    or not isinstance(payload.get("id"), str)
                ):
                    raise WebAppError("API Key 请求无效。")
                result = self.app.store_profile_key(payload["id"], payload["key"])
            elif parsed.path in {"/api/check", "/api/switch"}:
                if not isinstance(payload, dict) or not isinstance(payload.get("id"), str):
                    raise WebAppError("缺少 Provider ID。")
                result = self.app.check(payload["id"]) if parsed.path == "/api/check" else self.app.switch(payload["id"])
            elif parsed.path == "/api/restore":
                result = self.app.restore()
            elif parsed.path == "/api/close":
                result = {"closing": True}
                close_after_response = True
            else:
                self._json({"error": "Not found"}, 404)
                return
            self._json(result)
            if close_after_response:
                self.server.request_shutdown()
        except (WebAppError, ProfileCatalogError, OSError, RuntimeError, ValueError) as error:
            self._error(error, 400)


class _AppServer(ThreadingHTTPServer):
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], app: LocalWebApp):
        self.app = app
        super().__init__(address, _Handler)

    def request_shutdown(self) -> None:
        self.app.logger.info("shutdown.owner_tab_closed")
        # BaseServer.shutdown waits for serve_forever, so it cannot run in the request thread.
        threading.Thread(target=self.shutdown, name="lansi-owner-tab-shutdown", daemon=True).start()


def create_server(app: LocalWebApp, port: int = 0) -> _AppServer:
    return _AppServer(("127.0.0.1", port), app)


def _configure_logging(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        filename=path,
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        encoding="utf-8",
    )


def _parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path)
    parser.add_argument("--codex-home", type=Path)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--debug-log", type=Path)
    parser.add_argument("--open-browser", dest="open_browser", action="store_true", default=True)
    parser.add_argument("--no-open-browser", dest="open_browser", action="store_false")
    parser.add_argument("--isolated-acceptance", action="store_true")
    args = parser.parse_args(argv)
    if args.isolated_acceptance and (args.catalog is None or args.codex_home is None):
        parser.error("--isolated-acceptance requires explicit --catalog and --codex-home paths")
    return args


def _open_local_browser(url: str, logger: logging.Logger) -> bool:
    try:
        if webbrowser.open(url, new=2):
            logger.info("startup.browser_open method=webbrowser url=%s", url)
            return True
        logger.warning("startup.browser_open_failed method=webbrowser url=%s", url)
    except Exception as error:  # Browser registration is outside the application process.
        logger.warning("startup.browser_open_failed method=webbrowser error=%s url=%s", error, url)

    startfile = getattr(os, "startfile", None)
    if startfile is not None:
        try:
            startfile(url)
            logger.info("startup.browser_open method=startfile url=%s", url)
            return True
        except OSError as error:
            logger.warning("startup.browser_open_failed method=startfile error=%s url=%s", error, url)

    logger.error("startup.browser_unavailable url=%s", url)
    return False


def main(argv: list[str] | None = None) -> int:
    args = _parse_arguments(argv)
    catalog_path = args.catalog or _default_catalog_path()
    codex_home = args.codex_home or _default_codex_home()
    log_path = args.debug_log or Path(os.environ.get("TEMP", Path("/tmp"))) / "Lansi_CodexProviderManager-startup.log"
    _configure_logging(log_path)
    app = LocalWebApp(catalog_path, codex_home, isolated_acceptance=args.isolated_acceptance)
    server = create_server(app, args.port)
    url = f"http://127.0.0.1:{server.server_address[1]}/"
    app.logger.info("startup.ready isolated=%s url=%s", args.isolated_acceptance, url)
    if args.open_browser:
        _open_local_browser(url, app.logger)
    else:
        app.logger.info("startup.browser_disabled url=%s", url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        app.logger.info("shutdown.keyboard_interrupt")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
