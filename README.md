# Lansi_CodexProviderManager

## v0.1.0-beta.1

This beta supports verified switching and recovery for the built-in OpenAI/ChatGPT, Qilin, and VectorEngine profiles on one existing `CODEX_HOME`. It is unsigned on macOS and has not completed real-provider compatibility validation.

此 Beta 支持在同一既有 `CODEX_HOME` 中，对内置 OpenAI/ChatGPT、Qilin 与 VectorEngine Profile 进行经验证的切换与恢复。macOS 产物为未签名 Beta，尚未完成真实 Provider 兼容性验证。

The Windows non-secret Profile catalog data layer is included for the next beta milestone, but custom profile editing has not yet been connected to the Windows or macOS GUI. Do not rely on it for switching in v0.1.0-beta.1.

Windows 的非秘密 Profile catalog 数据层已包含在下一里程碑基础中，但自定义 Profile 编辑尚未接入 Windows 或 macOS GUI。请勿在 v0.1.0-beta.1 中依赖其进行切换。

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
