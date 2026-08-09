# Codex Provider Manager

A native SwiftUI macOS utility for switching one shared Codex installation among OpenAI/ChatGPT, Qilin, and VectorEngine.

## Safety model

- Uses the existing `CODEX_HOME` (default `~/.codex`) for every provider.
- Never edits `auth.json` or session JSONL files.
- Stores third-party API keys in macOS Keychain.
- Backs up `config.toml`, `state_5.sqlite`, WAL, and SHM before switching.
- Verifies history and extension invariants and restores the previous state on failure.
- OpenAI remains the built-in provider and uses the existing ChatGPT Plus/Codex login.

## Defaults

| Provider | Base URL | API type |
|---|---|---|
| OpenAI / ChatGPT | Built in | Built in |
| Qilin | `https://www.qilinapi.com` | `responses` |
| VectorEngine | `https://api.vectorengine.cn/v1` | `responses` |

## Build

Requirements: macOS 13 or later and Swift 5.9 or later. A full Xcode installation is required to run XCTest and to sign/notarize distribution builds.

```bash
swift build --disable-index-store
./scripts/build-app.sh
open "dist/Codex Provider Manager.app"
```

The local build is ad-hoc signed. For Developer ID distribution, first create a `notarytool` Keychain profile and then run:

```bash
./scripts/sign-and-notarize.sh "Developer ID Application: Name (TEAMID)" profile-name "dist/Codex Provider Manager.app"
```

## Recovery

Backups live under `~/.codex/backups/CodexProviderManager/`. The app keeps the newest ten non-pinned backups. If automatic recovery fails, do not relaunch ChatGPT until the reported backup has been restored.

## Diagnostics

`./scripts/run-diagnostics.sh` prints only redacted provider and history status. It does not print API keys, auth tokens, database rows, or absolute home paths.

## Development

Run `swift test` with a full Xcode toolchain. Tests use temporary Codex homes and isolated Keychain service names. Never add real API keys, `~/.codex` data, user databases, backups, or diagnostic output to the repository.

Licensed under the MIT License.
