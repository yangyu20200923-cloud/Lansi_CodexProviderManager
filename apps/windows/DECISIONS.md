# DECISIONS

## 2026-08-06

- Use one shared `CODEX_HOME`; do not duplicate sessions, plugins, skills, or MCP.
- Use one WinForms switcher instead of three separately maintained applications.
- Store keys in Windows user environment variables and display only masks.
- Keep the Python core because its standard library provides reliable SQLite backup and transactions.
- Block live database switching while Codex Desktop processes are running.
- Preserve unrelated TOML tables and remove only managed/legacy provider tables.
- OpenAI uses the existing `auth_mode = chatgpt` Codex Plus login; only Qilin and VectorEngine use key environment variables.
- A running Codex prompt must continue into shutdown and switching within the same button action; a warning must not silently cancel and imply success.
- Success is shown only after config and thread-provider readback verification.
- VectorEngine uses `https://api.vectorengine.cn/v1`; the previous `.ai` endpoint is legacy-only and is never rendered into a new config.

## 2026-08-17 (supersedes the provider choices above)

- The packaged application bundles only the OpenAI default Provider.
- The Qilin and VectorEngine built-ins and their managed API-key/base-URL handling were removed from the shipped Windows runtime; the decisions above are retained as historical record.
- Third-party Providers are only created by the user and are never bundled or shipped with API keys.
