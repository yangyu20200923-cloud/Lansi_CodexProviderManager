import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = PACKAGE_ROOT.parents[1]
sys.path.insert(0, str(PACKAGE_ROOT))

from profile_catalog import (
    MAX_MANAGED_MODELS,
    ProfileCatalogError,
    _codex_model,
    build_managed_model_catalog,
    codex_reasoning_efforts,
    fetch_codex_model_catalog,
    fetch_models,
    load_catalog,
    save_catalog,
    save_codex_model_catalog,
)
from switch_provider import render_custom_profile_config, switch_custom_profile


class ProfileCatalogTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name) / "profiles.json"

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def _models_response(payload):
        response = MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = json.dumps(payload).encode("utf-8")
        return response

    def test_standard_openai_model_list_is_adapted_to_codex_catalog(self):
        response = self._models_response(
            {"object": "list", "data": [{"id": "fixture-model", "object": "model"}]}
        )

        with patch("profile_catalog.urllib.request.urlopen", return_value=response):
            catalog = fetch_codex_model_catalog(
                "https://api.example.invalid/v1", "synthetic-key", "fixture-model"
            )

        self.assertEqual([item["slug"] for item in catalog["models"]], ["fixture-model"])
        model = catalog["models"][0]
        self.assertEqual(model["display_name"], "Fixture Model")
        self.assertEqual(model["shell_type"], "default")
        self.assertTrue(model["support_verbosity"])
        self.assertTrue(model["supports_parallel_tool_calls"])
        self.assertIn("model_messages", model)
        self.assertIn("token_budget", model["model_messages"])

    def test_codex_model_catalog_response_is_safely_normalised(self):
        response = self._models_response(
            {"models": [{"slug": "fixture-model", "display_name": "Untrusted name", "base_instructions": "untrusted"}]}
        )

        with patch("profile_catalog.urllib.request.urlopen", return_value=response):
            catalog = fetch_codex_model_catalog(
                "https://api.example.invalid/v1", "synthetic-key", "fixture-model"
            )

        self.assertEqual(catalog["models"][0]["display_name"], "Fixture Model")
        self.assertNotIn("base_instructions", catalog["models"][0])

    def test_managed_catalog_renders_only_selected_models_and_primary_model(self):
        catalog = build_managed_model_catalog(
            ["gpt-5.5", "gpt-5.6-sol", "gpt-5.5"],
            "gpt-5.6-terra",
        )

        self.assertEqual(
            [item["slug"] for item in catalog["models"]],
            ["gpt-5.6-terra", "gpt-5.5", "gpt-5.6-sol"],
        )

    def test_fetch_models_accepts_the_same_standard_response_shapes_as_the_picker(self):
        for payload in (
            {"data": [{"id": "data-model"}]},
            {"models": [{"slug": "slug-model"}]},
            [{"id": "array-model"}],
        ):
            with self.subTest(payload=payload), patch(
                "profile_catalog._request_models_payload", return_value=payload
            ):
                self.assertEqual(fetch_models("https://api.example.invalid/v1", "synthetic-key"), [
                    "data-model" if "data" in payload else "slug-model" if isinstance(payload, dict) else "array-model"
                ])

    def test_profile_catalog_rejects_more_than_managed_model_limit(self):
        profile = {
            "id": "70a1d044-7be6-440b-bcd4-e1499dd0fb9b",
            "name": "Too Many Models",
            "enabled": True,
            "authMode": "api_key",
            "baseUrl": "https://api.example.invalid/v1",
            "wireApi": "responses",
            "apiKeyEnv": "EXAMPLE_PROVIDER_API_KEY",
            "model": "model-0",
            "models": [f"model-{index}" for index in range(MAX_MANAGED_MODELS + 1)],
            "configOverrides": {},
        }

        with self.assertRaisesRegex(ProfileCatalogError, "cannot exceed"):
            save_catalog(self.path, {"profiles": [profile]})

    def test_codex_catalog_rejects_unlisted_selected_model(self):
        response = self._models_response(
            {"models": [{"slug": "another-model", "display_name": "Another Model"}]}
        )

        with patch("profile_catalog.urllib.request.urlopen", return_value=response):
            with self.assertRaisesRegex(ProfileCatalogError, "所选模型"):
                fetch_codex_model_catalog(
                    "https://api.example.invalid/v1", "synthetic-key", "fixture-model"
                )

    def test_codex_catalog_curates_messy_upstream_lists(self):
        response = self._models_response(
            {"data": [
                {"id": "gpt-5-chat"},
                {"id": "qwen3-coder"},
                {"id": "o1"},
                {"id": "suno_lyrics"},
                {"id": "doubao-seedream-5-0-260128"},
                {"id": "text-embedding-3-large"},
                {"id": "gpt-5.5"},
            ]}
        )

        with patch("profile_catalog.urllib.request.urlopen", return_value=response):
            catalog = fetch_codex_model_catalog(
                "https://api.example.invalid/v1", "synthetic-key", "gpt-5.5"
            )

        self.assertEqual(
            [item["slug"] for item in catalog["models"]],
            ["gpt-5.5", "gpt-5-chat", "qwen3-coder", "o1"],
        )

    def test_custom_catalog_advertises_structured_reasoning_levels(self):
        standard = _codex_model("fixture-model", 1)
        deepseek = _codex_model("deepseek-reasoner", 2)

        self.assertEqual(codex_reasoning_efforts("fixture-model"), ("none", "low", "medium", "high", "xhigh", "max"))
        self.assertEqual(codex_reasoning_efforts("DeepSeek-V4-Pro"), ("low", "medium", "high", "xhigh", "max"))
        self.assertEqual(standard["default_reasoning_level"], "low")
        self.assertEqual(deepseek["default_reasoning_level"], "high")
        self.assertEqual(
            [option["effort"] for option in standard["supported_reasoning_levels"]],
            ["none", "low", "medium", "high", "xhigh", "max"],
        )
        self.assertEqual(
            [option["effort"] for option in deepseek["supported_reasoning_levels"]],
            ["low", "medium", "high", "xhigh", "max"],
        )
        self.assertEqual(deepseek["model_messages"]["token_budget"]["reminder_threshold_tokens"], 6144)

    def test_codex_catalog_is_saved_atomically_without_secrets(self):
        catalog_path = Path(self.temporary.name) / "model-catalogs" / "fixture.json"
        catalog = {"models": [{"slug": "fixture-model", "display_name": "fixture-model"}]}

        save_codex_model_catalog(catalog_path, catalog)

        self.assertEqual(json.loads(catalog_path.read_text(encoding="utf-8")), catalog)
        self.assertNotIn("synthetic-key", catalog_path.read_text(encoding="utf-8"))

    def test_round_trip_keeps_custom_non_secret_profile_fields(self):
        catalog = {
            "profiles": [
                {
                    "id": "70a1d044-7be6-440b-bcd4-e1499dd0fb9b",
                    "name": "Example Provider",
                    "enabled": True,
                    "authMode": "api_key",
                    "baseUrl": "https://api.example.invalid/v1",
                    "wireApi": "responses",
                    "apiKeyEnv": "EXAMPLE_PROVIDER_API_KEY",
                    "model": "example-model",
                    "reasoningEffort": "high",
                    "reviewModel": "example-review-model",
                    "configOverrides": {},
                }
            ]
        }

        save_catalog(self.path, catalog)

        self.assertEqual(load_catalog(self.path), catalog)
        stored_profile = json.loads(self.path.read_text(encoding="utf-8"))["profiles"][0]
        self.assertNotIn("apiKey", stored_profile)

    def test_rejects_secret_or_unknown_profile_fields(self):
        self.path.write_text(
            json.dumps(
                {
                    "profiles": [
                        {
                            "id": "70a1d044-7be6-440b-bcd4-e1499dd0fb9b",
                            "name": "Unsafe Provider",
                            "enabled": True,
                            "authMode": "api_key",
                            "baseUrl": "https://api.example.invalid/v1",
                            "apiKeyEnv": "EXAMPLE_PROVIDER_API_KEY",
                            "apiKey": "synthetic-secret-value",
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )

        with self.assertRaises(ProfileCatalogError):
            load_catalog(self.path)

    def test_custom_profile_renders_a_stable_provider_table(self):
        profile = {
            "id": "70a1d044-7be6-440b-bcd4-e1499dd0fb9b",
            "name": "Example Provider",
            "enabled": True,
            "authMode": "api_key",
            "baseUrl": "https://api.example.invalid/v1",
            "wireApi": "responses",
            "apiKeyEnv": "EXAMPLE_PROVIDER_API_KEY",
            "model": "example-model",
        }

        provider_key, rendered = render_custom_profile_config('model = "old"\n', profile)

        self.assertEqual(provider_key, "custom_70a1d0447be6")
        self.assertIn(f'model_provider = "{provider_key}"', rendered)
        self.assertIn(f'[model_providers.{provider_key}]', rendered)
        self.assertIn('env_key = "EXAMPLE_PROVIDER_API_KEY"', rendered)

    def test_custom_profile_uses_the_existing_safe_switch_path(self):
        config = Path(self.temporary.name) / "config.toml"
        config.write_text('model = "old"\nmodel_provider = "openai"\n', encoding="utf-8")
        profile = {
            "id": "70a1d044-7be6-440b-bcd4-e1499dd0fb9b", "name": "Example Provider",
            "enabled": True, "authMode": "api_key", "baseUrl": "https://api.example.invalid/v1",
            "apiKeyEnv": "EXAMPLE_PROVIDER_API_KEY", "model": "example-model",
        }

        with patch("switch_provider._codex_processes", return_value=()):
            result = switch_custom_profile(profile, config, None)

        self.assertTrue(result["verified_config"])
        self.assertIn('model_provider = "custom_70a1d0447be6"', config.read_text(encoding="utf-8"))

    def run_catalog_cli(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(PACKAGE_ROOT / "profile_catalog.py"), *arguments],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_cli_removes_only_the_selected_profile_without_upsert_fields(self):
        common = ["--catalog", str(self.path)]
        fields = [
            "--name", "Example Provider",
            "--base-url", "https://api.example.invalid/v1",
            "--wire-api", "responses",
            "--api-key-env", "EXAMPLE_PROVIDER_API_KEY",
            "--model", "example-model",
        ]
        first = "70a1d044-7be6-440b-bcd4-e1499dd0fb9b"
        second = "8c29df1a-60a8-4f50-ad4f-960137606092"
        self.assertEqual(self.run_catalog_cli(*common, "--id", first, *fields).returncode, 0)
        self.assertEqual(self.run_catalog_cli(*common, "--id", second, *fields).returncode, 0)

        removed = self.run_catalog_cli(*common, "--id", first, "--remove")

        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertEqual([profile["id"] for profile in load_catalog(self.path)["profiles"]], [second])

    def test_cli_rejects_an_incomplete_upsert(self):
        result = self.run_catalog_cli(
            "--catalog", str(self.path),
            "--id", "70a1d044-7be6-440b-bcd4-e1499dd0fb9b",
            "--name", "Incomplete Provider",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("upsert requires", result.stderr)

    def test_cli_exports_one_non_secret_profile_and_reports_its_id(self):
        profile_id = "70a1d044-7be6-440b-bcd4-e1499dd0fb9b"
        export_path = Path(self.temporary.name) / "provider.lansi-profile.json"
        fields = [
            "--name", "Example Provider",
            "--base-url", "https://api.example.invalid/v1",
            "--wire-api", "responses",
            "--api-key-env", "EXAMPLE_PROVIDER_API_KEY",
            "--model", "example-model",
        ]
        created = self.run_catalog_cli("--catalog", str(self.path), "--id", profile_id, *fields)
        self.assertEqual(created.returncode, 0, created.stderr)

        exported = self.run_catalog_cli(
            "--catalog", str(self.path), "--id", profile_id, "--export", str(export_path)
        )

        self.assertEqual(exported.returncode, 0, exported.stderr)
        self.assertEqual(json.loads(exported.stdout), {"exportedProfileId": profile_id})
        exported_profile = load_catalog(export_path)["profiles"][0]
        self.assertEqual(exported_profile["id"], profile_id)
        self.assertNotIn("apiKey", exported_profile)

    def test_cli_imports_validated_profiles_and_reports_imported_ids(self):
        source_path = Path(self.temporary.name) / "import.lansi-profile.json"
        profile_id = "70a1d044-7be6-440b-bcd4-e1499dd0fb9b"
        save_catalog(
            source_path,
            {
                "profiles": [
                    {
                        "id": profile_id,
                        "name": "Imported Provider",
                        "enabled": True,
                        "authMode": "api_key",
                        "baseUrl": "https://api.example.invalid/v1",
                        "wireApi": "responses",
                        "apiKeyEnv": "EXAMPLE_PROVIDER_API_KEY",
                        "model": "example-model",
                    }
                ]
            },
        )

        imported = self.run_catalog_cli(
            "--catalog", str(self.path), "--import-file", str(source_path)
        )

        self.assertEqual(imported.returncode, 0, imported.stderr)
        self.assertEqual(json.loads(imported.stdout), {"importedProfileIds": [profile_id]})
        self.assertEqual(load_catalog(self.path)["profiles"][0]["id"], profile_id)

    def test_cli_rejects_secret_import_without_changing_the_catalog(self):
        existing_id = "70a1d044-7be6-440b-bcd4-e1499dd0fb9b"
        source_path = Path(self.temporary.name) / "unsafe.lansi-profile.json"
        self.run_catalog_cli(
            "--catalog", str(self.path), "--id", existing_id,
            "--name", "Existing Provider", "--base-url", "https://api.example.invalid/v1",
            "--wire-api", "responses", "--api-key-env", "EXAMPLE_PROVIDER_API_KEY",
            "--model", "example-model",
        )
        source_path.write_text(
            json.dumps({
                "profiles": [{
                    "id": "8c29df1a-60a8-4f50-ad4f-960137606092",
                    "name": "Unsafe Provider",
                    "enabled": True,
                    "authMode": "api_key",
                    "baseUrl": "https://api.example.invalid/v1",
                    "apiKeyEnv": "UNSAFE_PROVIDER_API_KEY",
                    "apiKey": "synthetic-secret-value",
                }]
            }),
            encoding="utf-8",
        )

        imported = self.run_catalog_cli(
            "--catalog", str(self.path), "--import-file", str(source_path)
        )

        self.assertNotEqual(imported.returncode, 0)
        self.assertEqual(
            [profile["id"] for profile in load_catalog(self.path)["profiles"]], [existing_id]
        )

    def test_cli_rejects_empty_import_without_changing_the_catalog(self):
        existing_id = "70a1d044-7be6-440b-bcd4-e1499dd0fb9b"
        source_path = Path(self.temporary.name) / "empty.lansi-profile.json"
        self.run_catalog_cli(
            "--catalog", str(self.path), "--id", existing_id,
            "--name", "Existing Provider", "--base-url", "https://api.example.invalid/v1",
            "--wire-api", "responses", "--api-key-env", "EXAMPLE_PROVIDER_API_KEY",
            "--model", "example-model",
        )
        save_catalog(source_path, {"profiles": []})

        imported = self.run_catalog_cli(
            "--catalog", str(self.path), "--import-file", str(source_path)
        )

        self.assertNotEqual(imported.returncode, 0)
        self.assertEqual(
            [profile["id"] for profile in load_catalog(self.path)["profiles"]], [existing_id]
        )

    def test_lcp_03_shared_fixture_preserves_all_non_secret_fields_and_renders_them(self):
        fixture_path = REPOSITORY_ROOT / "spec/fixtures/lcp-03-provider-parity.json"
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
        profile = fixture["profiles"][0]

        save_catalog(self.path, fixture)
        provider, rendered = render_custom_profile_config('model_provider = "openai"\n', profile)

        self.assertEqual(load_catalog(self.path), fixture)
        self.assertEqual(provider, "custom_35c5a9e6148b")
        self.assertIn('model = "lcp-03-model"', rendered)
        self.assertEqual(profile["models"], ["lcp-03-model", "lcp-03-fast"])
        self.assertIn('model_reasoning_effort = "high"', rendered)
        self.assertIn('review_model = "lcp-03-review-model"', rendered)
        self.assertIn('env_key = "LCP03_FIXTURE_API_KEY"', rendered)
        self.assertNotIn('"apiKey"', self.path.read_text(encoding="utf-8"))

    def test_custom_render_removes_invalid_builtin_openai_provider_override(self):
        profile = {
            "id": "35c5a9e6-148b-4ebd-b771-97cf3b04e982",
            "name": "Compatible Provider",
            "enabled": True,
            "authMode": "api_key",
            "baseUrl": "https://api.example.invalid/v1",
            "wireApi": "responses",
            "apiKeyEnv": "COMPATIBLE_PROVIDER_API_KEY",
            "model": "compatible-model",
            "configOverrides": {},
        }
        original = '''model_provider = "openai"

[model_providers.openai]
name = "invalid built-in override"
base_url = "https://api.example.invalid/v1"

[model_providers.unrelated]
name = "preserved"
'''

        _, rendered = render_custom_profile_config(original, profile)

        self.assertNotIn("[model_providers.openai]", rendered)
        self.assertIn("[model_providers.unrelated]", rendered)

    def test_cli_upsert_preserves_all_lcp_03_fields(self):
        fixture = json.loads(
            (REPOSITORY_ROOT / "spec/fixtures/lcp-03-provider-parity.json").read_text(encoding="utf-8")
        )
        profile = fixture["profiles"][0]

        result = self.run_catalog_cli(
            "--catalog", str(self.path), "--id", profile["id"], "--name", profile["name"],
            "--enabled", "false", "--auth-mode", profile["authMode"],
            "--base-url", profile["baseUrl"], "--wire-api", profile["wireApi"],
            "--api-key-env", profile["apiKeyEnv"], "--model", profile["model"],
            "--models-json", json.dumps(profile["models"]),
            "--reasoning-effort", profile["reasoningEffort"], "--review-model", profile["reviewModel"],
            "--config-overrides-json", "{}",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(load_catalog(self.path), fixture)

    def test_chatgpt_login_profile_has_no_api_key_requirement_or_rendered_reference(self):
        profile_id = "35c5a9e6-148b-4ebd-b771-97cf3b04e982"
        result = self.run_catalog_cli(
            "--catalog", str(self.path), "--id", profile_id, "--name", "ChatGPT Login",
            "--enabled", "true", "--auth-mode", "chatgpt_login", "--config-overrides-json", "{}",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        profile = load_catalog(self.path)["profiles"][0]
        _, rendered = render_custom_profile_config('model_provider = "openai"\n', profile)
        self.assertEqual(profile["authMode"], "chatgpt_login")
        self.assertNotIn("apiKeyEnv", profile)
        self.assertNotIn("env_key", rendered)
        self.assertIn("requires_openai_auth = true", rendered)

    def test_rejects_unapproved_config_overrides(self):
        with self.assertRaises(ProfileCatalogError):
            save_catalog(
                self.path,
                {"profiles": [{
                    "id": "35c5a9e6-148b-4ebd-b771-97cf3b04e982", "name": "Unsafe",
                    "enabled": True, "authMode": "api_key", "baseUrl": "https://api.example.invalid/v1",
                    "apiKeyEnv": "UNSAFE_API_KEY", "configOverrides": {"model": "unsafe"},
                }]},
            )

    def test_rejects_unsupported_wire_api_for_new_or_edited_profiles(self):
        catalog = {"profiles": [{
            "id": "35c5a9e6-148b-4ebd-b771-97cf3b04e982", "name": "Custom Wire",
            "enabled": True, "authMode": "api_key", "baseUrl": "https://api.example.invalid/v1",
            "apiKeyEnv": "CUSTOM_WIRE_API_KEY", "wireApi": "custom-responses",
        }]}

        with self.assertRaises(ProfileCatalogError):
            save_catalog(self.path, catalog)

    def test_load_migrates_legacy_wire_api_in_memory(self):
        catalog = {"profiles": [{
            "id": "35c5a9e6-148b-4ebd-b771-97cf3b04e982", "name": "Legacy Wire",
            "enabled": True, "authMode": "api_key", "baseUrl": "https://api.example.invalid/v1",
            "apiKeyEnv": "LEGACY_WIRE_API_KEY", "wireApi": "chat_completions",
        }]}
        self.path.write_text(json.dumps(catalog), encoding="utf-8")

        self.assertEqual(load_catalog(self.path)["profiles"][0]["wireApi"], "responses")


if __name__ == "__main__":
    unittest.main()
