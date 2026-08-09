# Lansi_CodexProviderManager

兰司观察 Codex_Provider 切换器 is a local, cross-platform provider-profile manager for an existing Codex home.

> This independent project is not affiliated with or endorsed by OpenAI or Codex.

The application keeps one existing CODEX_HOME. Before every verified switch it backs up the managed configuration and conversation database; it does not copy, delete, or upload conversations, Skills, MCP configuration, plugins, or API keys.

## Platform Applications

- macOS: apps/macos. Run \`swift test --disable-index-store\` from that directory.
- Windows: apps/windows. Run \`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Switcher.ps1\` from that directory.

Do not switch while Codex is actively writing. Use isolated tests only; never submit a real Codex home, credential, conversation, session file, backup, or database.

## Project Documents

See CONTRIBUTING.md for local development, SECURITY.md for vulnerability reporting, and docs/development/repository-layout.md for ownership.
