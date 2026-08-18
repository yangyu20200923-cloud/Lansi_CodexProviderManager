from contextlib import closing
import json
import os
import sqlite3
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from unittest.mock import MagicMock, patch


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PACKAGE_ROOT))

from local_web_app import (
    LocalWebApp,
    _open_local_browser,
    _parse_arguments,
    _store_user_environment_key,
    create_server,
    main,
)
from profile_catalog import load_catalog


class LocalWebAppTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.catalog = self.root / "profiles.json"
        self.home = self.root / "isolated-codex-home"
        self.home.mkdir()
        self.config = self.home / "config.toml"
        self.config.write_text(
            'model = "gpt-5.6-sol"\nmodel_provider = "openai"\n[history]\npersistence = "save-all"\n',
            encoding="utf-8",
        )
        with closing(sqlite3.connect(self.home / "state_5.sqlite")) as connection:
            connection.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT)")
            connection.execute("INSERT INTO threads VALUES ('fixture-thread', 'openai')")
            connection.commit()
        self.process_guard = patch("switch_provider._assert_codex_quiescent")
        self.process_guard.start()
        self.addCleanup(self.process_guard.stop)
        self.app = LocalWebApp(self.catalog, self.home, isolated_acceptance=True)
        self.server = create_server(self.app)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self):
        self.server.shutdown()
        self.thread.join(timeout=3)
        self.server.server_close()
        self.temporary.cleanup()

    def request(self, path, *, method="GET", body=None, token=None):
        headers = {}
        if body is not None:
            headers["Content-Type"] = "application/json"
            body = json.dumps(body).encode("utf-8")
        if token is not None:
            headers["X-Lansi-Session"] = token
        request = Request(self.base_url + path, data=body, headers=headers, method=method)
        with urlopen(request, timeout=5) as response:
            return response.status, json.loads(response.read().decode("utf-8"))

    def state(self):
        status, payload = self.request("/api/state")
        self.assertEqual(status, 200)
        return payload

    @staticmethod
    def profile_payload(name="Fixture Provider"):
        return {
            "name": name,
            "baseUrl": "https://api.example.invalid/v1",
            "wireApi": "responses",
            "apiKeyEnv": "FIXTURE_PROVIDER_API_KEY",
            "model": "fixture-model",
        }

    def test_loopback_server_requires_a_random_session_token_for_writes(self):
        self.assertEqual(self.server.server_address[0], "127.0.0.1")
        state = self.state()
        self.assertTrue(state["sessionToken"])
        with self.assertRaises(HTTPError) as error:
            self.request("/api/profile", method="POST", body=self.profile_payload())
        self.assertEqual(error.exception.code, 400)
        self.assertEqual(load_catalog(self.catalog) if self.catalog.exists() else {"profiles": []}, {"profiles": []})

    def test_authenticated_owner_tab_close_stops_the_local_server(self):
        with self.assertRaises(HTTPError) as error:
            self.request("/api/close", method="POST", body={})
        self.assertEqual(error.exception.code, 400)

        _, result = self.request("/api/close", method="POST", body={}, token=self.state()["sessionToken"])
        self.assertTrue(result["closing"])
        self.thread.join(timeout=3)
        self.assertFalse(self.thread.is_alive())

    def test_state_has_only_the_openai_builtin_and_never_lists_private_presets(self):
        state = self.state()
        self.assertEqual([choice["id"] for choice in state["choices"]], ["openai"])
        self.assertNotIn("qilin", json.dumps(state).lower())
        self.assertNotIn("vectorengine", json.dumps(state).lower())

    def test_isolated_acceptance_requires_explicit_fixture_paths(self):
        with self.assertRaises(SystemExit) as error:
            main(["--isolated-acceptance"])
        self.assertEqual(error.exception.code, 2)

    def test_direct_executable_launches_the_browser_by_default_and_can_be_disabled_for_automation(self):
        self.assertTrue(_parse_arguments([]).open_browser)
        self.assertFalse(_parse_arguments(["--no-open-browser"]).open_browser)

    def test_browser_start_uses_windows_shell_fallback_when_registered_browser_open_fails(self):
        logger = __import__("logging").getLogger("test-browser-start")
        with patch("local_web_app.webbrowser.open", return_value=False), patch.object(
            sys.modules["local_web_app"].os, "startfile", create=True
        ) as startfile:
            self.assertTrue(_open_local_browser("http://127.0.0.1:12345/", logger))
        startfile.assert_called_once_with("http://127.0.0.1:12345/")

    def test_full_custom_provider_lifecycle_persists_and_uses_the_safe_switch_core(self):
        state = self.state()
        token = state["sessionToken"]
        _, created = self.request("/api/profile", method="POST", token=token, body=self.profile_payload())
        profile_id = created["profile"]["id"]
        self.assertNotIn("apiKey", created["profile"])

        updated = self.profile_payload("Edited Provider")
        updated["id"] = profile_id
        updated["model"] = "edited-model"
        _, edited = self.request("/api/profile", method="POST", token=token, body=updated)
        self.assertEqual(edited["profile"]["id"], profile_id)
        self.assertEqual(len(load_catalog(self.catalog)["profiles"]), 1)

        copied = self.profile_payload("Copied Provider")
        _, copy_result = self.request("/api/profile", method="POST", token=token, body=copied)
        copy_id = copy_result["profile"]["id"]
        self.assertNotEqual(copy_id, profile_id)

        _, toggled = self.request(
            "/api/profile/toggle", method="POST", token=token, body={"id": copy_id, "enabled": False}
        )
        self.assertFalse(toggled["profile"]["enabled"])
        _, exported = self.request(f"/api/profile/export?id={profile_id}")
        self.assertEqual(exported["profiles"][0]["id"], profile_id)
        self.assertNotIn('"apiKey"', json.dumps(exported))
        imported_profile = dict(exported["profiles"][0])
        imported_profile["id"] = "8c29df1a-60a8-4f50-ad4f-960137606092"
        imported_profile["name"] = "Imported Provider"
        _, imported = self.request(
            "/api/profile/import", method="POST", token=token, body={"profiles": [imported_profile]}
        )
        imported_id = imported["importedProfileIds"][0]

        _, checked = self.request("/api/check", method="POST", token=token, body={"id": profile_id})
        self.assertTrue(checked["dry_run"])
        _, switched = self.request("/api/switch", method="POST", token=token, body={"id": profile_id})
        self.assertTrue(switched["verified_config"])
        self.assertIn('model_provider = "custom_', self.config.read_text(encoding="utf-8"))
        _, restored = self.request("/api/restore", method="POST", token=token, body={})
        self.assertTrue(restored["restored"])
        self.assertIn('model_provider = "openai"', self.config.read_text(encoding="utf-8"))

        restarted = LocalWebApp(self.catalog, self.home, isolated_acceptance=True)
        self.assertEqual({p["id"] for p in restarted.state()["profiles"]}, {profile_id, copy_id, imported_id})
        _, deleted = self.request("/api/profile/delete", method="POST", token=token, body={"id": profile_id})
        self.assertEqual(deleted["removedProfileId"], profile_id)
        _, deleted_copy = self.request("/api/profile/delete", method="POST", token=token, body={"id": copy_id})
        self.assertEqual(deleted_copy["removedProfileId"], copy_id)
        _, deleted_import = self.request("/api/profile/delete", method="POST", token=token, body={"id": imported_id})
        self.assertEqual(deleted_import["removedProfileId"], imported_id)
        self.assertEqual(self.state()["choices"], [{"id": "openai", "name": "OpenAI", "kind": "builtin", "enabled": True, "authMode": "chatgpt_login"}])

    def test_import_rejects_secret_or_unknown_fields_without_changing_catalog(self):
        token = self.state()["sessionToken"]
        unsafe = {"profiles": [self.profile_payload() | {"id": "70a1d044-7be6-440b-bcd4-e1499dd0fb9b", "apiKey": "synthetic-secret"}]}
        with self.assertRaises(HTTPError) as error:
            self.request("/api/profile/import", method="POST", token=token, body=unsafe)
        self.assertEqual(error.exception.code, 400)
        self.assertFalse(self.catalog.exists())

    def test_chatgpt_login_profile_keeps_its_optional_connection_fields_optional(self):
        token = self.state()["sessionToken"]
        _, created = self.request(
            "/api/profile",
            method="POST",
            token=token,
            body={"name": "Login Profile", "authMode": "chatgpt_login", "model": "gpt-5.6-sol"},
        )
        self.assertEqual(created["profile"]["authMode"], "chatgpt_login")
        self.assertNotIn("apiKeyEnv", created["profile"])

    def test_cannot_disable_or_delete_the_current_custom_provider(self):
        token = self.state()["sessionToken"]
        _, created = self.request("/api/profile", method="POST", token=token, body=self.profile_payload())
        profile_id = created["profile"]["id"]
        self.request("/api/switch", method="POST", token=token, body={"id": profile_id})

        for path, body in (
            ("/api/profile/delete", {"id": profile_id}),
            ("/api/profile/toggle", {"id": profile_id, "enabled": False}),
        ):
            with self.assertRaises(HTTPError) as error:
                self.request(path, method="POST", token=token, body=body)
            self.assertEqual(error.exception.code, 400)

    def test_shared_lcp_03_fixture_round_trips_all_approved_browser_fields(self):
        fixture = json.loads(
            (PACKAGE_ROOT.parents[1] / "spec/fixtures/lcp-03-provider-parity.json").read_text(encoding="utf-8")
        )
        token = self.state()["sessionToken"]
        _, imported = self.request("/api/profile/import", method="POST", token=token, body=fixture)
        self.assertEqual(imported["importedProfileIds"], [fixture["profiles"][0]["id"]])
        self.assertEqual(self.state()["profiles"], fixture["profiles"])

        edited = dict(fixture["profiles"][0])
        edited["name"] = "LCP-03 Browser Edit"
        edited.pop("configOverrides")
        _, result = self.request("/api/profile", method="POST", token=token, body=edited)
        self.assertEqual(result["profile"]["configOverrides"], {})

    def test_fetch_models_updates_selected_model_and_non_secret_catalog(self):
        token = self.state()["sessionToken"]
        _, created = self.request("/api/profile", method="POST", token=token, body=self.profile_payload())
        profile_id = created["profile"]["id"]
        with patch("local_web_app.fetch_models", return_value=["deepseek-chat", "deepseek-reasoner"]):
            with patch.dict("os.environ", {"FIXTURE_PROVIDER_API_KEY": "fixture-secret"}):
                _, result = self.request("/api/profile/models", method="POST", token=token, body={"id": profile_id})
        self.assertEqual(result["models"], ["deepseek-chat", "deepseek-reasoner"])
        self.assertEqual(result["profile"]["model"], "deepseek-chat")
        self.assertNotIn("fixture-secret", self.catalog.read_text(encoding="utf-8"))

    def test_api_key_endpoint_writes_only_the_user_environment_and_never_returns_the_key(self):
        token = self.state()["sessionToken"]
        _, created = self.request("/api/profile", method="POST", token=token, body=self.profile_payload())
        profile_id = created["profile"]["id"]
        secret = "synthetic-browser-api-key"

        with self.assertLogs("lansi-web", level="INFO") as captured:
            with patch("local_web_app._store_user_environment_key") as store_key:
                _, result = self.request(
                    "/api/profile/key",
                    method="POST",
                    token=token,
                    body={"id": profile_id, "key": secret},
                )
        store_key.assert_called_once_with("FIXTURE_PROVIDER_API_KEY", secret)
        self.assertEqual(result, {"stored": True})
        self.assertNotIn(secret, self.catalog.read_text(encoding="utf-8"))
        _, exported = self.request(f"/api/profile/export?id={profile_id}")
        self.assertNotIn(secret, json.dumps(exported))
        self.assertNotIn(secret, "\n".join(captured.output))

        with patch.dict(os.environ, {"FIXTURE_PROVIDER_API_KEY": secret}, clear=False):
            state = self.state()
        self.assertTrue(state["credentialStatus"][profile_id]["apiKeyConfigured"])
        self.assertNotIn(secret, json.dumps(state))

    def test_api_key_endpoint_rejects_invalid_requests_and_chatgpt_login_profiles(self):
        token = self.state()["sessionToken"]
        _, api_profile = self.request("/api/profile", method="POST", token=token, body=self.profile_payload())
        _, login_profile = self.request(
            "/api/profile",
            method="POST",
            token=token,
            body={"name": "Login Profile", "authMode": "chatgpt_login", "model": "gpt-5.6-sol"},
        )

        for body in (
            {"id": api_profile["profile"]["id"], "key": ""},
            {"id": api_profile["profile"]["id"], "key": "x" * (16 * 1024 + 1)},
            {"id": login_profile["profile"]["id"], "key": "synthetic-browser-api-key"},
            {"id": api_profile["profile"]["id"]},
        ):
            with self.assertRaises(HTTPError) as error:
                self.request("/api/profile/key", method="POST", token=token, body=body)
            self.assertEqual(error.exception.code, 400)
        with self.assertRaises(HTTPError) as error:
            self.request(
                "/api/profile/key",
                method="POST",
                body={"id": api_profile["profile"]["id"], "key": "synthetic-browser-api-key"},
            )
        self.assertEqual(error.exception.code, 400)

    def test_windows_environment_key_writer_uses_hkcu_and_current_process_without_a_command_line(self):
        registry_key = MagicMock()
        registry_context = MagicMock()
        registry_context.__enter__.return_value = registry_key
        fake_winreg = MagicMock(
            HKEY_CURRENT_USER="HKCU",
            KEY_SET_VALUE=2,
            REG_SZ=1,
            CreateKeyEx=MagicMock(return_value=registry_context),
        )
        secret = "synthetic-browser-api-key"
        with patch.object(sys, "platform", "win32"), patch.dict(sys.modules, {"winreg": fake_winreg}), patch.dict(
            os.environ, {}, clear=True
        ), patch("local_web_app._broadcast_windows_environment_change") as broadcast:
            _store_user_environment_key("FIXTURE_PROVIDER_API_KEY", secret)
            self.assertEqual(os.environ["FIXTURE_PROVIDER_API_KEY"], secret)
        fake_winreg.CreateKeyEx.assert_called_once_with("HKCU", "Environment", 0, 2)
        fake_winreg.SetValueEx.assert_called_once_with(registry_key, "FIXTURE_PROVIDER_API_KEY", 0, 1, secret)
        broadcast.assert_called_once_with()

    def test_browser_rejects_nonempty_config_overrides(self):
        token = self.state()["sessionToken"]
        payload = self.profile_payload() | {"configOverrides": {"model": "unsafe"}}
        with self.assertRaises(HTTPError) as error:
            self.request("/api/profile", method="POST", token=token, body=payload)
        self.assertEqual(error.exception.code, 400)
        self.assertFalse(self.catalog.exists())

    def test_html_exposes_the_full_local_lifecycle_without_winforms_dependencies(self):
        request = Request(self.base_url + "/")
        with urlopen(request, timeout=5) as response:
            html = response.read().decode("utf-8")
        for label in ("新增 Provider", "编辑", "复制", "停用", "导入 Provider", "导出所选", "恢复最近备份", "切换 Provider", "认证方式"):
            self.assertIn(label, html)
        self.assertIn("X-Lansi-Session", html)
        self.assertIn('type="password"', html)
        self.assertIn("API Key（仅当前 Windows 用户）", html)
        self.assertIn("/api/profile/key", html)
        self.assertIn("不会保存到 Provider、导出文件或日志", html)
        self.assertNotIn("System.Windows.Forms", html)
        with urlopen(Request(self.base_url + "/assets/LansiObserve.ico"), timeout=5) as response:
            self.assertEqual(response.headers["Content-Type"], "image/x-icon")


if __name__ == "__main__":
    unittest.main()
