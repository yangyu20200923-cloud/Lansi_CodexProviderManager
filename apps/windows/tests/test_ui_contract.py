import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "CodexProviderSwitcher.ps1"


class WindowsUiContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = SCRIPT_PATH.read_text(encoding="utf-8-sig")

    def test_ui_is_chinese(self):
        self.assertIn("Codex API 切换器", self.script)
        self.assertIn("切换 Provider", self.script)
        self.assertIn("恢复最近备份", self.script)

    def test_running_codex_continues_same_switch_after_confirmed_shutdown(self):
        self.assertIn("function Request-CodexShutdown", self.script)
        self.assertGreaterEqual(self.script.count("Request-CodexShutdown"), 3)
        self.assertNotIn("Assert-CodexClosed", self.script)
        self.assertIn("是否关闭 Codex 并继续本次操作", self.script)

    def test_process_queries_are_forced_to_arrays_for_single_process(self):
        self.assertNotIn("$processes = Get-CodexProcesses", self.script)
        self.assertNotIn("$remaining = Get-CodexProcesses", self.script)
        self.assertNotIn("$running = Get-CodexProcesses", self.script)
        self.assertIn("$processes = @(Get-CodexProcesses)", self.script)
        self.assertIn("$remaining = @(Get-CodexProcesses)", self.script)
        self.assertIn("$running = @(Get-CodexProcesses)", self.script)

    def test_openai_uses_plus_login_without_api_key(self):
        self.assertIn("'OpenAI Plus'", self.script)
        self.assertIn("Id = 'openai'; EnvKey = $null", self.script)
        self.assertIn("Codex Plus 登录（auth.json）", self.script)

    def test_success_message_requires_post_write_verification(self):
        self.assertIn("$result.verified_config", self.script)
        self.assertIn("$result.verified_threads", self.script)
        self.assertIn("切换并校验成功", self.script)

    def test_add_and_edit_share_the_labeled_provider_dialog(self):
        self.assertIn("function Show-ProviderDialog", self.script)
        self.assertEqual(self.script.count("Show-ProviderDialog -Title"), 3)
        for field in ("名称", "Base URL", "Wire API", "环境变量名", "模型"):
            self.assertIn(field, self.script)

    def test_catalog_actions_share_checked_cli_execution(self):
        self.assertIn("function Invoke-ProfileCatalog", self.script)
        self.assertGreaterEqual(self.script.count("Invoke-ProfileCatalog -Arguments"), 7)
        self.assertIn("$exitCode = $LASTEXITCODE", self.script)
        self.assertIn("if ($exitCode -ne 0)", self.script)

    def test_edit_preserves_uuid_and_delete_returns_to_builtin_default(self):
        self.assertIn("--id', $selected.ProfileId", self.script)
        self.assertIn("Refresh-ProviderChoices -SelectProfileId $selected.ProfileId", self.script)
        self.assertIn("确定删除 $($selected.Name)", self.script)
        self.assertIn("$providerBox.SelectedIndex = 0", self.script)

    def test_import_export_use_the_catalog_cli_and_preserve_builtin_profiles(self):
        self.assertIn("$importProviderButton", self.script)
        self.assertIn("$exportProviderButton", self.script)
        self.assertIn("New-Object System.Windows.Forms.OpenFileDialog", self.script)
        self.assertIn("New-Object System.Windows.Forms.SaveFileDialog", self.script)
        self.assertIn("'--import-file', $dialog.FileName", self.script)
        self.assertIn("'--id', $selected.ProfileId, '--export', $dialog.FileName", self.script)
        self.assertIn("内置 Provider 不可导出", self.script)
        self.assertIn("importedProfileIds", self.script)
        self.assertIn("Refresh-ProviderChoices -SelectProfileId $importedProfileId", self.script)
        self.assertIn("function Refresh-ProviderChoices", self.script)


if __name__ == "__main__":
    unittest.main()
