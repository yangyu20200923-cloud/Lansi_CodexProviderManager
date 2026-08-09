# CHANGELOG_AI

## 2026-08-06

- Added the unified Windows Codex provider switcher package.
- Added OpenAI, Qilin, and VectorEngine provider definitions.
- Added masked environment-variable key management.
- Added atomic config updates, conversation database synchronization, backup, restore, and dry-run behavior.
- Added isolated unit tests, parser checks, compilation checks, and secret-pattern scan.
- No real Codex configuration, API key, plugin, skill, MCP, or conversation file was modified during generation.

## 2026-08-06 Switch-flow correction

- Fixed the running-Codex path: confirmed shutdown now continues the same switch instead of aborting it.
- Added graceful shutdown, timeout, separately confirmed forced shutdown, and wait-for-exit checks.
- Added config and thread-provider readback verification before reporting success.
- Changed OpenAI authentication to the existing Codex Plus `chatgpt` login state.
- Translated the complete switcher UI and messages to Chinese.
- Expanded regression coverage from 6 to 11 tests.

## 2026-08-06 Single-process Count correction

- Fixed PowerShell scalar unrolling when exactly one Codex process remains.
- Forced all process-query results into arrays before reading `.Count`.
- Added a regression contract for the one-process state; total tests are now 12.

## 2026-08-06 VectorEngine endpoint correction

- Changed the generated VectorEngine base URL from `https://api.vectorengine.ai/v1` to `https://api.vectorengine.cn/v1`.
- Retained recognition of the old `.ai` URL only for legacy configuration cleanup.
