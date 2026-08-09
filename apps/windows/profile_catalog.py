"""Non-secret portable provider profile catalog for the Windows switcher."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import tempfile
import uuid
from urllib.parse import urlparse


class ProfileCatalogError(ValueError):
    pass


_PROFILE_FIELDS = {
    "id",
    "name",
    "enabled",
    "authMode",
    "baseUrl",
    "wireApi",
    "apiKeyEnv",
    "model",
    "reasoningEffort",
    "reviewModel",
    "configOverrides",
}
_REQUIRED_FIELDS = {"id", "name", "enabled", "authMode"}
_ENV_NAME = re.compile(r"^[A-Z][A-Z0-9_]{0,127}$")


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
    if not isinstance(profile["enabled"], bool) or profile["authMode"] not in {"chatgpt_login", "api_key"}:
        raise ProfileCatalogError("Profile enabled and authMode values are invalid")
    if profile["authMode"] == "api_key":
        base_url = profile.get("baseUrl")
        if not isinstance(base_url, str) or urlparse(base_url).scheme not in {"http", "https"}:
            raise ProfileCatalogError("API-key profiles need an HTTP baseUrl")
        environment_name = profile.get("apiKeyEnv")
        if not isinstance(environment_name, str) or not _ENV_NAME.fullmatch(environment_name):
            raise ProfileCatalogError("API-key profiles need a valid apiKeyEnv")
    for name in ("baseUrl", "wireApi", "apiKeyEnv", "model", "reasoningEffort", "reviewModel"):
        if name in profile and not isinstance(profile[name], str):
            raise ProfileCatalogError(f"Profile {name} must be text")
    if "configOverrides" in profile and not isinstance(profile["configOverrides"], dict):
        raise ProfileCatalogError("configOverrides must be an object")
    return profile


def _validate_catalog(catalog: object) -> dict[str, object]:
    if not isinstance(catalog, dict) or set(catalog) != {"profiles"}:
        raise ProfileCatalogError("Catalog must contain only profiles")
    profiles = catalog["profiles"]
    if not isinstance(profiles, list):
        raise ProfileCatalogError("Catalog profiles must be a list")
    validated = [_validate_profile(profile) for profile in profiles]
    if len({profile["id"] for profile in validated}) != len(validated):
        raise ProfileCatalogError("Profile ids must be unique")
    return {"profiles": validated}


def load_catalog(path: Path) -> dict[str, object]:
    try:
        catalog = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ProfileCatalogError("Profile catalog is missing or invalid") from error
    return _validate_catalog(catalog)


def save_catalog(path: Path, catalog: dict[str, object]) -> None:
    validated = _validate_catalog(catalog)
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
