"""Non-secret portable provider profile catalog for the Windows switcher."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import tempfile
import urllib.error
import urllib.request
import uuid
from urllib.parse import urlparse


class ProfileCatalogError(ValueError):
    pass


_PROFILE_FIELDS = {
    "id",
    "providerId",
    "name",
    "enabled",
    "authMode",
    "baseUrl",
    "wireApi",
    "apiKeyEnv",
    "authCommand",
    "httpHeaders",
    "envHttpHeaders",
    "model",
    "models",
    "reasoningEffort",
    "reviewModel",
    "supportsStandaloneWebSearch",
    "legacyAliases",
    "configOverrides",
}
_REQUIRED_FIELDS = {"id", "name", "enabled", "authMode"}
_ENV_NAME = re.compile(r"^[A-Z][A-Z0-9_]{0,127}$")
_PROVIDER_ID = re.compile(r"^[a-z][a-z0-9_-]{0,63}$")
_RESERVED_PROVIDER_IDS = {"openai", "ollama", "lmstudio"}
_AUTH_MODES = {"openai_login", "environment_key", "command_token"}
_CREDENTIAL_HEADERS = {"authorization", "proxy-authorization", "x-api-key", "api-key"}
_SUPPORTED_WIRE_API = "responses"
MAX_MANAGED_MODELS = 100
_MAX_UPSTREAM_MODELS = 1000
_MAX_MODEL_ID_LENGTH = 256
_CODEX_BASE_INSTRUCTIONS = (
    "You are Codex, a coding agent. Follow the user's instructions and use available tools "
    "to work in the current repository."
)
_STANDARD_REASONING_LEVELS = ("none", "low", "medium", "high", "xhigh", "max")
_DEEPSEEK_REASONING_LEVELS = ("low", "medium", "high", "xhigh", "max")
_REASONING_LEVEL_DESCRIPTIONS = {
    "none": "Disables model reasoning when that model supports a non-reasoning mode",
    "low": "Fast responses with lighter reasoning",
    "medium": "Balances speed and reasoning depth for everyday tasks",
    "high": "Greater reasoning depth for complex problems",
    "xhigh": "Extra high reasoning depth for complex problems",
    "max": "Maximum available reasoning for the most demanding tasks",
}


def _validate_profile(profile: object) -> dict[str, object]:
    if not isinstance(profile, dict):
        raise ProfileCatalogError("Each profile must be an object")
    unknown = set(profile) - _PROFILE_FIELDS
    if unknown or not _REQUIRED_FIELDS.issubset(profile):
        raise ProfileCatalogError("Profile fields do not match the non-secret contract")
    try:
        uuid.UUID(str(profile["id"]))
    except (ValueError, TypeError, AttributeError) as error:
        raise ProfileCatalogError("Profile id must be a UUID") from error
    if not isinstance(profile["name"], str) or not profile["name"].strip():
        raise ProfileCatalogError("Profile name is required")
    provider_id = profile.get("providerId")
    if not isinstance(provider_id, str) or not _PROVIDER_ID.fullmatch(provider_id):
        raise ProfileCatalogError("Provider ID must start with a lowercase letter and use only lowercase letters, digits, underscores, or hyphens")
    if provider_id in _RESERVED_PROVIDER_IDS:
        raise ProfileCatalogError("openai, ollama, and lmstudio are reserved Provider IDs")
    if not isinstance(profile["enabled"], bool) or profile["authMode"] not in _AUTH_MODES:
        raise ProfileCatalogError("Profile enabled and authMode values are invalid")
    if profile["authMode"] != "openai_login":
        base_url = profile.get("baseUrl")
        parsed_base_url = urlparse(base_url) if isinstance(base_url, str) else None
        if parsed_base_url is None or parsed_base_url.scheme != "https" or not parsed_base_url.netloc:
            raise ProfileCatalogError("Custom Provider profiles need an HTTPS baseUrl")
        if profile.get("wireApi") != _SUPPORTED_WIRE_API:
            raise ProfileCatalogError("Custom Provider profiles need wireApi=responses")
        if not isinstance(profile.get("model"), str) or not str(profile["model"]).strip():
            raise ProfileCatalogError("Custom Provider profiles need a model")
    if profile["authMode"] == "environment_key":
        environment_name = profile.get("apiKeyEnv")
        if not isinstance(environment_name, str) or not _ENV_NAME.fullmatch(environment_name):
            raise ProfileCatalogError("API-key profiles need a valid apiKeyEnv")
    elif "apiKeyEnv" in profile:
        raise ProfileCatalogError("Only environment-key profiles may define apiKeyEnv")
    command = profile.get("authCommand")
    if profile["authMode"] == "command_token":
        if not isinstance(command, dict) or set(command) - {"command", "timeoutMilliseconds", "refreshIntervalMilliseconds", "workingDirectory"}:
            raise ProfileCatalogError("Command-token profiles need a valid authCommand")
        executable = command.get("command")
        if not isinstance(executable, str) or not Path(executable).is_absolute():
            raise ProfileCatalogError("Authentication command must be an absolute path")
        timeout = command.get("timeoutMilliseconds", 10_000)
        if not isinstance(timeout, int) or isinstance(timeout, bool) or not 100 <= timeout <= 300_000:
            raise ProfileCatalogError("Authentication command timeout must be between 100 and 300000 ms")
        refresh = command.get("refreshIntervalMilliseconds")
        if refresh is not None and (not isinstance(refresh, int) or isinstance(refresh, bool) or refresh < 0):
            raise ProfileCatalogError("Authentication command refresh interval must be a non-negative integer")
        working_directory = command.get("workingDirectory")
        if working_directory is not None and (not isinstance(working_directory, str) or not Path(working_directory).is_absolute()):
            raise ProfileCatalogError("Authentication command working directory must be absolute")
    elif command is not None:
        raise ProfileCatalogError("Only command-token profiles may define authCommand")
    for name in ("baseUrl", "apiKeyEnv", "model", "reasoningEffort", "reviewModel"):
        if name in profile and (not isinstance(profile[name], str) or not profile[name].strip()):
            raise ProfileCatalogError(f"Profile {name} must be text")
    if "models" in profile:
        if not isinstance(profile["models"], list) or any(
            not isinstance(model, str) or not model.strip() for model in profile["models"]
        ) or len(set(profile["models"])) != len(profile["models"]):
            raise ProfileCatalogError("Profile models must be a unique list of non-empty text")
        if len(profile["models"]) > MAX_MANAGED_MODELS:
            raise ProfileCatalogError(f"Profile models cannot exceed {MAX_MANAGED_MODELS} entries")
    if "wireApi" in profile and profile["wireApi"] != _SUPPORTED_WIRE_API:
        raise ProfileCatalogError("Only wireApi=responses is supported by the current Codex version")
    if "configOverrides" in profile and (
        not isinstance(profile["configOverrides"], dict) or profile["configOverrides"]
    ):
        raise ProfileCatalogError("No configOverrides are approved")
    for field in ("httpHeaders", "envHttpHeaders"):
        headers = profile.get(field, {})
        if not isinstance(headers, dict) or any(
            not isinstance(key, str) or not key.strip() or not isinstance(value, str) or not value.strip()
            for key, value in headers.items()
        ):
            raise ProfileCatalogError(f"Profile {field} must be a non-empty text map")
    if any(key.casefold() in _CREDENTIAL_HEADERS for key in profile.get("httpHeaders", {})):
        raise ProfileCatalogError("Credential headers must reference environment variables instead of storing values")
    if any(not _ENV_NAME.fullmatch(value) for value in profile.get("envHttpHeaders", {}).values()):
        raise ProfileCatalogError("Environment HTTP headers must reference valid environment variable names")
    if "supportsStandaloneWebSearch" in profile and not isinstance(profile["supportsStandaloneWebSearch"], bool):
        raise ProfileCatalogError("supportsStandaloneWebSearch must be true or false")
    aliases = profile.get("legacyAliases", [])
    if not isinstance(aliases, list) or any(not isinstance(alias, str) or not _PROVIDER_ID.fullmatch(alias) for alias in aliases):
        raise ProfileCatalogError("Legacy aliases must be valid Provider IDs")
    if provider_id in aliases or len(set(aliases)) != len(aliases):
        raise ProfileCatalogError("Legacy aliases must be unique and different from the Provider ID")
    return profile


def _validate_catalog(catalog: object) -> dict[str, object]:
    if not isinstance(catalog, dict) or set(catalog) != {"schemaVersion", "profiles"}:
        raise ProfileCatalogError("Catalog must contain schemaVersion and profiles")
    if catalog["schemaVersion"] != 2:
        raise ProfileCatalogError("Only profile catalog schemaVersion=2 is supported")
    profiles = catalog["profiles"]
    if not isinstance(profiles, list):
        raise ProfileCatalogError("Catalog profiles must be a list")
    validated = [_validate_profile(profile) for profile in profiles]
    if len({profile["id"] for profile in validated}) != len(validated):
        raise ProfileCatalogError("Profile ids must be unique")
    provider_ids = [str(profile["providerId"]).casefold() for profile in validated]
    if len(set(provider_ids)) != len(provider_ids):
        raise ProfileCatalogError("Provider IDs must be unique")
    return {"schemaVersion": 2, "profiles": validated}


def load_catalog(path: Path) -> dict[str, object]:
    try:
        catalog = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ProfileCatalogError("Profile catalog is missing or invalid") from error
    return _validate_catalog(_migrate_catalog(catalog, migrate_legacy_wire_api=True))


def _migrate_catalog(catalog: object, *, migrate_legacy_wire_api: bool = False) -> object:
    """Read legacy profiles safely without rendering a value strict Codex rejects.

    The migration is in-memory: a catalog is only rewritten after the user explicitly saves,
    imports, edits, or changes a profile. Profile catalogues contain no key values.
    """

    if not isinstance(catalog, dict) or not isinstance(catalog.get("profiles"), list):
        return catalog
    if catalog.get("schemaVersion", 1) not in {1, 2}:
        return catalog
    migrated: list[object] = []
    for profile in catalog["profiles"]:
        if isinstance(profile, dict):
            updated = dict(profile)
            profile_id = str(updated.get("id", ""))
            try:
                legacy_provider_id = f"custom_{uuid.UUID(profile_id).hex[:12]}"
            except (ValueError, TypeError, AttributeError):
                legacy_provider_id = ""
            updated["providerId"] = str(updated.get("providerId") or legacy_provider_id).strip().lower()
            updated["authMode"] = {
                "api_key": "environment_key",
                "chatgpt_login": "openai_login",
            }.get(updated.get("authMode"), updated.get("authMode"))
            if migrate_legacy_wire_api or updated.get("wireApi") is None:
                updated["wireApi"] = _SUPPORTED_WIRE_API
            updated.setdefault("httpHeaders", {})
            updated.setdefault("envHttpHeaders", {})
            updated.setdefault("supportsStandaloneWebSearch", False)
            aliases = updated.get("legacyAliases", [])
            updated["legacyAliases"] = list(dict.fromkeys(
                alias.strip().lower() for alias in aliases
                if isinstance(alias, str) and alias.strip().lower() != updated["providerId"]
            )) if isinstance(aliases, list) else []
            migrated.append(updated)
        else:
            migrated.append(profile)
    return {"schemaVersion": 2, "profiles": migrated}


def save_catalog(path: Path, catalog: dict[str, object]) -> None:
    validated = _validate_catalog(_migrate_catalog(catalog))
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, prefix=".profiles-", delete=False
        ) as handle:
            temporary_path = Path(handle.name)
            json.dump(validated, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
        temporary_path = None
    finally:
        if temporary_path and temporary_path.exists():
            temporary_path.unlink()


def _models_endpoint(base_url: str) -> str:
    parsed = urlparse(base_url.strip())
    if parsed.scheme.lower() != "https" or not parsed.netloc:
        raise ProfileCatalogError("Base URL must be a valid HTTPS URL")
    path = parsed.path.rstrip("/")
    if not path.endswith("/models"):
        path = f"{path}/models" if path else "/models"
    return parsed._replace(path=path, params="", query="", fragment="").geturl()


def _request_models_payload(
    base_url: str,
    api_key: str,
    http_headers: dict[str, str] | None = None,
    env_http_headers: dict[str, str] | None = None,
) -> object:
    if not api_key:
        raise ProfileCatalogError("API key is required to fetch models")
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Accept": "application/json",
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    }
    headers.update(http_headers or {})
    for header, environment_name in (env_http_headers or {}).items():
        value = os.environ.get(environment_name)
        if value:
            headers[header] = value
    request = urllib.request.Request(
        _models_endpoint(base_url),
        headers=headers,
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        raise ProfileCatalogError(f"Model request failed with HTTP {error.code}") from error
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        raise ProfileCatalogError("Model request failed") from error
    return payload


def fetch_models(
    base_url: str,
    api_key: str,
    http_headers: dict[str, str] | None = None,
    env_http_headers: dict[str, str] | None = None,
) -> list[str]:
    return _model_ids(_request_models_payload(base_url, api_key, http_headers, env_http_headers))


def _model_ids(payload: object) -> list[str]:
    field = "id"
    if isinstance(payload, list):
        items = payload
    elif isinstance(payload, dict):
        items = payload.get("data")
        if not isinstance(items, list):
            items = payload.get("models")
            field = "slug"
    else:
        items = None
    if not isinstance(items, list) or len(items) > _MAX_UPSTREAM_MODELS:
        raise ProfileCatalogError("Provider returned an unsupported model-list response")

    models: list[str] = []
    seen: set[str] = set()
    for item in items:
        value = item.get(field) if isinstance(item, dict) else item if isinstance(item, str) else None
        if not isinstance(value, str):
            continue
        model = value.strip()
        if (
            not model
            or len(model) > _MAX_MODEL_ID_LENGTH
            or any(ord(character) < 32 for character in model)
            or model in seen
        ):
            continue
        seen.add(model)
        models.append(model)
    if not models:
        raise ProfileCatalogError("Provider returned no models")
    return models


def codex_reasoning_efforts(model: str) -> tuple[str, ...]:
    """Return the safe Codex-facing reasoning choices for a configured model.

    A generic ``/models`` response exposes model names but no capability metadata.
    An empty list therefore makes Codex treat every custom model as having no
    reasoning selector. DeepSeek V4 documents low/high/max and explicit
    compatibility mappings for medium and xhigh, so custom DeepSeek profiles
    expose every selectable effort plus the provider's explicit ``max`` level.
    """

    if "deepseek" in model.casefold():
        return _DEEPSEEK_REASONING_LEVELS
    return _STANDARD_REASONING_LEVELS


def _codex_model(model: str, priority: int) -> dict[str, object]:
    """Create the same Codex model metadata used by the verified macOS catalog."""

    efforts = codex_reasoning_efforts(model)
    parts = [part for part in model.split("-") if part]
    display_name = " ".join(part[:1].upper() + part[1:] for part in parts) or model
    return {
        "slug": model,
        "display_name": display_name,
        "description": f"Model {model} served by this provider.",
        "default_reasoning_level": "high" if "deepseek" in model.casefold() else "low",
        "supported_reasoning_levels": [
            {"effort": effort, "description": _REASONING_LEVEL_DESCRIPTIONS[effort]}
            for effort in efforts
        ],
        "shell_type": "default",
        "visibility": "list",
        "supported_in_api": True,
        "priority": priority,
        "support_verbosity": True,
        "truncation_policy": {"mode": "tokens", "limit": 10000},
        "supports_parallel_tool_calls": True,
        "experimental_supported_tools": [],
        "model_messages": {
            "instructions_template": "You are Codex, an AI coding assistant.",
            "instructions_variables": None,
            "approvals": None,
            "collaboration_modes": None,
            "auto_review": None,
            "permissions": None,
            "token_budget": {
                "reminder_threshold_tokens": 6144,
                "reminder_message_template": "The context window is nearly exhausted.",
                "guidance_message": "",
                "auto_compact_fallback_prompt": "",
                "auto_compact_fallback_buffer_tokens": 16384,
            },
        },
    }


def fetch_codex_model_catalog(
    base_url: str, api_key: str, selected_model: str
) -> dict[str, object]:
    """Adapt a standard OpenAI model list into Codex Desktop's local catalog format."""

    models = _curate_model_ids(_model_ids(_request_models_payload(base_url, api_key)), selected_model)
    selected = selected_model.strip()
    if selected not in models:
        raise ProfileCatalogError(
            "所选模型不在 Provider 返回的模型列表中；已拒绝切换，原配置未更改。"
        )
    return {"models": [_codex_model(model, index + 1) for index, model in enumerate(models)]}


def build_managed_model_catalog(
    managed_models: list[str], primary_model: str
) -> dict[str, object]:
    """Render only the models the user selected for this Provider.

    The primary model remains available after a user clears the managed list, but
    an upstream ``/models`` response is never merged here.
    """

    candidates = [primary_model, *managed_models]
    models: list[str] = []
    seen: set[str] = set()
    for candidate in candidates:
        value = candidate.strip()
        if value and value not in seen:
            seen.add(value)
            models.append(value)
    if not models:
        raise ProfileCatalogError("Custom Provider requires a current model before rendering its model catalog")
    return {"models": [_codex_model(model, index + 1) for index, model in enumerate(models)]}


def _curate_model_ids(models: list[str], selected: str) -> list[str]:
    """Drop non-LLM entries (image/audio/lyrics/embedding...) so the Codex picker
    stays usable for providers such as VectorEngine that advertise huge lists."""

    excluded = (
        "image", "audio", "tts", "speech", "lyric", "embedding", "rerank", "seedream",
        "flux", "sora", "whisper", "suno", "dall", "video", "moderation", "realtime",
        "transcribe", "ocr",
    )
    families = (
        "gpt", "claude", "deepseek", "qwen", "o1", "o3", "o4", "o5", "gemini", "llama",
        "mistral", "glm", "kimi", "moonshot", "doubao", "ernie", "spark", "yi-", "minimax",
        "hunyuan", "command-", "phi-", "grok", "codex", "chat",
    )
    selected = selected.strip()
    original = [model.strip() for model in models if model.strip()]
    result: list[str] = []
    seen: set[str] = set()
    for model in models:
        value = model.strip()
        if not value or value in seen:
            continue
        lowered = value.lower()
        if any(marker in lowered for marker in excluded):
            continue
        if any(marker in lowered for marker in families):
            seen.add(value)
            result.append(value)
    if selected and selected in original:
        if selected in result:
            result.remove(selected)
        result.insert(0, selected)
    return result or original


def save_codex_model_catalog(path: Path, catalog: dict[str, object]) -> None:
    """Atomically persist a non-secret generated model catalog."""

    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, prefix=".model-catalog-", delete=False
        ) as handle:
            temporary_path = Path(handle.name)
            json.dump(catalog, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
        temporary_path = None
    finally:
        if temporary_path and temporary_path.exists():
            temporary_path.unlink()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--id")
    parser.add_argument("--name")
    parser.add_argument("--provider-id")
    parser.add_argument("--base-url")
    parser.add_argument("--wire-api")
    parser.add_argument("--api-key-env")
    parser.add_argument("--model")
    parser.add_argument("--models")
    parser.add_argument("--models-json")
    parser.add_argument("--fetch-models", action="store_true")
    parser.add_argument("--enabled", choices=("true", "false"))
    parser.add_argument("--auth-mode", choices=("openai_login", "environment_key", "command_token", "chatgpt_login", "api_key"))
    parser.add_argument("--reasoning-effort")
    parser.add_argument("--review-model")
    parser.add_argument("--config-overrides-json")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--remove", action="store_true")
    mode.add_argument("--set-enabled", choices=("true", "false"))
    mode.add_argument("--export", dest="export_path", type=Path)
    mode.add_argument("--import-file", type=Path)
    args = parser.parse_args()
    if args.fetch_models:
        if not args.base_url or not args.api_key_env:
            parser.error("--fetch-models requires --base-url and --api-key-env")
        api_key = os.environ.get(args.api_key_env, "")
        print(json.dumps({"models": fetch_models(args.base_url, api_key)}, ensure_ascii=False))
        return 0
    catalog = load_catalog(args.catalog) if args.catalog.exists() else {"schemaVersion": 2, "profiles": []}
    if args.export_path is not None:
        if not args.id: parser.error("export requires --id")
        profile = next((item for item in catalog["profiles"] if item["id"] == args.id), None)
        if profile is None: parser.error("profile id was not found")
        save_catalog(args.export_path, {"schemaVersion": 2, "profiles": [profile]})
        print(json.dumps({"exportedProfileId": profile["id"]}, ensure_ascii=False))
        return 0
    if args.import_file is not None:
        imported = load_catalog(args.import_file)["profiles"]
        if not imported:
            parser.error("import file does not contain profiles")
        imported_ids = [profile["id"] for profile in imported]
        catalog["profiles"] = [
            item for item in catalog["profiles"] if item["id"] not in set(imported_ids)
        ] + imported
        save_catalog(args.catalog, catalog)
        print(json.dumps({"importedProfileIds": imported_ids}, ensure_ascii=False))
        return 0
    if not args.id: parser.error("upsert, remove, or set-enabled requires --id")
    if args.remove:
        catalog["profiles"] = [item for item in catalog["profiles"] if item["id"] != args.id]
        save_catalog(args.catalog, catalog)
        return 0
    if args.set_enabled is not None:
        matched = False
        for profile in catalog["profiles"]:
            if profile["id"] == args.id:
                profile["enabled"] = args.set_enabled == "true"
                matched = True
        if not matched:
            parser.error("profile id was not found")
        save_catalog(args.catalog, catalog)
        return 0
    if not args.name:
        parser.error("upsert requires --name")
    auth_mode = {"api_key": "environment_key", "chatgpt_login": "openai_login"}.get(
        args.auth_mode or "environment_key", args.auth_mode or "environment_key"
    )
    if auth_mode == "environment_key" and not all((args.base_url, args.api_key_env)):
        parser.error("API-key upsert requires --base-url and --api-key-env")
    try:
        config_overrides = json.loads(args.config_overrides_json) if args.config_overrides_json else {}
    except json.JSONDecodeError as error:
        parser.error(f"config-overrides-json must be JSON: {error.msg}")
    profile = {
        "id": args.id,
        "providerId": (args.provider_id or f"custom_{uuid.UUID(args.id).hex[:12]}").lower(),
        "name": args.name,
        "enabled": args.enabled != "false",
        "authMode": auth_mode,
        "configOverrides": config_overrides,
        "httpHeaders": {},
        "envHttpHeaders": {},
        "supportsStandaloneWebSearch": False,
        "legacyAliases": [],
    }
    values = {
        "baseUrl": args.base_url,
        "wireApi": args.wire_api,
        "apiKeyEnv": args.api_key_env,
        "model": args.model,
        "models": None,
        "reasoningEffort": args.reasoning_effort,
        "reviewModel": args.review_model,
    }
    if args.models_json:
        try:
            models = json.loads(args.models_json)
        except json.JSONDecodeError as error:
            parser.error(f"models-json must be JSON: {error.msg}")
        if not isinstance(models, list):
            parser.error("models-json must be an array")
        values["models"] = models
    elif args.models is not None:
        values["models"] = [value.strip() for value in args.models.split(",") if value.strip()]
    profile.update({key: value for key, value in values.items() if value is not None})
    catalog["profiles"] = [item for item in catalog["profiles"] if item["id"] != args.id] + [profile]
    save_catalog(args.catalog, catalog)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
