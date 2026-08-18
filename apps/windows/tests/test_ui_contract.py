import json
import os
import sqlite3
import sys
import tempfile
import types
import unittest
from contextlib import closing
from pathlib import Path
from unittest.mock import MagicMock, patch


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PACKAGE_ROOT))

from desktop_app import DesktopProviderManager, _parse_arguments
import desktop_app as desktop_app_module


DESKTOP_APP_PATH = PACKAGE_ROOT / "desktop_app.py"
LAUNCHER_PATH = PACKAGE_ROOT / "Start-CodexProviderSwitcher.cmd"
EXECUTABLE_BUILDER_PATH = PACKAGE_ROOT / "New-WindowsExecutable.ps1"
TEST_SCRIPT_PATH = PACKAGE_ROOT / "Test-Switcher.ps1"
README_PATH = PACKAGE_ROOT / "README.md"


class WindowsDesktopUiContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.catalog = self.root / "profiles.json"
        self.home = self.root / "isolated-codex-home"
        self.home.mkdir()
        (self.home / "config.toml").write_text(
            'model = "gpt-5.6-sol"\nmodel_provider = "openai"\n[history]\npersistence = "save-all"\n',
            encoding="utf-8",
        )
        with closing(sqlite3.connect(self.home / "state_5.sqlite")) as connection:
            connection.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT)")
            connection.execute("INSERT INTO threads VALUES ('fixture-thread', 'openai')")
            connection.commit()
        self.manager = DesktopProviderManager(self.catalog, self.home)

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def profile_payload(name="Fixture Provider"):
        return {
            "name": name,
            "authMode": "api_key",
            "baseUrl": "https://api.example.invalid/v1",
            "wireApi": "responses",
            "apiKeyEnv": "FIXTURE_PROVIDER_API_KEY",
            "model": "fixture-model",
            "models": ["fixture-model", "fixture-reasoner"],
        }

    def test_native_desktop_manager_runs_the_custom_profile_lifecycle_without_http(self):
        profile = self.manager.upsert(self.profile_payload())
        profile_id = str(profile["id"])

        with patch("desktop_app._store_user_environment_key") as store_key:
            self.manager.store_key(profile_id, "synthetic-desktop-api-key")
        store_key.assert_called_once_with("FIXTURE_PROVIDER_API_KEY", "synthetic-desktop-api-key")
        self.assertNotIn("synthetic-desktop-api-key", self.catalog.read_text(encoding="utf-8"))
        self.assertEqual(self.manager.export_profile(profile_id)["profiles"][0]["id"], profile_id)
        generated_catalog_path = self.catalog.parent / "model-catalogs" / f"{profile_id}.json"
        with patch.dict(os.environ, {"FIXTURE_PROVIDER_API_KEY": "synthetic-desktop-api-key"}), patch(
            "desktop_app.fetch_models", return_value=["fixture-model"]
        ), patch("switch_provider._codex_processes", return_value=()):
            self.assertTrue(self.manager.check(profile_id)["dry_run"])
            self.assertFalse(generated_catalog_path.exists())
        with patch.dict(os.environ, {"FIXTURE_PROVIDER_API_KEY": "synthetic-desktop-api-key"}), patch(
            "desktop_app.fetch_models", return_value=["fixture-model"]
        ), patch("switch_provider._codex_processes", return_value=()):
            switch_result = self.manager.switch(profile_id)
            self.assertTrue(switch_result["verified_config"])
            self.assertTrue(switch_result["preflight_verified"])
        self.assertEqual(switch_result["thread_routing"]["other_count"], 1)
        self.assertEqual(switch_result["connection"]["wire_api"], "responses")
        rendered = self.manager.config_path.read_text(encoding="utf-8")
        self.assertIn("model_catalog_json", rendered)
        self.assertTrue(generated_catalog_path.is_file())
        generated_catalog = json.loads(generated_catalog_path.read_text(encoding="utf-8"))
        self.assertEqual(
            [item["slug"] for item in generated_catalog["models"]],
            ["fixture-model", "fixture-reasoner"],
        )
        with patch("switch_provider._codex_processes", return_value=()):
            self.assertTrue(self.manager.restore()["restored"])
        self.manager.remove(profile_id)
        self.assertEqual(self.manager.state()["choices"], [{"id": "openai", "name": "OpenAI", "kind": "builtin", "enabled": True, "authMode": "chatgpt_login"}])

    def test_model_list_limit_is_enforced_before_profile_is_saved(self):
        payload = self.profile_payload()
        payload["models"] = [f"fixture-model-{index}" for index in range(101)]
        payload["model"] = "fixture-model-0"

        with self.assertRaisesRegex(desktop_app_module.DesktopAppError, "最多保留 100"):
            self.manager.upsert(payload)

    def test_current_model_can_remain_selected_outside_the_managed_list(self):
        payload = self.profile_payload()
        payload["models"] = ["fixture-reasoner"]

        profile = self.manager.upsert(payload)

        self.assertEqual(profile["model"], "fixture-model")
        self.assertEqual(profile["models"], ["fixture-reasoner"])

    def test_edit_profile_reloads_saved_non_secret_fields_and_model_choices(self):
        profile = self.manager.upsert(self.profile_payload("Saved Provider"))
        profile_id = str(profile["id"])

        loaded = self.manager.profile_for_edit(profile_id)

        self.assertEqual(loaded["name"], "Saved Provider")
        self.assertEqual(loaded["model"], "fixture-model")
        self.assertEqual(loaded["models"], ["fixture-model", "fixture-reasoner"])
        self.assertNotIn("apiKey", loaded)

    def test_state_reports_saved_api_key_presence_without_exposing_key_value(self):
        profile = self.manager.upsert(self.profile_payload("Credential Status Provider"))

        with patch.dict(os.environ, {"FIXTURE_PROVIDER_API_KEY": "synthetic-secret"}):
            state = self.manager.state()

        self.assertTrue(state["credentialStatus"][profile["id"]])
        self.assertEqual(state["connection"]["provider"], "openai")
        self.assertEqual(state["connection"]["model"], "gpt-5.6-sol")
        self.assertNotIn("synthetic-secret", json.dumps(state, ensure_ascii=False))

    def test_state_reports_managed_backup_presence_without_paths(self):
        self.assertFalse(self.manager.state()["latestBackup"])
        backup_dir = self.home / "backups" / "windows-provider-switch"
        backup_dir.mkdir(parents=True)
        (backup_dir / "config-test.toml").write_text("backup", encoding="utf-8")
        state = self.manager.state()
        self.assertTrue(state["latestBackup"])
        self.assertNotIn("windows-provider-switch", json.dumps(state, ensure_ascii=False))

    def test_switch_uses_the_live_tree_selection_instead_of_a_stale_event_value(self):
        profile_id = "00000000-0000-0000-0000-000000000001"

        class FakeTree:
            def selection(self):
                return (profile_id,)

        app = object.__new__(desktop_app_module.ProviderDesktopApp)
        app.selected_id = "openai"
        app.provider_tree = FakeTree()
        app.root = object()
        app.state = {
            "choices": [
                {"id": "openai", "name": "OpenAI", "kind": "builtin", "enabled": True},
                {"id": profile_id, "name": "DeepSeek", "kind": "custom", "enabled": True},
            ]
        }
        app._switch_selected = MagicMock()

        with patch.object(desktop_app_module, "_askyesno", return_value=True):
            app._switch()

        app._switch_selected.assert_called_once_with(profile_id, offer_graceful_close=True)

    def test_native_desktop_source_has_no_browser_server_or_http_api(self):
        source = DESKTOP_APP_PATH.read_text(encoding="utf-8")
        for marker in ("ProviderDesktopApp", "Windows 11-inspired", "WindowsButton", "_enable_windows_dpi_awareness", "访问密钥（不会显示）", "_apply_window_icon", "tk.Tk()"):
            self.assertIn(marker, source)
        self.assertIn("window.iconbitmap(str(icon_path))", source)
        for forbidden in ("ThreadingHTTPServer", "BaseHTTPRequestHandler", "webbrowser", "X-Lansi-Session", "/api/"):
            self.assertNotIn(forbidden, source)

    def test_native_desktop_defines_high_contrast_windows_11_interaction_states(self):
        source = DESKTOP_APP_PATH.read_text(encoding="utf-8")
        for marker in ("#0F6CBD", "#115EA3", "#0F548C", "#1B1B1B", "#616161", "highlightcolor", "disabledforeground"):
            self.assertIn(marker, source)
        self.assertIn('("selected", _COLORS["accent"])', source)

    def test_native_desktop_uses_responsive_grid_layout_and_model_selector(self):
        source = DESKTOP_APP_PATH.read_text(encoding="utf-8")
        self.assertIn("APP_BUILD", source)
        self.assertIn("self._on_main_resize", source)
        self.assertIn("self._refresh_model_choices", source)
        self.assertIn("self._sync_reasoning_choices", source)
        self.assertIn("self._sync_tree_selection()", source)
        self.assertIn("self._detail_value_wraplength", source)
        self.assertIn('text=str(item["name"])', source)
        self.assertIn("wraplength=200", source)
        for marker in (
            "已选模型",
            "可用模型",
            "添加选中",
            "全部添加",
            "_add_models_to_managed",
            "_ignore_upstream",
            "取消获取",
            "_cancel_model_fetch",
            "_poll_model_fetch",
            "selectmode=tk.EXTENDED",
            "MAX_MANAGED_MODELS",
        ):
            self.assertIn(marker, source)
        self.assertNotIn("fetch_codex_model_catalog(", source)
        self.assertIn('width=240', source)
        self.assertIn('sidebar.rowconfigure(3, weight=0)', source)
        self.assertIn('padding=(28, 18)', source)
        self.assertIn("self._fit_open_window", source)
        self.assertIn("self._sync_content_scrollbar", source)
        self.assertIn("self._fit_open_dialog", source)
        self.assertIn("self._sync_form_scrollbar", source)
        self.assertIn("self._form_canvas", source)
        self.assertIn('rows.append(("推理强度", profile["reasoningEffort"]))', source)
        self.assertIn("已配置：{environment}", source)
        self.assertIn("detail_columns = self._detail_columns", source)
        self.assertIn("divmod(index, detail_columns)", source)
        self.assertIn('height=4', source)
        self.assertIn('state="normal"', source)
        self.assertIn("系统状态", source)
        self.assertIn("当前模型", source)
        self.assertIn("已有任务保持原样", source)
        self.assertIn("编辑服务", source)
        self.assertIn("应用设置并重启 ChatGPT", source)
        self.assertIn('actions.columnconfigure(0, weight=1)', source)
        self.assertNotIn("width=280", source)
        self.assertNotIn('geometry("720x560")', source)
        self.assertNotIn("right.pack_propagate", source)

    def test_native_desktop_offers_normal_close_only_for_running_codex(self):
        source = DESKTOP_APP_PATH.read_text(encoding="utf-8")
        self.assertIn("CodexRunningError", source)
        self.assertIn("request_codex_graceful_shutdown", source)
        self.assertIn("不会强制结束进程", source)

    def test_packaged_launcher_targets_the_native_desktop_executable_without_browser_arguments(self):
        launcher = LAUNCHER_PATH.read_text(encoding="utf-8")
        builder = EXECUTABLE_BUILDER_PATH.read_text(encoding="utf-8")
        test_script = TEST_SCRIPT_PATH.read_text(encoding="utf-8")
        self.assertIn("Lansi_CodexProviderManager.exe", launcher)
        self.assertIn("native desktop", launcher.lower())
        self.assertNotIn("--open-browser", launcher)
        self.assertIn("desktop_app.py", builder)
        self.assertNotIn("local_web_app.py", builder)
        self.assertIn("--add-data", builder)
        self.assertIn("LansiObserve.ico", builder)
        self.assertIn("--windowed", builder)
        self.assertIn("desktop_app.py", test_script)
        self.assertNotIn("unittest discover", test_script)
        self.assertNotIn("test_local_web_app", test_script)

    def test_desktop_arguments_reject_the_retired_browser_flag_and_require_isolated_paths(self):
        with self.assertRaises(SystemExit):
            _parse_arguments(["--open-browser"])
        with self.assertRaises(SystemExit):
            _parse_arguments(["--isolated-acceptance"])

    def test_windows_readme_describes_a_native_desktop_application(self):
        readme = README_PATH.read_text(encoding="utf-8")
        self.assertIn("原生桌面", readme)
        self.assertNotIn("本地浏览器 Provider 管理器", readme)

    def _profile_dialog_stub(self):
        try:
            root = desktop_app_module.tk.Tk()
        except desktop_app_module.tk.TclError:
            self.skipTest("Tk display unavailable")
        root.withdraw()
        self.addCleanup(root.destroy)
        return root

    def test_profile_dialog_edit_prefills_saved_fields(self):
        profile = self.manager.upsert(self.profile_payload("Prefill Provider"))
        root = self._profile_dialog_stub()
        stub = types.SimpleNamespace(
            root=root,
            _set_notice=lambda *args, **kwargs: None,
            refresh=lambda *args, **kwargs: None,
        )
        dialog = desktop_app_module.ProfileDialog(stub, "edit", profile)
        self.addCleanup(dialog.window.destroy)

        self.assertEqual(dialog.values["name"].get(), "Prefill Provider")
        self.assertEqual(dialog.values["baseUrl"].get(), "https://api.example.invalid/v1")
        self.assertEqual(dialog.values["wireApi"].get(), "responses")
        self.assertEqual(dialog.values["apiKeyEnv"].get(), "FIXTURE_PROVIDER_API_KEY")
        self.assertEqual(dialog.values["model"].get(), "fixture-model")
        self.assertEqual(dialog._managed_models, ["fixture-model", "fixture-reasoner"])
        draft = dialog._draft()
        self.assertEqual(draft["name"], "Prefill Provider")
        self.assertEqual(draft["model"], "fixture-model")
        self.assertEqual(draft["models"], ["fixture-model", "fixture-reasoner"])
        self.assertEqual(draft["wireApi"], "responses")

    def test_profile_dialog_stages_upstream_models_until_user_adds_them(self):
        profile = self.manager.upsert(self.profile_payload("Staged Provider"))
        root = self._profile_dialog_stub()
        stub = types.SimpleNamespace(
            root=root,
            _set_notice=lambda *args, **kwargs: None,
            refresh=lambda *args, **kwargs: None,
            manager=self.manager,
        )
        dialog = desktop_app_module.ProfileDialog(stub, "edit", profile)
        self.addCleanup(dialog.window.destroy)

        cancel = desktop_app_module.threading.Event()
        results = desktop_app_module.queue.Queue()
        dialog._model_fetch_cancel = cancel
        dialog._is_fetching_models = True
        results.put(("models", ["upstream-model", "fixture-model"]))
        dialog._poll_model_fetch(cancel, results)

        self.assertEqual(dialog._managed_models, ["fixture-model", "fixture-reasoner"])
        self.assertEqual(dialog._upstream_models, ["upstream-model", "fixture-model"])
        dialog._upstream_model_list.selection_set(0, 1)
        dialog._add_selected_upstream()
        self.assertEqual(dialog._managed_models, ["fixture-model", "fixture-reasoner", "upstream-model"])
        self.assertEqual(
            self.manager.profile_for_edit(str(profile["id"]))["models"],
            ["fixture-model", "fixture-reasoner", "upstream-model"],
        )

    def test_profile_dialog_cancels_fetch_without_replacing_existing_upstream_models(self):
        profile = self.manager.upsert(self.profile_payload("Cancel Provider"))
        root = self._profile_dialog_stub()
        stub = types.SimpleNamespace(
            root=root,
            _set_notice=lambda *args, **kwargs: None,
            refresh=lambda *args, **kwargs: None,
            manager=self.manager,
        )
        dialog = desktop_app_module.ProfileDialog(stub, "edit", profile)
        self.addCleanup(dialog.window.destroy)
        dialog._upstream_models = ["previous-upstream-model"]
        cancel = desktop_app_module.threading.Event()
        dialog._model_fetch_cancel = cancel
        dialog._is_fetching_models = True

        dialog._cancel_model_fetch()

        self.assertTrue(cancel.is_set())
        self.assertFalse(dialog._is_fetching_models)
        self.assertEqual(dialog._upstream_models, ["previous-upstream-model"])

    def test_profile_dialog_discloses_saved_api_key_status_without_exposing_value(self):
        profile = self.manager.upsert(self.profile_payload("Credential Status Provider"))
        root = self._profile_dialog_stub()
        stub = types.SimpleNamespace(
            root=root,
            _set_notice=lambda *args, **kwargs: None,
            refresh=lambda *args, **kwargs: None,
        )

        with patch.dict(os.environ, {"FIXTURE_PROVIDER_API_KEY": "synthetic-secret"}):
            dialog = desktop_app_module.ProfileDialog(stub, "edit", profile)
            self.addCleanup(dialog.window.destroy)
            status_text = dialog.api_key_status.get()

        self.assertEqual(dialog.values["apiKey"].get(), "")
        self.assertIn("已配置：FIXTURE_PROVIDER_API_KEY", status_text)
        self.assertIn("留空会保留现有值", status_text)
        self.assertNotIn("synthetic-secret", status_text)

    def test_profile_dialog_copy_prefills_and_suffixes_name(self):
        profile = self.manager.upsert(self.profile_payload("Copy Source"))
        root = self._profile_dialog_stub()
        stub = types.SimpleNamespace(
            root=root,
            _set_notice=lambda *args, **kwargs: None,
            refresh=lambda *args, **kwargs: None,
        )
        dialog = desktop_app_module.ProfileDialog(stub, "copy", profile)
        self.addCleanup(dialog.window.destroy)

        self.assertEqual(dialog.values["name"].get(), "Copy Source 副本")
        self.assertEqual(dialog.values["model"].get(), "fixture-model")
        self.assertEqual(dialog._draft()["models"], ["fixture-model", "fixture-reasoner"])

    def test_profile_dialog_exposes_model_appropriate_reasoning_choices(self):
        profile = self.profile_payload("DeepSeek Provider") | {
            "model": "deepseek-reasoner",
            "models": ["deepseek-chat", "deepseek-reasoner"],
            "reasoningEffort": "max",
        }
        profile = self.manager.upsert(profile)
        root = self._profile_dialog_stub()
        stub = types.SimpleNamespace(
            root=root,
            _set_notice=lambda *args, **kwargs: None,
            refresh=lambda *args, **kwargs: None,
        )
        dialog = desktop_app_module.ProfileDialog(stub, "edit", profile)
        self.addCleanup(dialog.window.destroy)

        self.assertEqual(dialog.values["reasoningEffort"].get(), "max")
        self.assertEqual(
            tuple(dialog.values["reasoningEffort"].cget("values")),
            ("默认（由模型决定）", "low", "medium", "high", "xhigh", "max"),
        )
        self.assertEqual(dialog._draft()["reasoningEffort"], "max")

    def test_error_messages_do_not_expose_absolute_paths(self):
        (self.home / "config.toml").unlink()
        with self.assertRaises(FileNotFoundError) as caught:
            self.manager.check("openai")
        message = str(caught.exception)
        self.assertNotIn(str(self.root), message)
        self.assertNotIn(str(self.home), message)
        self.assertIn("config.toml", message)

        with self.assertRaises(FileNotFoundError) as caught_restore:
            self.manager.restore()
        restore_message = str(caught_restore.exception)
        self.assertNotIn(str(self.root), restore_message)
        self.assertNotIn(str(self.home), restore_message)
        self.assertIn("windows-provider-switch", restore_message)

    def test_manager_forwards_tick_to_graceful_shutdown(self):
        tick = lambda elapsed_seconds: None
        with patch(
            "desktop_app.request_codex_graceful_shutdown",
            return_value={"requested": True, "closed": True, "windows": 1},
        ) as shutdown:
            result = self.manager.request_codex_graceful_shutdown(tick=tick)
        shutdown.assert_called_once_with(tick=tick)
        self.assertTrue(result["closed"])

    def test_native_desktop_installs_right_click_copy_paste_for_all_text_surfaces(self):
        source = DESKTOP_APP_PATH.read_text(encoding="utf-8")
        for marker in (
            "_bind_context_menus",
            "_show_copy_only_menu",
            "_show_editable_menu",
            "_show_tree_menu",
            "_show_text_menu",
            "_entry_copy",
            "_entry_paste",
            "_label_copy_text",
            "_clipboard_copy",
            "<Button-3>",
            "粘贴",
            "全选",
            "_copyable_dialog",
            "_askyesno",
            "_showerror",
            "刷新状态",
        ):
            self.assertIn(marker, source)
        self.assertNotIn("messagebox.askyesno", source)
        self.assertNotIn("messagebox.showerror", source)

    def test_right_click_helpers_read_textvariable_labels_and_bind_controls(self):
        root = self._profile_dialog_stub()
        label = desktop_app_module.ttk.Label(root, text="静态文本")
        desktop_app_module._bind_context_menus(label)
        self.assertTrue(label.bind("<Button-3>"))
        self.assertEqual(desktop_app_module._label_copy_text(label), "静态文本")

        variable = desktop_app_module.tk.StringVar(value="动态错误信息")
        dynamic = desktop_app_module.ttk.Label(root, textvariable=variable)
        desktop_app_module._bind_context_menus(dynamic)
        self.assertEqual(desktop_app_module._label_copy_text(dynamic), "动态错误信息")

        entry = desktop_app_module.ttk.Entry(root)
        entry.insert(0, "可复制字段")
        desktop_app_module._bind_context_menus(entry)
        self.assertTrue(entry.bind("<Button-3>"))

        text = desktop_app_module.tk.Text(root)
        text.insert("1.0", "可复制正文")
        desktop_app_module._bind_context_menus(text)
        self.assertTrue(text.bind("<Button-3>"))

    def test_layout_keeps_details_compact_at_the_default_window_width(self):
        source = DESKTOP_APP_PATH.read_text(encoding="utf-8")
        self.assertIn("detail_columns = 2 if main_width >= 720 else 1", source)
        self.assertIn('actions.columnconfigure(0, weight=1)', source)
        self.assertIn("preferred_height = min(content_height + non_content_height + 8, 760)", source)

    def test_family_layout_aligns_sidebar_context_menus_and_right_aligned_bottom_bar_with_macos(self):
        source = DESKTOP_APP_PATH.read_text(encoding="utf-8")
        ordered_buttons = (
            'WindowsButton(actions, "编辑服务"',
            'WindowsButton(actions, "刷新状态"',
            'WindowsButton(actions, "恢复最近备份"',
            'WindowsButton(actions, "停用"',
            'WindowsButton(actions, "删除"',
            'WindowsButton(actions, "应用设置并重启 ChatGPT"',
        )
        positions = [source.index(label) for label in ordered_buttons]
        self.assertEqual(positions, sorted(positions))
        for marker in (
            "_on_tree_menu",
            "_on_add_provider_menu",
            "粘贴服务",
            "复制到剪贴板",
            "导出服务",
            "复制服务",
            "当前使用",
            "检查服务",
            "_copy_profile_json",
        ):
            self.assertIn(marker, source)

    def test_backup_management_entry_and_dialog_are_wired(self):
        source = DESKTOP_APP_PATH.read_text(encoding="utf-8")
        self.assertIn('WindowsButton(actions, "备份管理"', source)
        self.assertIn("def _backup_management", source)
        self.assertIn("list_backups(backup_dir)", source)
        self.assertIn("_prune_backups(backup_dir)", source)
        self.assertIn('ttk.Button(actions, text="清理旧备份"', source)
        self.assertNotIn("_layout_header_actions", source)
        self.assertIn("self._layout_action_bar", source)
        self.assertIn("rows = 1 if single_row_width <= available else 2", source)
        self.assertIn("self._action_rows", source)

    def test_native_desktop_sets_family_taskbar_icon_identity(self):
        source = DESKTOP_APP_PATH.read_text(encoding="utf-8")
        self.assertIn("_set_windows_app_user_model_id", source)
        self.assertIn("SetCurrentProcessExplicitAppUserModelID", source)
        self.assertIn("LansiObserve.ico", source)
        self.assertIn("iconbitmap", source)

    def test_provider_list_scrolls_when_it_exceeds_the_fixed_row_count(self):
        source = DESKTOP_APP_PATH.read_text(encoding="utf-8")
        self.assertIn("_sync_provider_scrollbar", source)
        self.assertIn("self._provider_scrollbar.grid_remove()", source)
        self.assertIn('int(self.provider_tree.cget("height") or 4)', source)
        self.assertIn("self._provider_scrollbar.grid()", source)

    def test_native_desktop_ships_basic_refresh_shortcuts_and_double_click_editing(self):
        source = DESKTOP_APP_PATH.read_text(encoding="utf-8")
        for marker in (
            "<Control-r>",
            "<F5>",
            "<Control-s>",
            "<Control-Return>",
            "<Double-1>",
            "_on_tree_double_click",
            "刷新状态",
        ):
            self.assertIn(marker, source)


if __name__ == "__main__":
    unittest.main()
