# Codex Implementation Report

## Task ID

USER-20260806-WINDOWS-CODEX-SWITCHER

## Task File

User request in the current Codex task; no Hermes TASK package was supplied.

## Codex Session File

Not applicable for this projectless local task.

## Target Repo

`C:\Users\Lansi\Documents\Codex\2026-08-06\d-users-lansi-desktop-apikey\outputs\CodexProviderSwitcherWindows`

## Execution Channel

Local Codex execution in the Windows workspace. No Hermes MCP, Desktop delivery, or external deployment was used.

## Modified Files

None outside the generated output package.

## Added Files

- `switch_provider.py`
- `CodexProviderSwitcher.ps1`
- `Start-CodexProviderSwitcher.cmd`
- `Install-DesktopShortcut.ps1`
- `Test-Switcher.ps1`
- `README.md`
- `tests/test_switch_provider.py`
- Design, plan, memory, and this report under `docs/`, `DEV_STATUS.md`, `DECISIONS.md`, `TODO.md`, and `CHANGELOG_AI.md`.

## Core Implementation

- One shared `CODEX_HOME` for history, plugins, skills, and MCP.
- OpenAI, Qilin, and VectorEngine provider switching.
- User environment variables with masked GUI confirmation.
- Chinese WinForms UI.
- Existing Codex Plus login for OpenAI; key variables only for Qilin and VectorEngine.
- Atomic config replacement and timestamped config/SQLite backups.
- SQLite thread provider synchronization and preview repair in one transaction.
- Dry-run and latest-backup restore.
- Live Codex process guard before database changes.
- Confirmed close-and-continue flow when Codex is running.
- Post-write config and full thread-provider verification before success is reported.
- Legacy managed inline provider token removal without printing its value.

## Commands Run

```text
python -m unittest discover -s tests -v
python -m py_compile switch_provider.py
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\Test-Switcher.ps1
python switch_provider.py --config C:\Users\Lansi\.codex\config.toml --state-db C:\Users\Lansi\.codex\state_5.sqlite status
```

## Test Output

- Unit and UI contract tests: 13 passed.
- Python compilation: passed.
- PowerShell parser checks: passed.
- Isolated CLI dry-run: passed; no backup created.
- Secret-pattern scan: passed.
- Read-only real-state inspection: config and state exist; `threads` schema contains required columns; 311 threads observed.
- Rendered config for all three providers: TOML parsing passed.

## Git Diff Summary

The current projectless directory is not a Git repository, so no commit or Git diff is available. The generated package is self-contained under `outputs/CodexProviderSwitcherWindows`.

## Test Manager Review

Local Test Gate: PASS for isolated core and static verification. Real provider authentication was intentionally not tested.

## QA Gate Result

NO-GO for claiming production/provider acceptance. The package is ready for user-controlled first-run check and closed-Codex switching, pending provider-side model/API confirmation.

## Discord / Message Sync

Not sent. No Hermes TASK or Discord notification request was provided.

## Risks

- The current real config has `model_provider = custom` and a legacy inline token; migration will change that file only after the user confirms a key in the GUI.
- Provider services may not support the configured model names or Responses API behavior.
- Windows user environment variables are user-readable registry values, not an encrypted vault.
- The switcher deliberately blocks changes while Codex processes are running; forced process termination is not implemented.

## Need Hermes/User Confirmation

- Confirm the selected provider's model mapping and API compatibility.
- Close Codex Desktop and use `Check only` before the first real switch.
- Decide whether to create the optional desktop shortcut.
