# Lansi Codex Provider Manager for macOS

English | [简体中文](#简体中文)

A native macOS Provider manager for an existing Codex installation. OpenAI / ChatGPT login is the only built-in Provider. Create and manage every third-party Provider yourself in the app, without hand-editing TOML or JSON and without bundling private Providers or API keys.

## Install, launch, and use

macOS 13+ and Swift 5.9+ are required to build locally. Build and install the app for the current user:

```bash
./scripts/build-app.sh
./scripts/install-app.sh --launch
```

The application is installed at `~/Applications/Codex Provider Manager.app`. Use **Add Provider** to enter the Provider fields, add a selected model and optional comma-separated model list, use **Fetch upstream** to read an OpenAI-compatible `/models` endpoint, then use **Check** before **Switch Provider**. API-key Providers must have an explicit model; the manager never substitutes a GPT model for a non-GPT upstream. Use **Restore Latest Backup** to recover the most recent verified switch backup. The app keeps the existing Codex home (normally `~/.codex`), backs up before changing a Provider, and verifies that sessions, thread routing, Skills, MCP, plugins, AGENTS instructions, and unrelated configuration are retained.

Run redacted diagnostics without printing API keys, tokens, database rows, or absolute home paths:

```bash
./scripts/run-diagnostics.sh
```

Remove only the installed app with:

```bash
./scripts/uninstall-app.sh
```

Uninstall moves the app to Trash by default. It never deletes Codex homes, profiles, sessions, Skills, MCP, plugins, backups, or credentials.

## Build Artifacts / 构建产物

Run `scripts/build-dmg.sh --replace` on macOS to rebuild
`dist/Lansi_CodexProviderManager-macos.dmg` and its adjacent SHA-256 checksum.
The DMG contains only `Codex Provider Manager.app`; it never includes a Codex
home, profiles, conversations, Skills, MCP configuration, plugins, backups, or
credentials.

在 macOS 上运行 `scripts/build-dmg.sh --replace`，会重新生成
`dist/Lansi_CodexProviderManager-macos.dmg` 及相邻的 SHA-256 校验文件。
DMG 只包含 `Codex Provider Manager.app`，不会包含 Codex 主目录、Profile、
会话、Skill、MCP 配置、插件、备份或凭据。

## Signing limitation

Local builds are ad-hoc signed for local use and are **not notarized**. A normal macOS Gatekeeper prompt can therefore block an unsigned local artifact. Do not weaken system security to bypass an unexpected prompt; obtain a Developer ID signed and notarized artifact from the release publisher instead. Publishers can sign and notarize a built app with:

```bash
./scripts/sign-and-notarize.sh "Developer ID Application: Name (TEAMID)" profile-name "dist/Codex Provider Manager.app"
```

## Development

Run `swift test` with a full Xcode toolchain. Tests use temporary Codex homes and isolated Keychain service names. Never add real API keys, `~/.codex` data, user databases, backups, or diagnostic output to the repository.

Licensed under the MIT License.

## 简体中文

这是 macOS 原生 Provider 管理器。内置项只有 OpenAI / ChatGPT 登录；第三方 Provider 由用户在应用中自行创建和管理，软件不会附带私有 Provider 或 API key。它保留原有 Codex home，无需手工编辑 TOML 或 JSON。

在 macOS 13+ 上可用以下命令构建、安装并启动：

```bash
./scripts/build-app.sh
./scripts/install-app.sh --launch
```

发布 DMG 可运行 `./scripts/build-dmg.sh --replace`，产物和 SHA-256 校验文件位于 `dist/`。

应用安装到 `~/Applications/Codex Provider Manager.app`。使用“新增 Provider”填写字段，先执行“检查”再“切换 Provider”；需要撤销时使用“恢复最近备份”。每次切换前都会备份，并校验会话、线程路由、Skill、MCP、插件、AGENTS 指令及无关配置仍被保留。

诊断命令如下，输出会隐藏 API key、token、数据库行和绝对 home 路径：

```bash
./scripts/run-diagnostics.sh
```

使用 `./scripts/uninstall-app.sh` 仅移除应用。默认移入废纸篓，绝不删除 Codex home、Profile、会话、Skill、MCP、插件、备份或凭据。

本地构建仅使用 ad-hoc 签名，未完成 notarization，Gatekeeper 可能阻止未知来源的构建。不要为未知提示降低系统安全性；应从发布方取得 Developer ID 签名并完成 notarization 的产物。发布方可用上面的 `sign-and-notarize.sh` 命令进行签名和公证。
