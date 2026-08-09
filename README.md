# Lansi_CodexProviderManager

兰司观察 Codex_Provider 切换器 is a local, cross-platform provider-profile manager for an existing Codex home.

兰司观察 Codex_Provider 切换器是一个本地跨平台 Provider 配置管理工具，始终使用已有的 Codex 主目录。

> This independent project is not affiliated with or endorsed by OpenAI or Codex.

The application keeps one existing CODEX_HOME. Before every verified switch it backs up the managed configuration and conversation database; it does not copy, delete, or upload conversations, Skills, MCP configuration, plugins, or API keys.

应用只使用一份已有的 CODEX_HOME。每次通过验证的切换前都会备份受管配置和会话数据库；不会复制、删除或上传会话、Skills、MCP 配置、插件或 API Key。

## Platform Applications

- macOS: apps/macos. Run \`swift test --disable-index-store\` from that directory.
- Windows: apps/windows. Run \`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Switcher.ps1\` from that directory.

Do not switch while Codex is actively writing. Use isolated tests only; never submit a real Codex home, credential, conversation, session file, backup, or database.

请勿在 Codex 正在写入时切换。测试必须使用隔离数据；不要提交真实 Codex 主目录、凭据、对话、会话文件、备份或数据库。

## Project Documents

See CONTRIBUTING.md for local development, SECURITY.md for vulnerability reporting, and docs/development/repository-layout.md for ownership.
