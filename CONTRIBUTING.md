# Contributing

Use isolated fixtures and temporary directories for every test. Never add a real CODEX_HOME, API key, auth.json, session JSONL, SQLite database, backup, or diagnostics output to a change.

每个测试都必须使用隔离 fixture 和临时目录。不得将真实 CODEX_HOME、API Key、auth.json、会话 JSONL、SQLite 数据库、备份或诊断输出加入变更。

Run macOS checks from apps/macos with `swift test --disable-index-store`. Run Windows checks from apps/windows with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Switcher.ps1` on Windows. Changes that affect switching must state their impact on conversations, sessions, Skills, MCP configuration, and plugins.

macOS 检查在 apps/macos 中执行 `swift test --disable-index-store`；Windows 检查在 Windows 上的 apps/windows 中执行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Switcher.ps1`。涉及切换的变更必须说明其对会话、上下文、Skills、MCP 配置和插件的影响。
