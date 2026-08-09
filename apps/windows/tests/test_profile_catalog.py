import json
import sys
import tempfile
import unittest
from pathlib import Path


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PACKAGE_ROOT))

from profile_catalog import ProfileCatalogError, load_catalog, save_catalog


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


if __name__ == "__main__":
    unittest.main()
