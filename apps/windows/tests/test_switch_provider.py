import json
import os
import sqlite3
import shutil
import sys
import tempfile
import time
import unittest
from contextlib import closing
from pathlib import Path
from unittest.mock import patch


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PACKAGE_ROOT))

from switch_provider import (
    PROVIDERS,
    _acquire_lock,
    _release_lock,
    render_config,
    restore_latest,
    status,
    switch_provider,
)


SAMPLE_CONFIG = '''model = "old-model"
model_provider = "custom"
model_reasoning_effort = "low"

[model_providers.custom]
name = "legacy"
base_url = "https://www.qilinapi.com/v1"
wire_api = "responses"
experimental_bearer_token = "legacy-inline-secret"

[model_providers.unrelated]
name = "keep-me"
base_url = "https://example.invalid/v1"
experimental_bearer_token = "unrelated-secret"

[plugins.'sites@openai-bundled']
enabled = true

[mcp_servers.example]
command = "example.exe"
'''


class RenderConfigTests(unittest.TestCase):
    def test_openai_uses_chatgpt_login_instead_of_an_api_key_variable(self):
        self.assertIsNone(PROVIDERS["openai"]["env_key"])

    def test_render_qilin_preserves_unrelated_config_and_removes_managed_inline_secret(self):
        rendered = render_config(SAMPLE_CONFIG, "qilin")

        self.assertIn('model_provider = "qilin"', rendered)
        self.assertIn('model = "gpt-5.6-sol"', rendered)
        self.assertIn('[model_providers.qilin]', rendered)
        self.assertIn('env_key = "QILIN_API_KEY"', rendered)
        self.assertIn('[model_providers.vectorengine]', rendered)
        self.assertIn('[plugins.\'sites@openai-bundled\']', rendered)
        self.assertIn('[mcp_servers.example]', rendered)
        self.assertIn('[model_providers.unrelated]', rendered)
        self.assertIn('experimental_bearer_token = "unrelated-secret"', rendered)
        self.assertNotIn('legacy-inline-secret', rendered)
        self.assertNotIn('[model_providers.custom]', rendered)

    def test_render_openai_uses_builtin_provider_and_save_all_history(self):
        rendered = render_config(SAMPLE_CONFIG, "openai")

        self.assertIn('model_provider = "openai"', rendered)
        self.assertIn('[history]', rendered)
        self.assertIn('persistence = "save-all"', rendered)
        self.assertIn('[model_providers.qilin]', rendered)
        self.assertIn('[model_providers.vectorengine]', rendered)

    def test_vectorengine_uses_cn_base_url(self):
        rendered = render_config(SAMPLE_CONFIG, "vectorengine")

        self.assertIn('base_url = "https://api.vectorengine.cn/v1"', rendered)
        self.assertNotIn('base_url = "https://api.vectorengine.ai/v1"', rendered)

    def test_invalid_provider_is_rejected(self):
        with self.assertRaises(ValueError):
            render_config(SAMPLE_CONFIG, "unknown")


class SwitchTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.config = self.root / "config.toml"
        self.state = self.root / "state_5.sqlite"
        self.config.write_text(SAMPLE_CONFIG, encoding="utf-8")
        with closing(sqlite3.connect(self.state)) as connection:
            connection.execute(
                "CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT, title TEXT, preview TEXT)"
            )
            connection.execute(
                "INSERT INTO threads VALUES ('one', 'custom', 'Existing task', '')"
            )
            connection.commit()

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_switch_creates_backups_and_updates_existing_threads(self):
        result = switch_provider("vectorengine", self.config, self.state)

        self.assertEqual(result["provider"], "vectorengine")
        self.assertTrue(result["verified_config"])
        self.assertTrue(result["verified_threads"])
        self.assertEqual(result["synced_threads"], 1)
        backup_dir = self.root / "backups" / "windows-provider-switch"
        self.assertTrue((backup_dir / result["config_backup"]).exists())
        self.assertTrue((backup_dir / result["state_backup"]).exists())
        self.assertTrue((backup_dir / result["backup_manifest"]).exists())
        self.assertNotIn(str(self.root), result["config_backup"])
        self.assertIn('model_provider = "vectorengine"', self.config.read_text(encoding="utf-8"))
        with closing(sqlite3.connect(self.state)) as connection:
            provider, preview = connection.execute(
                "SELECT model_provider, preview FROM threads WHERE id = 'one'"
            ).fetchone()
        self.assertEqual(provider, "vectorengine")
        self.assertEqual(preview, "Existing task")

    def test_dry_run_does_not_write_or_create_backups(self):
        original_config = self.config.read_bytes()
        original_state = self.state.read_bytes()

        result = switch_provider("qilin", self.config, self.state, dry_run=True)

        self.assertTrue(result["dry_run"])
        self.assertEqual(self.config.read_bytes(), original_config)
        self.assertEqual(self.state.read_bytes(), original_state)
        self.assertFalse((self.root / "backups").exists())

    def test_switch_and_status_redact_config_and_database_paths(self):
        switch = switch_provider("qilin", self.config, self.state)
        current_status = status(self.config, self.state)

        for result in (switch, current_status):
            self.assertNotIn(str(self.root), result["config"])
            self.assertNotIn(str(self.root), result["state_db"])
        self.assertEqual(switch["config"], "config.toml")
        self.assertEqual(switch["state_db"], "state_5.sqlite")

    def test_lock_records_owner_metadata(self):
        lock_dir = self.root / ".windows-provider-switch.lock"

        owner_id = _acquire_lock(lock_dir, timeout_seconds=0)

        metadata = json.loads((lock_dir / "owner.json").read_text(encoding="utf-8"))
        self.assertEqual(metadata["owner_id"], owner_id)
        self.assertEqual(metadata["pid"], os.getpid())
        _release_lock(lock_dir, owner_id)
        self.assertFalse(lock_dir.exists())

    def test_lock_does_not_reclaim_old_directory_by_age_alone(self):
        lock_dir = self.root / ".windows-provider-switch.lock"
        lock_dir.mkdir()
        old_timestamp = time.time() - 120
        os.utime(lock_dir, (old_timestamp, old_timestamp))

        with self.assertRaises(RuntimeError):
            _acquire_lock(lock_dir, timeout_seconds=0)

    def test_restore_latest_restores_matching_config_and_database(self):
        switch = switch_provider("qilin", self.config, self.state)
        backup_dir = self.root / "backups" / "windows-provider-switch"
        (backup_dir / switch["config_backup"]).write_text("tampered\n", encoding="utf-8")
        self.config.write_text('model_provider = "damaged"\n', encoding="utf-8")
        with closing(sqlite3.connect(self.state)) as connection:
            connection.execute("UPDATE threads SET model_provider = 'damaged'")
            connection.commit()

        with self.assertRaises(RuntimeError):
            restore_latest(self.config, self.state)

    def test_restore_latest_recovers_valid_backups(self):
        switch_provider("qilin", self.config, self.state)
        self.config.write_text('model_provider = "damaged"\n', encoding="utf-8")
        with closing(sqlite3.connect(self.state)) as connection:
            connection.execute("UPDATE threads SET model_provider = 'damaged'")
            connection.commit()

        result = restore_latest(self.config, self.state)

        self.assertTrue(result["restored"])
        self.assertNotIn(str(self.root), result["config_backup"])
        self.assertNotIn(str(self.root), result["state_backup"])
        backup_dir = self.root / "backups" / "windows-provider-switch"
        self.assertTrue((backup_dir / result["config_backup"]).exists())
        self.assertTrue((backup_dir / result["state_backup"]).exists())
        self.assertEqual(self.config.read_text(encoding="utf-8"), SAMPLE_CONFIG)
        with closing(sqlite3.connect(self.state)) as connection:
            provider = connection.execute("SELECT model_provider FROM threads WHERE id = 'one'").fetchone()[0]
        self.assertEqual(provider, "custom")

    def test_restore_latest_rejects_corrupted_config_readback(self):
        switch_provider("qilin", self.config, self.state)
        self.config.write_text('model_provider = "damaged"\n', encoding="utf-8")
        original_copy2 = shutil.copy2

        def corrupt_restored_config(source, destination, *args, **kwargs):
            result = original_copy2(source, destination, *args, **kwargs)
            if Path(source).name.startswith("config-"):
                Path(destination).write_text("corrupted\n", encoding="utf-8")
            return result

        with patch("switch_provider.shutil.copy2", side_effect=corrupt_restored_config):
            with self.assertRaises(RuntimeError):
                restore_latest(self.config, self.state)


if __name__ == "__main__":
    unittest.main()
