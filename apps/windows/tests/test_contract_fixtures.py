import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "apps" / "windows"))

from switch_provider import render_config


class ContractFixtureTests(unittest.TestCase):
    def test_openai_render_matches_shared_compatibility_fixture(self):
        base = (ROOT / "spec/config-fixtures/base-config.toml").read_text(encoding="utf-8")
        rendered = render_config(base, "openai")

        self.assertIn('model = "gpt-5.6-sol"', rendered)
        self.assertIn('model_provider = "openai"', rendered)
        self.assertNotIn("[model_providers.openai]", rendered)
        self.assertNotIn("[model_providers.qilin]", rendered)
        self.assertNotIn("[model_providers.vectorengine]", rendered)
        self.assertNotIn("qilin", rendered.lower())
        self.assertNotIn("vectorengine", rendered.lower())
        self.assertIn("[model_providers.custom]", rendered)
        self.assertIn('name = "Synthetic provider"', rendered)
        self.assertIn("[plugins.'fixture@local']", rendered)
        self.assertIn("[mcp_servers.fixture]", rendered)
        self.assertIn("[history]", rendered)
        self.assertIn('persistence = "save-all"', rendered)


if __name__ == "__main__":
    unittest.main()
