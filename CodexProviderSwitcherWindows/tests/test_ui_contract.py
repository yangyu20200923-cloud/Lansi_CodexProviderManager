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


if __name__ == "__main__":
    unittest.main()
