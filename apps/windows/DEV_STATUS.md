# DEV_STATUS

## Current stage

Implementation handoff and local verification.

## Completed

- Native Windows GUI with OpenAI as the only built-in Provider; every other Provider is a user-created profile.
- Shared `CODEX_HOME` design for history, plugins, skills, and MCP.
- User environment variable key storage with masked confirmation.
- Atomic config replacement, SQLite backup/sync, dry-run, and restore.
- Double-click launcher and optional desktop shortcut installer.
- Isolated unit and static verification.
- Chinese UI and confirmed close-then-continue switch flow.
- OpenAI Plus login reuse without `OPENAI_API_KEY`.
- Post-write verification for config and all thread provider values.

## Unverified

- Real provider authentication and model availability were not tested because that would use live credentials and external quota.
- Full end-to-end switching was not performed against the active Codex database.

## Risk

Provider-side support for `gpt-5.6-sol`, `gpt-5.5`, and the Responses API must match the service account.

## 2026-08-17 Provider catalog change

- The bundled Provider catalog was reduced to the OpenAI default only.
- Bundled third-party Provider entries, managed base URLs, and their API-key handling were removed from the shipped Windows runtime.
- Custom profiles remain fully supported, but the application ships no third-party Provider entries, endpoints, or API keys.

## 2026-08-17 macOS family layout alignment

- The window shell now mirrors the macOS build: Provider sidebar, detail and
  system-status cards, and a right-aligned bottom action bar whose last button is
  “应用并重启 ChatGPT”.
- Sidebar keeps only “＋ 新增 Provider”; import/paste live on its context menu and
  edit/copy/export/paste live on the Provider list context menu.
- The taskbar icon now uses the packaged family icon through a stable
  `SetCurrentProcessExplicitAppUserModelID` identity in addition to the EXE icon.
- The bottom action bar adapts to window width: one right-aligned row when it
  fits, otherwise two right-aligned rows, so button labels are never clipped.
  The title type scale was tightened (20pt) and the bar gained consistent bottom
  breathing room.
