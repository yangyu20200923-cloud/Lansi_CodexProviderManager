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

import switch_provider as switch_provider_module
from switch_provider import (
    CodexProcessProbeError,
    CodexRunningError,
    PROVIDERS,
    _CodexProcessProbeError,
    _acquire_lock,
    _codex_processes,
    _prune_backups,
    _release_lock,
    request_codex_graceful_shutdown,
    render_config,
    render_custom_profile_config,
    restore_latest,
    status,
    switch_provider,
)


SAMPLE_CONFIG = '''model = "old-model"
model_provider = "custom"
model_reasoning_effort = "low"

[model_providers.openai]
name = "invalid built-in override"
base_url = "https://api.example.invalid/v1"

[model_providers.custom]
name = "unrelated-user"
base_url = "https://api.example.invalid/v1"
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

    def test_only_openai_is_a_builtin_provider(self):
        self.assertEqual(
            [key for key in PROVIDERS if not key.startswith("custom_")],
            ["openai"],
        )
        self.assertEqual(PROVIDERS["openai"]["display_name"], "OpenAI")

    def test_shipped_module_has_no_third_party_provider_markers(self):
        source = Path(switch_provider_module.__file__).read_text(encoding="utf-8").lower()

        for marker in (
            "qilin",
            "vectorengine",
            "qilinapi",
            "qilin_api_key",
            "vectorengine_api_key",
        ):
            self.assertNotIn(marker, source)

    def test_render_openai_preserves_unrelated_config_without_bundled_third_party_tables(self):
        rendered = render_config(SAMPLE_CONFIG, "openai")

        self.assertIn('model_provider = "openai"', rendered)
        self.assertIn('model = "gpt-5.6-sol"', rendered)
        self.assertNotIn("[model_providers.openai]", rendered)
        self.assertNotIn("[model_providers.qilin]", rendered)
        self.assertNotIn("[model_providers.vectorengine]", rendered)
        self.assertNotIn("qilin", rendered.lower())
        self.assertNotIn("vectorengine", rendered.lower())
        self.assertNotIn("QILIN_API_KEY", rendered)
        self.assertNotIn("VECTORENGINE_API_KEY", rendered)
        self.assertIn("[plugins.'sites@openai-bundled']", rendered)
        self.assertIn("[mcp_servers.example]", rendered)
        self.assertIn('[model_providers.unrelated]', rendered)
        self.assertIn('[model_providers.custom]', rendered)
        self.assertIn('experimental_bearer_token = "legacy-inline-secret"', rendered)
        self.assertIn('experimental_bearer_token = "unrelated-secret"', rendered)

    def test_render_openai_uses_builtin_provider_and_save_all_history(self):
        rendered = render_config(SAMPLE_CONFIG, "openai")

        self.assertIn('model_provider = "openai"', rendered)
        self.assertNotIn("[model_providers.openai]", rendered)
        self.assertIn('[history]', rendered)
        self.assertIn('persistence = "save-all"', rendered)
        self.assertNotIn("[model_providers.qilin]", rendered)
        self.assertNotIn("[model_providers.vectorengine]", rendered)

    def test_legacy_third_party_provider_ids_are_rejected(self):
        for provider in ("qilin", "vectorengine"):
            with self.assertRaises(ValueError):
                render_config(SAMPLE_CONFIG, provider)

    def test_invalid_provider_is_rejected(self):
        with self.assertRaises(ValueError):
            render_config(SAMPLE_CONFIG, "unknown")

    def test_render_does_not_duplicate_model_key_when_config_starts_with_bom(self):
        rendered = render_config("\ufeff" + SAMPLE_CONFIG, "openai")

        self.assertEqual(sum(line.startswith("model = ") for line in rendered.splitlines()), 1)
        self.assertIn('model = "gpt-5.6-sol"', rendered)
        self.assertNotIn('model = "old-model"', rendered)

    def test_render_removes_legacy_openai_override_that_current_codex_rejects(self):
        legacy = (
            SAMPLE_CONFIG
            + '\n[model_providers.openai]\nname = "legacy"\nbase_url = "https://api.openai.com/v1"\nwire_api = "responses"\n'
        )

        rendered = render_config(legacy, "openai")

        self.assertNotIn("[model_providers.openai]", rendered)
        self.assertIn('model_provider = "openai"', rendered)

    def test_render_custom_profile_removes_legacy_openai_override_too(self):
        legacy = SAMPLE_CONFIG + '\n[model_providers.openai]\nname = "legacy"\n'

        _provider, rendered = render_custom_profile_config(
            legacy,
            {
                "id": "00000000-0000-0000-0000-000000000001",
                "name": "Fixture",
                "enabled": True,
                "authMode": "api_key",
                "baseUrl": "https://api.example.invalid/v1",
                "wireApi": "responses",
                "apiKeyEnv": "FIXTURE_KEY",
                "model": "fixture-model",
                "models": ["fixture-model"],
            },
        )

        self.assertNotIn("[model_providers.openai]", rendered)
        self.assertIn("[model_providers.custom_000000000000]", rendered)

    def test_custom_render_sets_local_model_catalog_and_builtin_removes_it(self):
        profile = {
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "Fixture",
            "enabled": True,
            "authMode": "api_key",
            "baseUrl": "https://api.example.invalid/v1",
            "wireApi": "responses",
            "apiKeyEnv": "FIXTURE_API_KEY",
            "model": "fixture-model",
        }
        catalog_path = Path("C:/fixture/model-catalog.json")

        _, custom = render_custom_profile_config(
            'model_provider = "openai"\n', profile, model_catalog_path=catalog_path
        )
        builtin = render_config(custom, "openai")

        self.assertIn("model_catalog_json", custom)
        self.assertIn(json.dumps(str(catalog_path.resolve())), custom)
        self.assertNotIn("model_catalog_json", builtin)


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
        self._real_assert_quiescent = switch_provider_module._assert_codex_quiescent
        self._guard_patcher = patch("switch_provider._assert_codex_quiescent")
        self._guard_patcher.start()
        self.addCleanup(self._guard_patcher.stop)

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_switch_creates_backups_and_preserves_existing_thread_routing(self):
        result = switch_provider("openai", self.config, self.state)

        self.assertEqual(result["provider"], "openai")
        self.assertTrue(result["verified_config"])
        self.assertTrue(result["verified_threads"])
        self.assertEqual(result["synced_threads"], 0)
        self.assertEqual(
            result["thread_routing"],
            {"verified": True, "total": 1, "provider_count": 0, "other_count": 1},
        )
        self.assertEqual(result["connection"]["provider"], "openai")
        self.assertEqual(result["connection"]["wire_api"], "responses")
        backup_dir = self.root / "backups" / "windows-provider-switch"
        self.assertTrue((backup_dir / result["config_backup"]).exists())
        self.assertTrue((backup_dir / result["state_backup"]).exists())
        self.assertTrue((backup_dir / result["backup_manifest"]).exists())
        self.assertIsNone(result["preserved_backup"])
        self.assertNotIn(str(self.root), result["config_backup"])
        self.assertIn('model_provider = "openai"', self.config.read_text(encoding="utf-8"))
        with closing(sqlite3.connect(self.state)) as connection:
            provider, preview = connection.execute(
                "SELECT model_provider, preview FROM threads WHERE id = 'one'"
            ).fetchone()
        self.assertEqual(provider, "custom")
        self.assertEqual(preview, "")

    def test_switch_writes_phase_log_to_state_switch_log(self):
        result = switch_provider("openai", self.config, self.state)

        self.assertTrue(result["verified_config"])
        log_path = self.root / "state" / "switch.log"
        self.assertTrue(log_path.exists())
        log = log_path.read_text(encoding="utf-8")
        self.assertIn("switch start: target=openai", log)
        self.assertIn("normalized", log)
        self.assertIn("backup created", log)
        self.assertIn("switch complete: target=openai", log)
        self.assertNotIn("switch failed", log)

    def test_switch_clears_previous_api_key_and_reports_live_phases(self):
        old_key_name = "LCP_TEST_OLD_API_KEY"
        self.config.write_text(
            'model = "old-model"\nmodel_provider = "custom"\n'
            '[model_providers.custom]\nname = "Old"\nenv_key = "LCP_TEST_OLD_API_KEY"\n',
            encoding="utf-8",
        )
        os.environ[old_key_name] = "synthetic-old-key"
        phases = []
        try:
            with patch("switch_provider._codex_processes", return_value=()), patch(
                "switch_provider.launch_codex_desktop", return_value={"requested": False, "verified": True}
            ):
                result = switch_provider(
                    "openai",
                    self.config,
                    self.state,
                    phase_callback=lambda phase, message: phases.append((phase, message)),
                )
        finally:
            os.environ.pop(old_key_name, None)

        self.assertTrue(result["verified_provider"])
        self.assertTrue(result["old_api_key_cleared"])
        self.assertEqual(os.environ.get(old_key_name), None)
        self.assertEqual(
            [phase for phase, _message in phases],
            ["stopping", "normalizing", "backing_up", "applying", "verifying", "launching", "complete"],
        )

    def test_switch_keeps_legacy_session_provider_names_resolvable(self):
        session = self.root / "sessions" / "2026" / "fixture.jsonl"
        session.parent.mkdir(parents=True, exist_ok=True)
        session.write_text(
            '{"type":"session_meta","payload":{"type":"session_meta","model_provider":"qilin"}}\n',
            encoding="utf-8",
        )

        result = switch_provider("openai", self.config, self.state)

        self.assertTrue(result["verified_config"])
        rendered = self.config.read_text(encoding="utf-8")
        self.assertIn("[model_providers.qilin]", rendered)
        self.assertIn("requires_openai_auth = true", rendered)

    def test_launch_uses_a_fresh_environment_without_the_previous_key(self):
        old_key_name = "LCP_TEST_OLD_API_KEY"
        new_key_name = "LCP_TEST_NEW_API_KEY"
        os.environ[old_key_name] = "synthetic-old-key"
        os.environ[new_key_name] = "synthetic-new-key"
        executable = self.root / "Codex.exe"
        executable.write_text("fixture", encoding="utf-8")
        try:
            with patch("switch_provider.os.name", "nt"), patch(
                "switch_provider._installed_codex_executable", return_value=executable
            ), patch("switch_provider._codex_processes", side_effect=[(), ("Codex.exe",)]), patch(
                "switch_provider.subprocess.Popen"
            ) as launch:
                result = switch_provider_module.launch_codex_desktop(
                    target_env_key=new_key_name,
                    previous_env_key=old_key_name,
                )
        finally:
            os.environ.pop(old_key_name, None)
            os.environ.pop(new_key_name, None)

        self.assertTrue(result["verified"])
        environment = launch.call_args.kwargs["env"]
        self.assertNotIn(old_key_name, environment)
        self.assertEqual(environment[new_key_name], "synthetic-new-key")

    def test_prune_backups_keeps_only_newest_five_groups(self):
        backup_dir = self.root / "backups" / "windows-provider-switch"
        backup_dir.mkdir(parents=True)
        for index in range(8):
            stamp = f"20260817-{index:02d}0000-000000"
            (backup_dir / f"config-{stamp}.toml").write_text(f"model = \"m{index}\"\n", encoding="utf-8")
            (backup_dir / f"manifest-{stamp}.json").write_text("{}", encoding="utf-8")

        removed = _prune_backups(backup_dir)

        self.assertEqual(removed, 3)
        remaining = sorted(path.name for path in backup_dir.iterdir() if path.name.startswith("config-"))
        self.assertEqual(len(remaining), 5)
        self.assertIn("config-20260817-070000-000000.toml", remaining)
        self.assertNotIn("config-20260817-000000-000000.toml", remaining)

    def test_prune_backups_honors_byte_limit(self):
        backup_dir = self.root / "backups" / "windows-provider-switch"
        backup_dir.mkdir(parents=True)
        for index in range(4):
            stamp = f"20260817-{index:02d}0000-000000"
            (backup_dir / f"config-{stamp}.toml").write_text("x" * 5_000, encoding="utf-8")

        removed = _prune_backups(backup_dir, max_count=10, max_bytes=6_000)

        self.assertEqual(removed, 3)
        remaining = [p for p in backup_dir.iterdir() if p.suffix == ".toml"]
        self.assertEqual(len(remaining), 1)

    def test_prune_backups_removes_expired_groups(self):
        backup_dir = self.root / "backups" / "windows-provider-switch"
        backup_dir.mkdir(parents=True)
        old_stamp = "20260101-000000-000000"
        new_stamp = "20260817-120000-000000"
        (backup_dir / f"config-{old_stamp}.toml").write_text("old", encoding="utf-8")
        (backup_dir / f"config-{new_stamp}.toml").write_text("new", encoding="utf-8")

        removed = _prune_backups(backup_dir, max_age_days=14)

        self.assertEqual(removed, 1)
        self.assertFalse((backup_dir / f"config-{old_stamp}.toml").exists())
        self.assertTrue((backup_dir / f"config-{new_stamp}.toml").exists())

    def test_normalize_session_reasoning_clears_plaintext_content_and_is_idempotent(self):
        session = self.root / "sessions" / "2026" / "deepseek.jsonl"
        session.parent.mkdir(parents=True)
        session.write_text(
            '{"type":"session_meta","payload":{"id":"t","session_id":"t","model_provider":"custom_deepseek","cwd":"C:\\tmp"}}\n'
            '{"type":"response_item","payload":{"type":"reasoning","id":"r1","summary":[],"content":[{"type":"reasoning_text","text":"plaintext thinking"}],"encrypted_content":"c2VjcmV0"}}\n'
            '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"}]}}\n',
            encoding="utf-8",
        )

        count = switch_provider_module._normalize_session_reasoning(self.root)

        self.assertEqual(count, 1)
        lines = session.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 3)
        self.assertIn('"content": []', lines[1])
        self.assertIn('"encrypted_content": null', lines[1])
        self.assertNotIn("plaintext thinking", lines[1])
        self.assertIn('"output_text"', lines[2])
        self.assertEqual(switch_provider_module._normalize_session_reasoning(self.root), 0)

    def test_switch_normalizes_polluted_sessions_before_preservation_snapshot(self):
        session = self.root / "sessions" / "2026" / "deepseek.jsonl"
        session.parent.mkdir(parents=True)
        session.write_text(
            '{"type":"session_meta","payload":{"id":"t","session_id":"t","model_provider":"custom_deepseek","cwd":"C:\\tmp"}}\n'
            '{"type":"response_item","payload":{"type":"reasoning","id":"r1","summary":[],"content":[{"type":"reasoning_text","text":"plaintext thinking"}],"encrypted_content":"c2VjcmV0"}}\n'
            '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"}]}}\n',
            encoding="utf-8",
        )

        result = switch_provider("openai", self.config, self.state)

        self.assertTrue(result["verified_config"], result)
        self.assertEqual(result["normalized_session_items"], 1)
        lines = session.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 3)
        self.assertIn('"content": []', lines[1])
        self.assertNotIn("plaintext thinking", lines[1])

    def test_dry_run_does_not_write_or_create_backups(self):
        original_config = self.config.read_bytes()
        original_state = self.state.read_bytes()

        result = switch_provider("openai", self.config, self.state, dry_run=True)

        self.assertTrue(result["dry_run"])
        self.assertEqual(self.config.read_bytes(), original_config)
        self.assertEqual(self.state.read_bytes(), original_state)
        self.assertFalse((self.root / "backups").exists())

    def test_switch_refuses_live_codex_process_before_creating_backups(self):
        original_config = self.config.read_bytes()
        original_state = self.state.read_bytes()

        with patch(
            "switch_provider._codex_processes", return_value=("codex.exe",), create=True
        ), patch("switch_provider._assert_codex_quiescent", self._real_assert_quiescent):
            with self.assertRaises(CodexRunningError):
                switch_provider("openai", self.config, self.state)

        self.assertEqual(self.config.read_bytes(), original_config)
        self.assertEqual(self.state.read_bytes(), original_state)
        self.assertFalse((self.root / "backups").exists())

    def test_windows_process_guard_uses_tasklist_when_toolhelp_is_unavailable(self):
        with patch("switch_provider.os.name", "nt"), patch(
            "switch_provider._codex_processes_from_toolhelp",
            side_effect=_CodexProcessProbeError("unavailable"),
        ), patch("switch_provider._codex_processes_from_tasklist", return_value=()):
            self.assertEqual(_codex_processes(), ())

    def test_windows_process_guard_still_blocks_a_detected_codex_process_from_fallback(self):
        with patch("switch_provider.os.name", "nt"), patch(
            "switch_provider._codex_processes_from_toolhelp",
            side_effect=_CodexProcessProbeError("unavailable"),
        ), patch("switch_provider._codex_processes_from_tasklist", return_value=("Codex.exe",)):
            self.assertEqual(_codex_processes(), ("Codex.exe",))

    def test_windows_process_guard_fails_closed_only_when_both_probes_are_unavailable(self):
        with patch("switch_provider.os.name", "nt"), patch(
            "switch_provider._codex_processes_from_toolhelp",
            side_effect=_CodexProcessProbeError("unavailable"),
        ), patch(
            "switch_provider._codex_processes_from_tasklist",
            side_effect=_CodexProcessProbeError("unavailable"),
        ):
            with self.assertRaisesRegex(CodexProcessProbeError, "无法确认 Codex 是否已经关闭"):
                _codex_processes()

    def test_graceful_shutdown_posts_close_and_rechecks_before_switching(self):
        with patch("switch_provider._codex_processes", side_effect=[("Codex.exe",), ()]), patch(
            "switch_provider._codex_process_ids_from_toolhelp", return_value=(1234,)
        ), patch("switch_provider._post_close_to_codex_windows", return_value=1) as post_close:
            result = request_codex_graceful_shutdown(wait_seconds=0)

        post_close.assert_called_once_with((1234,))
        self.assertEqual(result, {"requested": True, "closed": True, "windows": 1})

    def test_graceful_shutdown_refuses_switch_when_codex_does_not_exit(self):
        with patch("switch_provider._codex_processes", return_value=("Codex.exe",)), patch(
            "switch_provider._codex_process_ids_from_toolhelp", return_value=(1234,)
        ), patch("switch_provider._post_close_to_codex_windows", return_value=0):
            with self.assertRaisesRegex(CodexRunningError, "未能在等待时间内正常关闭"):
                request_codex_graceful_shutdown(wait_seconds=0)

    def test_graceful_shutdown_fails_closed_when_window_lookup_is_unavailable(self):
        with patch("switch_provider._codex_processes", return_value=("Codex.exe",)), patch(
            "switch_provider._codex_process_ids_from_toolhelp",
            side_effect=_CodexProcessProbeError("unavailable"),
        ):
            with self.assertRaisesRegex(CodexProcessProbeError, "无法定位正在运行的 Codex 窗口"):
                request_codex_graceful_shutdown(wait_seconds=0)

    def test_switch_rejects_unsupported_schema_before_creating_backups(self):
        self.state.unlink()
        with closing(sqlite3.connect(self.state)) as connection:
            connection.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT)")
            connection.commit()
        original_config = self.config.read_bytes()

        with self.assertRaises(RuntimeError):
            switch_provider("openai", self.config, self.state)

        self.assertEqual(self.config.read_bytes(), original_config)
        self.assertFalse((self.root / "backups").exists())

    def test_switch_rejects_extension_mutation_without_replacing_protected_roots(self):
        session = self.root / "sessions" / "2026" / "fixture.jsonl"
        skill = self.root / "skills" / "fixture" / "SKILL.md"
        plugin = self.root / "plugins" / "fixture" / "plugin.json"
        mcp = self.root / "mcp" / "fixture.json"
        for path, content in (
            (session, '{"type":"synthetic"}\n'),
            (skill, "synthetic skill\n"),
            (plugin, '{"name":"fixture"}\n'),
            (mcp, '{"command":"fixture"}\n'),
        ):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        expected_files = {path: path.read_bytes() for path in (session, skill, plugin, mcp)}
        original_status = status

        def mutate_extension(config_path, state_db_path):
            skill.write_text("mutated\n", encoding="utf-8")
            return original_status(config_path, state_db_path)

        with patch("switch_provider.status", side_effect=mutate_extension):
            with self.assertRaises(RuntimeError):
                switch_provider("openai", self.config, self.state)

        self.assertEqual(self.config.read_text(encoding="utf-8"), SAMPLE_CONFIG)
        with closing(sqlite3.connect(self.state)) as connection:
            provider = connection.execute("SELECT model_provider FROM threads WHERE id = 'one'").fetchone()[0]
        self.assertEqual(provider, "custom")
        self.assertEqual(skill.read_text(encoding="utf-8"), "mutated\n")
        self.assertEqual(session.read_bytes(), expected_files[session])
        self.assertEqual(plugin.read_bytes(), expected_files[plugin])
        self.assertEqual(mcp.read_bytes(), expected_files[mcp])

    def test_switch_does_not_copy_the_volatile_plugin_runtime_cache(self):
        volatile = self.root / "plugins" / "cache" / "openai-primary-runtime" / "asset.json"
        volatile.parent.mkdir(parents=True, exist_ok=True)
        volatile.write_text('{"runtime":"fixture"}\n', encoding="utf-8")
        original_hash = __import__("switch_provider")._sha256

        def hash_nonvolatile(path):
            if Path(path) == volatile:
                raise OSError(3, "path not found")
            return original_hash(path)

        with patch("switch_provider.shutil.copytree", side_effect=OSError(3, "path not found")), patch(
            "switch_provider._sha256", side_effect=hash_nonvolatile
        ):
            result = switch_provider("openai", self.config, self.state)

        self.assertTrue(result["verified_config"])
        self.assertTrue(volatile.exists())

    def test_switch_and_status_redact_config_and_database_paths(self):
        switch = switch_provider("openai", self.config, self.state)
        current_status = status(self.config, self.state)

        for result in (switch, current_status):
            self.assertNotIn(str(self.root), result["config"])
            self.assertNotIn(str(self.root), result["state_db"])
        self.assertEqual(switch["config"], "config.toml")
        self.assertEqual(switch["state_db"], "state_5.sqlite")

    def test_status_reports_activity_counts_without_exposing_paths_or_content(self):
        for path, content in (
            (self.root / "sessions" / "2026" / "one.jsonl", '{"type":"fixture"}\n'),
            (self.root / "sessions" / "2026" / "two.jsonl", '{"type":"fixture"}\n'),
            (self.root / "skills" / "one" / "SKILL.md", "fixture skill\n"),
            (self.root / "skills" / "ignore.txt", "ignore\n"),
            (self.root / "plugins" / "one" / "plugin.json", '{"name":"fixture"}\n'),
            (self.root / "mcp" / "fixture.json", '{"name":"fixture"}\n'),
        ):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        self.config.write_text(SAMPLE_CONFIG + "\n[mcp_servers.second]\ncommand = \"second.exe\"\n", encoding="utf-8")

        diagnostics = status(self.config, self.state)["diagnostics"]

        self.assertEqual(diagnostics["thread_count"], 1)
        self.assertEqual(diagnostics["session_file_count"], 2)
        self.assertEqual(diagnostics["skill_count"], 1)
        self.assertEqual(diagnostics["plugin_count"], 1)
        self.assertEqual(diagnostics["mcp_server_count"], 2)
        self.assertEqual(diagnostics["mcp_file_count"], 1)
        self.assertIsNone(diagnostics["history_error"])

    def test_status_exposes_active_responses_connection_and_safe_thread_routing(self):
        self.config.write_text(
            '''model = "deepseek-v4-pro"
model_provider = "custom_0123456789ab"
model_reasoning_effort = "max"

[model_providers.custom_0123456789ab]
name = "DeepSeek"
base_url = "https://api.deepseek.com"
wire_api = "responses"
env_key = "DS_API_KEY"
experimental_bearer_token = "synthetic-secret"
''',
            encoding="utf-8",
        )

        snapshot = status(self.config, self.state)

        self.assertEqual(
            snapshot["connection"],
            {
                "model": "deepseek-v4-pro",
                "provider": "custom_0123456789ab",
                "base_url": "https://api.deepseek.com",
                "wire_api": "responses",
                "api_key_environment": "DS_API_KEY",
                "requires_openai_auth": None,
                "authentication": "环境变量 API Key",
            },
        )
        self.assertEqual(snapshot["diagnostics"]["current_provider_thread_count"], 0)
        self.assertEqual(snapshot["diagnostics"]["other_provider_thread_count"], 1)
        self.assertNotIn("synthetic-secret", json.dumps(snapshot, ensure_ascii=False))

    def test_status_reports_missing_or_incompatible_history_without_hiding_extensions(self):
        skill = self.root / "skills" / "one" / "SKILL.md"
        skill.parent.mkdir(parents=True, exist_ok=True)
        skill.write_text("fixture skill\n", encoding="utf-8")
        self.state.unlink()

        missing = status(self.config, self.state)["diagnostics"]

        self.assertIsNone(missing["thread_count"])
        self.assertEqual(missing["history_error"], "state_db_missing")
        self.assertEqual(missing["skill_count"], 1)

        with closing(sqlite3.connect(self.state)) as connection:
            connection.execute("CREATE TABLE unrelated (id TEXT)")
        incompatible = status(self.config, self.state)["diagnostics"]
        self.assertEqual(incompatible["history_error"], "threads_unavailable")
        self.assertEqual(incompatible["skill_count"], 1)

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
        switch = switch_provider("openai", self.config, self.state)
        backup_dir = self.root / "backups" / "windows-provider-switch"
        (backup_dir / switch["config_backup"]).write_text("tampered\n", encoding="utf-8")
        self.config.write_text('model_provider = "damaged"\n', encoding="utf-8")
        with closing(sqlite3.connect(self.state)) as connection:
            connection.execute("UPDATE threads SET model_provider = 'damaged'")
            connection.commit()

        with self.assertRaises(RuntimeError):
            restore_latest(self.config, self.state)

    def test_restore_latest_recovers_config_and_database_without_replacing_protected_roots(self):
        session = self.root / "sessions" / "2026" / "fixture.jsonl"
        skill = self.root / "skills" / "fixture" / "SKILL.md"
        plugin = self.root / "plugins" / "fixture" / "plugin.json"
        mcp = self.root / "mcp" / "fixture.json"
        for path, content in (
            (session, '{"type":"synthetic"}\n'),
            (skill, "synthetic skill\n"),
            (plugin, '{"name":"fixture"}\n'),
            (mcp, '{"command":"fixture"}\n'),
        ):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        switch_provider("openai", self.config, self.state)
        self.config.write_text('model_provider = "damaged"\n', encoding="utf-8")
        with closing(sqlite3.connect(self.state)) as connection:
            connection.execute("UPDATE threads SET model_provider = 'damaged'")
            connection.commit()
        skill.write_text("damaged skill\n", encoding="utf-8")
        plugin.unlink()
        (self.root / "mcp" / "new.json").write_text('{"command":"damaged"}\n', encoding="utf-8")

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
        self.assertEqual(skill.read_text(encoding="utf-8"), "damaged skill\n")
        self.assertFalse(plugin.exists())
        self.assertTrue((self.root / "mcp" / "new.json").exists())

    def test_stale_lock_from_dead_process_is_reclaimed(self):
        lock_dir = self.root / ".windows-provider-switch.lock"
        lock_dir.mkdir()
        (lock_dir / "owner.json").write_text(
            json.dumps(
                {
                    "owner_id": "stale-owner",
                    "pid": 99999999,
                    "created_at": "2020-01-01T00:00:00+00:00",
                }
            ),
            encoding="utf-8",
        )

        owner_id = _acquire_lock(lock_dir, timeout_seconds=1)

        self.assertNotEqual(owner_id, "stale-owner")
        metadata = json.loads((lock_dir / "owner.json").read_text(encoding="utf-8"))
        self.assertEqual(metadata["pid"], os.getpid())
        _release_lock(lock_dir, owner_id)
        self.assertFalse(lock_dir.exists())

    def test_stale_lock_with_live_pid_waits_and_times_out(self):
        lock_dir = self.root / ".windows-provider-switch.lock"
        lock_dir.mkdir()
        (lock_dir / "owner.json").write_text(
            json.dumps(
                {
                    "owner_id": "live-owner",
                    "pid": os.getpid(),
                    "created_at": "2020-01-01T00:00:00+00:00",
                }
            ),
            encoding="utf-8",
        )

        with self.assertRaises(RuntimeError):
            _acquire_lock(lock_dir, timeout_seconds=0.3)

        self.assertTrue(lock_dir.exists())

    def test_owner_less_old_lock_is_reclaimed_after_stale_threshold(self):
        lock_dir = self.root / ".windows-provider-switch.lock"
        lock_dir.mkdir()
        old_timestamp = time.time() - 400
        os.utime(lock_dir, (old_timestamp, old_timestamp))

        owner_id = _acquire_lock(lock_dir, timeout_seconds=1)

        metadata = json.loads((lock_dir / "owner.json").read_text(encoding="utf-8"))
        self.assertEqual(metadata["owner_id"], owner_id)
        _release_lock(lock_dir, owner_id)
        self.assertFalse(lock_dir.exists())

    def test_status_reads_bom_prefixed_model_provider(self):
        self.config.write_text('\ufeffmodel_provider = "openai"\nmodel = "gpt-5.6-sol"\n', encoding="utf-8")

        self.assertEqual(status(self.config, self.state)["current_provider"], "openai")

    def test_switch_reports_thread_verification_from_real_read(self):
        result = switch_provider("openai", self.config, self.state)

        self.assertTrue(result["verified_threads"])
        self.assertEqual(result["synced_threads"], 0)

    def test_switch_reports_unverified_threads_when_read_fails(self):
        with patch(
            "switch_provider._read_thread_routing",
            return_value={"verified": False, "total": None, "provider_count": None, "other_count": None},
        ):
            result = switch_provider("openai", self.config, self.state)

        self.assertFalse(result["verified_threads"])

    def test_switch_without_state_db_reports_none_thread_verification(self):
        result = switch_provider("openai", self.config, None)

        self.assertIsNone(result["verified_threads"])

    def test_graceful_shutdown_ticks_while_waiting_and_closes_when_codex_exits(self):
        ticks = []
        with patch(
            "switch_provider._codex_processes", side_effect=[("Codex.exe",), ("Codex.exe",), ()]
        ), patch("switch_provider._codex_process_ids_from_toolhelp", return_value=(1234,)), patch(
            "switch_provider._post_close_to_codex_windows", return_value=1
        ):
            result = request_codex_graceful_shutdown(
                wait_seconds=2.0, tick=lambda elapsed: ticks.append(round(elapsed, 1))
            )

        self.assertTrue(ticks)
        self.assertEqual(ticks, sorted(ticks))
        self.assertEqual(result, {"requested": True, "closed": True, "windows": 1})

    def test_graceful_shutdown_keeps_ticking_until_timeout(self):
        ticks = []
        with patch("switch_provider._codex_processes", return_value=("Codex.exe",)), patch(
            "switch_provider._codex_process_ids_from_toolhelp", return_value=(1234,)
        ), patch("switch_provider._post_close_to_codex_windows", return_value=1):
            with self.assertRaises(CodexRunningError):
                request_codex_graceful_shutdown(
                    wait_seconds=0.6, tick=lambda elapsed: ticks.append(round(elapsed, 1))
                )

        self.assertGreaterEqual(len(ticks), 2)
        self.assertEqual(ticks, sorted(ticks))

    def test_restore_latest_rejects_corrupted_config_readback(self):
        switch_provider("openai", self.config, self.state)
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
