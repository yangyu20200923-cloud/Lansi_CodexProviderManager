import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PACKAGE_ROOT))

from profile_catalog import ProfileCatalogError, load_catalog, save_catalog
from switch_provider import render_custom_profile_config, switch_custom_profile


class ProfileCatalogTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name) / "profiles.json"

    def tearDown(self):
        self.temporary.cleanup()

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


if __name__ == "__main__":
    unittest.main()
