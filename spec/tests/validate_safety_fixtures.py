#!/usr/bin/env python3
import shutil
import tempfile
import unittest
from pathlib import Path

from safety_fixture_validator import FixtureValidationError, validate_fixture


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "safety-fixtures"


class SafetyFixtureTests(unittest.TestCase):
    def copy_fixture(self) -> tuple[tempfile.TemporaryDirectory[str], Path]:
        temporary = tempfile.TemporaryDirectory()
        destination = Path(temporary.name) / "safety-fixtures"
        shutil.copytree(FIXTURE, destination)
        return temporary, destination

    def test_synthetic_fixture_matches_its_preservation_contract(self):
        snapshot = validate_fixture(FIXTURE)
        self.assertEqual(snapshot["threadRowCount"], 1)
        self.assertEqual(snapshot["sessionJsonlCount"], 1)
        self.assertEqual(snapshot["extensionFileCount"], 3)

    def test_rejects_an_extension_hash_mismatch(self):
        temporary, fixture = self.copy_fixture()
        self.addCleanup(temporary.cleanup)
        skill = fixture / "home" / "skills" / "fixture-skill" / "SKILL.md"
        skill.write_text("changed synthetic fixture\n", encoding="utf-8")
        with self.assertRaises(FixtureValidationError):
            validate_fixture(fixture)

    def test_rejects_an_unlisted_extension_file(self):
        temporary, fixture = self.copy_fixture()
        self.addCleanup(temporary.cleanup)
        extra = fixture / "home" / "plugins" / "fixture-plugin" / "extra.txt"
        extra.write_text("unexpected extension file\n", encoding="utf-8")
        with self.assertRaises(FixtureValidationError):
            validate_fixture(fixture)

    def test_rejects_credential_like_fixture_content(self):
        temporary, fixture = self.copy_fixture()
        self.addCleanup(temporary.cleanup)
        config = fixture / "home" / "config.toml"
        config.write_text(config.read_text(encoding="utf-8") + "\nvalue = \"sk-abcdefghijklmnopqrstuvwx\"\n", encoding="utf-8")
        with self.assertRaises(FixtureValidationError):
            validate_fixture(fixture)

    def test_rejects_preservation_count_drift(self):
        temporary, fixture = self.copy_fixture()
        self.addCleanup(temporary.cleanup)
        session = fixture / "home" / "sessions" / "2026" / "extra.jsonl"
        session.write_text("{\"type\":\"synthetic\"}\n", encoding="utf-8")
        with self.assertRaises(FixtureValidationError):
            validate_fixture(fixture)


if __name__ == "__main__":
    unittest.main()
