# Windows Codex Provider Switcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a dependency-light Windows GUI that safely switches three Codex API providers without separating Codex state.

**Architecture:** PowerShell WinForms handles interaction and user environment variables. A Python standard-library core performs atomic TOML edits, SQLite backup/synchronization, dry runs, and restore against one shared Codex home.

**Tech Stack:** Windows PowerShell 5.1+, WinForms, Python 3.11 standard library, SQLite, unittest.

## Global Constraints

- Never write an API key into source files, logs, test fixtures, or generated reports.
- Never change `CODEX_HOME`; sessions, plugins, skills, MCP, and state remain shared.
- Never edit real Codex files during automated tests.
- Block live state-database edits while Codex Desktop is running.
- Preserve all unrelated TOML content byte-for-byte where practical.

---

### Task 1: Core behavioral tests

**Files:**
- Create: `tests/test_switch_provider.py`

**Interfaces:**
- Consumes: CLI functions from `switch_provider.py`.
- Produces: regression coverage for render, switch, dry-run, backup, and restore behavior.

- [ ] Write tests using temporary config and SQLite files.
- [ ] Run `python -m unittest discover -s tests -v` and confirm failure because the core module is missing.

### Task 2: Atomic provider core

**Files:**
- Create: `switch_provider.py`

**Interfaces:**
- Produces: `render_config`, `switch_provider`, `restore_latest`, and a JSON CLI.

- [ ] Implement provider definitions and narrowly scoped TOML transformations.
- [ ] Implement config/database backups, locking, atomic config replacement, SQLite transaction, and rollback.
- [ ] Implement `status`, `switch`, and `restore` CLI commands with no secret output.
- [ ] Run the unittest suite and make all tests pass.

### Task 3: Windows GUI and launchers

**Files:**
- Create: `CodexProviderSwitcher.ps1`
- Create: `Start-CodexProviderSwitcher.cmd`
- Create: `Install-DesktopShortcut.ps1`

**Interfaces:**
- Consumes: JSON output from `switch_provider.py`.
- Produces: masked key UI, provider selection, switch, restore, and Codex relaunch controls.

- [ ] Implement provider selection and masked current-key status.
- [ ] Implement blank-keeps-current and nonblank-replaces-current key handling.
- [ ] Block switching while `ChatGPT`, `codex`, or `codex-code-mode-host` processes are active.
- [ ] Invoke the Python core without passing key values on the command line.
- [ ] Add double-click and desktop-shortcut entry points.

### Task 4: Documentation and verification

**Files:**
- Create: `README.md`
- Create: `Test-Switcher.ps1`
- Create: `DEV_STATUS.md`
- Create: `DECISIONS.md`
- Create: `TODO.md`
- Create: `CHANGELOG_AI.md`

**Interfaces:**
- Consumes: completed package.
- Produces: installation, operation, recovery, risk, and verification instructions.

- [ ] Document prerequisites, first use, provider switching, backup restore, and uninstall.
- [ ] Add one command that runs unit tests, Python compilation, PowerShell parsing, and secret-pattern scans.
- [ ] Run the full verification command against temporary data.
- [ ] Record real outputs and residual risks in the memory files.
