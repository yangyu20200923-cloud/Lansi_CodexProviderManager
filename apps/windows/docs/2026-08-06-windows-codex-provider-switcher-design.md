# Windows Codex Provider Switcher Design

## Goal

Provide one Windows GUI for switching Codex Desktop between OpenAI, Qilin, and VectorEngine while preserving one shared Codex home, conversation history, plugins, skills, and MCP configuration.

## Architecture

- `CodexProviderSwitcher.ps1` owns the WinForms UI, masked key display, user-level environment variables, process checks, and user confirmations.
- `switch_provider.py` owns provider metadata, narrowly scoped TOML editing, atomic replacement, SQLite backup and thread-provider synchronization, and restore.
- `Start-CodexProviderSwitcher.cmd` is the double-click entry point.
- `Install-DesktopShortcut.ps1` creates an optional desktop shortcut.

All providers use `C:\Users\Lansi\.codex` by default. The switcher never changes `CODEX_HOME`, copies session directories, or replaces the whole Codex configuration. It edits only root provider/model keys and managed provider tables.

## Key Handling

Keys use Windows user environment variables: `OPENAI_API_KEY`, `QILIN_API_KEY`, and `VECTORENGINE_API_KEY`. The GUI reads the selected variable and shows only a mask. A blank input keeps the existing key; a nonblank input replaces it after confirmation. Full keys are never printed to logs or command output.

Legacy inline provider tokens are detected. A successful switch removes managed inline token fields from `config.toml`; the user must first place the key in the selected environment variable through the GUI.

## Switching Flow

1. Detect `C:\Users\<user>\.codex`, current provider, selected environment variable status, and Codex processes.
2. Require Codex Desktop processes to be closed before changing the active SQLite database.
3. Validate that the selected provider has a key variable.
4. Back up `config.toml` and `state_5.sqlite` with a timestamp.
5. Write the new config through a temporary file and atomic replace.
6. In one SQLite transaction, update existing thread `model_provider` values so old tasks can resume with the selected provider.
7. Roll back the config and database transaction on failure.
8. Offer to launch the installed Codex Desktop package after switching.

## Recovery And Safety

Backups live under `.codex\backups\windows-provider-switch`. A lock directory blocks concurrent switches. Restore selects the newest valid backup pair. The core supports `--dry-run` so configuration changes can be inspected without writes.

## Verification

Automated tests use temporary directories and SQLite databases. They verify config preservation, managed-table replacement, secret removal, history synchronization, backup creation, dry-run behavior, and restoration. PowerShell parsing and Python compilation are checked separately.
