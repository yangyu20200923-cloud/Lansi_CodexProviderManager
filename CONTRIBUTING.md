# Contributing

Use isolated fixtures and temporary directories for every test. Never add a real CODEX_HOME, API key, auth.json, session JSONL, SQLite database, backup, or diagnostics output to a change.

Run macOS checks from apps/macos with `swift test --disable-index-store`. Run Windows checks from apps/windows with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Switcher.ps1` on Windows. Changes that affect switching must state their impact on conversations, sessions, Skills, MCP configuration, and plugins.
