# Phase 2 Switch Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make both native switchers recoverable under configuration and SQLite failures while proving that conversations and extensions remain intact.

**Architecture:** Keep one shared `CODEX_HOME`. Each platform implements the same ordered protocol: preflight, exclusive lock, SQLite-consistent backup, atomic apply, readback verification, and automatic recovery. Shared synthetic fixtures express invariants; platform tests inject failures at each write boundary.

**Tech Stack:** Swift Foundation/SQLite3/XCTest on macOS; Python standard library/SQLite3/unittest and PowerShell UI tests on Windows; SHA-256 synthetic fixtures.

## Global Constraints

- Follow `docs/architecture/switch-safety-and-recovery.md` exactly.
- Do not use a real `CODEX_HOME`, credential, auth file, session, backup, or conversation in tests.
- Preserve Skills, MCP, plugins, AGENTS instructions, sessions, and unknown TOML fields.
- Never log or serialize credential values, bearer tokens, database content, or absolute home paths.
- Preserve the Phase 1 compatibility-managed TOML scope; do not add fields without official documentation.

---

### Task 1: Shared Safety Fixtures and Snapshot Contract

**Files:**
- Create: `spec/safety-fixtures/README.md`
- Create: `spec/safety-fixtures/home/config.toml`
- Create: `spec/safety-fixtures/home/threads.sql`
- Create: `spec/safety-fixtures/extensions.sha256`
- Create: `spec/safety-fixtures/expected-preservation.json`
- Test: `spec/tests/validate_safety_fixtures.py`

**Produces:** a synthetic home corpus and a validator that emits no user paths or content.

- [ ] Write validator tests for manifest hash mismatch, credential-like fixture text, and changed preservation counts.
- [ ] Add a validator that checks extension SHA-256 values, threads/session counts, and rejects credential-like content.
- [ ] Create only synthetic sessions, Skills, plugin, MCP, config, and SQLite schema samples.
- [ ] Run `python3 spec/tests/validate_safety_fixtures.py` and require all cases to pass.
- [ ] Commit with `test: add switch safety fixtures`.

### Task 2: macOS Lock, Redacted Snapshot, and Restore Primitives

**Files:**
- Create: `apps/macos/Sources/ProviderCore/SwitchLock.swift`
- Modify: `apps/macos/Sources/ProviderCore/BackupService.swift`
- Modify: `apps/macos/Sources/ProviderCore/DiagnosticsService.swift`
- Create: `apps/macos/Tests/ProviderCoreTests/SwitchSafetyTests.swift`

**Produces:** `SwitchLock.acquire(at:)`, redacted `BackupManifest`, and `BackupService.restore` verification.

- [ ] Write XCTest cases that hold a synthetic lock, verify contention refusal, verify a SQLite online-backup restore, and assert that diagnostics replace home paths and secret markers.
- [ ] Implement owner-aware lock acquisition and defer-based release; stale reclamation must verify its owner is absent.
- [ ] Replace raw WAL/SHM copying with a single SQLite online-backup artifact and manifest checksums.
- [ ] Add restore readback checks for config checksum and SQLite thread count.
- [ ] Run `cd apps/macos && swift test --disable-index-store`.
- [ ] Commit with `feat: harden macos switch recovery`.

### Task 3: Windows Lock, Redacted Snapshot, and Restore Primitives

**Files:**
- Modify: `apps/windows/switch_provider.py`
- Modify: `apps/windows/tests/test_switch_provider.py`
- Modify: `apps/windows/CodexProviderSwitcher.ps1`

**Produces:** owner-aware lock, checksum manifest, redacted result object, and verified restore.

- [ ] Write unittest cases for lock contention, config replacement exception, SQLite commit exception, and restored fixture invariants.
- [ ] Replace age-only lock removal with owner liveness validation and leave an uncertain lock in place.
- [ ] Use SQLite online backup for both backup and restore; persist only relative artifact names and checksums in the manifest.
- [ ] Redact config, database, backup, and exception paths before returning data to PowerShell.
- [ ] Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\Test-Switcher.ps1` on Windows.
- [ ] Commit with `feat: harden windows switch recovery`.

### Task 4: Coordinated Apply, Verification, and Fault Recovery

**Files:**
- Modify: `apps/macos/Sources/ProviderCore/ProviderSwitchCoordinator.swift`
- Modify: `apps/macos/Sources/ProviderCore/HistorySyncService.swift`
- Modify: `apps/macos/Tests/ProviderCoreTests/SwitchSafetyTests.swift`
- Modify: `apps/windows/switch_provider.py`
- Modify: `apps/windows/tests/test_switch_provider.py`

**Produces:** the ordered shared protocol and deterministic fault injection hooks limited to test builds.

- [ ] Write failing tests for config write failure, thread-transaction failure, readback mismatch, and recovery failure against synthetic homes.
- [ ] Acquire the lock before snapshot; refuse an unquiesced Codex process before any backup or write.
- [ ] Verify Provider selection, approved thread metadata, counts, sessions, and extension hashes after successful apply and after recovery.
- [ ] Ensure every post-snapshot failure restores config and SQLite before the lock is released; report recovery-required only when restoration verification fails.
- [ ] Run macOS XCTest and Windows `Test-Switcher.ps1` against synthetic data.
- [ ] Commit with `feat: verify provider switch recovery`.

### Task 5: Restore UI and Phase 2 Audit

**Files:**
- Modify: `apps/macos/App/ContentView.swift`
- Modify: `apps/macos/App/ProviderManagerViewModel.swift`
- Modify: `apps/macos/App/StatusSummaryView.swift`
- Modify: `apps/macos/Resources/en.lproj/Localizable.strings`
- Modify: `apps/macos/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `apps/windows/CodexProviderSwitcher.ps1`
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Test: platform UI contract tests

**Produces:** restore actions that expose only redacted backup IDs and verification results.

- [ ] Add tests asserting that UI strings and CLI JSON omit absolute paths and credential-like values.
- [ ] Show backup ID, timestamp, verification verdict, and recovery outcome; require confirmation before manual restore.
- [ ] Run `python3 spec/tests/validate_safety_fixtures.py`, macOS XCTest, Windows PowerShell tests, fixture hash checks, secret scan, and `git diff --check`.
- [ ] Update bilingual release notes and recovery documentation.
- [ ] Commit only audit corrections with `docs: record switch safety audit`.
