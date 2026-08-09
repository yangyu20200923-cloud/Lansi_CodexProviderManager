import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "apps" / "windows"))

from switch_provider import render_config


class ContractFixtureTests(unittest.TestCase):
    def test_qilin_render_matches_shared_compatibility_fixture(self):
        base = (ROOT / "spec/config-fixtures/base-config.toml").read_text(encoding="utf-8")
        expected = (ROOT / "spec/config-fixtures/expected-compatible.toml").read_text(encoding="utf-8")
        self.assertEqual(render_config(base, "qilin"), expected)


if __name__ == "__main__":
    unittest.main()
