#!/usr/bin/env python3
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ProfileSchemaTests(unittest.TestCase):
    def test_schema_exposes_non_secret_profile_contract(self):
        schema = json.loads((ROOT / "provider-profile.schema.json").read_text())
        required = set(schema["required"])
        self.assertTrue({"id", "name", "enabled", "authMode"}.issubset(required))
        self.assertNotIn("apiKey", schema["properties"])
        self.assertEqual(schema["properties"]["authMode"]["enum"], ["chatgpt_login", "api_key"])

    def test_examples_are_synthetic_and_conform_to_schema_shape(self):
        for name in ("openai-chatgpt.profile.json", "openai-compatible.profile.json"):
            profile = json.loads((ROOT / "examples" / name).read_text())
            self.assertIn(profile["authMode"], {"chatgpt_login", "api_key"})
            self.assertNotIn("apiKey", profile)
            self.assertNotIn("token", profile)


if __name__ == "__main__":
    unittest.main()
