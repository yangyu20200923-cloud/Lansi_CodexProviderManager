# Phase 0 Monorepo Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Convert the two existing platform prototypes into a documented Git monorepo without altering provider-switching behavior.

**Architecture:** Keep the native SwiftUI/Swift Package and PowerShell/Python applications separate under apps/. The root owns policy, shared documentation, CI, and release metadata. No runtime library, provider behavior, credential behavior, or Codex data format changes in Phase 0.

**Tech Stack:** Git, GitHub Actions, Swift 5.9/XCTest, Python 3 unittest, Windows PowerShell 5.1+.

## Global Constraints

- Preserve existing application behavior during import and relocation. Non-functional whitespace cleanup is allowed before the baseline commit when required by repository checks.
- Never read, stage, log, or test against a live Codex home, API key, token, backup, session JSONL, or user database.
- Keep generated output, diagnostics, bytecode, databases, backups, and credentials ignored.
- Use the approved names Lansi_CodexProviderManager and 兰司观察 Codex_Provider 切换器. Do not claim OpenAI or Codex affiliation.
- Run Swift verification on macOS and PowerShell verification on Windows.
- Keep import, relocation, governance, and CI as reviewable commits.

## Migration Impact Review

**Classification:** technical directory migration. **Risk:** MEDIUM. Phase 0 does not change user data, external APIs, runtime behavior, or schemas. The risk is broken build/test/package/documentation paths after relocation.

| Source | Target | Dependents | Control |
| --- | --- | --- | --- |
| CodexProviderManager/ | apps/macos/ | Package.swift and shell scripts | baseline commit, git mv, Swift test and package smoke |
| CodexProviderSwitcherWindows/ | apps/windows/ | cmd, ps1, Python core/tests | baseline commit, git mv, Test-Switcher.ps1 |
| Root docs | new root files | contributors/release users | link only to apps/macos and apps/windows |
| CI | .github/workflows/ci.yml | pull requests | explicit working directory per OS |

**Prerequisites:** Git identity, full Xcode on a macOS verifier, Python 3 and Windows PowerShell on a Windows verifier. No production Codex files are required.

**Downtime:** none. **Rollback:** revert the relocation commit. Never use git reset --hard, git clean, or recursive deletion.

## Planned File Structure

| Path | Responsibility |
| --- | --- |
| apps/macos/ | Relocated SwiftUI/Swift Package application |
| apps/windows/ | Relocated PowerShell UI and Python core |
| README.md | Bilingual overview and safe-use boundary |
| CONTRIBUTING.md | Fixture, test, and no-secret rules |
| SECURITY.md | Private vulnerability reporting |
| CODE_OF_CONDUCT.md | Contributor behavior |
| CHANGELOG.md | Release history |
| docs/development/repository-layout.md | Repository ownership map |
| .github/workflows/ci.yml | Platform CI |
| .github/ISSUE_TEMPLATE/bug_report.yml | Secret-safe bug report form |

## Task 1: Capture the Prototype Baseline

**Files:**
- Modify: none
- Test: CodexProviderManager/Tests/ProviderCoreTests/*
- Test: CodexProviderSwitcherWindows/tests/test_switch_provider.py
- Test: CodexProviderSwitcherWindows/tests/test_ui_contract.py

**Interfaces:**
- Consumes: CodexProviderManager/Package.swift and CodexProviderSwitcherWindows/Test-Switcher.ps1
- Produces: a tracked, unchanged baseline that later Git renames can preserve

- [ ] **Step 1: Record starting state**

Run:

    git status --short
    git log --oneline -3
    git ls-files --others --exclude-standard

Expected: both platform source trees are untracked; only the approved program-design and Phase 0 plan documents are tracked.

- [ ] **Step 2: Run macOS tests from the original path**

Run:

    cd CodexProviderManager
    swift test --disable-index-store

Expected: XCTest exits 0. If Xcode is unavailable, record the environmental block without source edits.

- [ ] **Step 3: Run Windows checks from the original path on Windows**

Run:

    Set-Location CodexProviderSwitcherWindows
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Switcher.ps1

Expected: Python compile, unittest, parser checks, isolated dry-run, and secret scan exit 0.

- [ ] **Step 4: Block import if likely credentials exist**

Run:

    rg -n --glob '!**/.build/**' --glob '!**/dist/**' --glob '!**/__pycache__/**' '(sk-[A-Za-z0-9_-]{20,}|Bearer[[:space:]]+[A-Za-z0-9._-]{20,}|OPENAI_API_KEY[[:space:]]*=[^[:space:]]+|QILIN_API_KEY[[:space:]]*=[^[:space:]]+|VECTORENGINE_API_KEY[[:space:]]*=[^[:space:]]+)' CodexProviderManager CodexProviderSwitcherWindows

Expected: no output. Any match blocks import until removed or converted to a non-secret fixture.

- [ ] **Step 5: Commit baseline source**

Run:

    git add CodexProviderManager CodexProviderSwitcherWindows
    git diff --cached --check
    git commit -m "chore: import existing platform prototypes"

Expected: source, tests, existing docs, and licenses are tracked; generated output and private data are not. If `git diff --cached --check` reports only pre-existing trailing whitespace or blank lines at EOF, remove only that whitespace, re-run the macOS suite and credential scan, then commit the cleaned baseline.

## Task 2: Relocate Applications Into apps/

**Files:**
- Move: CodexProviderManager/ to apps/macos/
- Move: CodexProviderSwitcherWindows/ to apps/windows/
- Create: scripts/check-repository-layout.sh
- Modify: .gitignore

**Interfaces:**
- Consumes: tracked source roots from Task 1
- Produces: apps/macos/Package.swift and apps/windows/Test-Switcher.ps1 as stable entry points

- [ ] **Step 1: Write a failing layout test**

Create scripts/check-repository-layout.sh:

    #!/usr/bin/env bash
    set -euo pipefail
    test -f apps/macos/Package.swift
    test -f apps/windows/switch_provider.py
    test -f apps/windows/Test-Switcher.ps1
    test ! -e CodexProviderManager
    test ! -e CodexProviderSwitcherWindows

- [ ] **Step 2: Verify the layout test fails**

Run:

    bash scripts/check-repository-layout.sh

Expected: failure because final paths do not exist.

- [ ] **Step 3: Move tracked sources and update ignores**

Run:

    mkdir -p apps
    git mv CodexProviderManager apps/macos
    git mv CodexProviderSwitcherWindows apps/windows

Replace old path-specific ignore entries with:

    apps/macos/.build/
    apps/macos/dist/
    apps/windows/__pycache__/
    apps/windows/tests/__pycache__/

Keep generic bytecode, credential, database, backup, and Codex scratch exclusions.

- [ ] **Step 4: Verify both applications in their final locations**

Run on macOS:

    bash scripts/check-repository-layout.sh
    cd apps/macos
    swift test --disable-index-store
    ./scripts/package-smoke.sh

Run on Windows:

    Set-Location apps/windows
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Switcher.ps1

Expected: all commands exit 0 and package output remains ignored.

- [ ] **Step 5: Commit relocation**

Run:

    git add .gitignore scripts/check-repository-layout.sh apps
    git diff --cached --check
    git commit -m "chore: organize platform apps in monorepo"

## Task 3: Add Open-Source Governance

**Files:**
- Create: README.md, CONTRIBUTING.md, SECURITY.md, CODE_OF_CONDUCT.md, CHANGELOG.md
- Create: LICENSE copied from apps/macos/LICENSE
- Create: docs/development/repository-layout.md
- Create: scripts/check-project-docs.sh

**Interfaces:**
- Consumes: final app paths and the approved program design
- Produces: public project entry points that forbid secret and user-data submission

- [ ] **Step 1: Write a failing documentation contract test**

Create scripts/check-project-docs.sh:

    #!/usr/bin/env bash
    set -euo pipefail
    for file in README.md CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md CHANGELOG.md LICENSE docs/development/repository-layout.md; do test -s "$file"; done
    rg -q 'Lansi_CodexProviderManager' README.md
    rg -q '兰司观察 Codex_Provider 切换器' README.md
    rg -q 'apps/macos' README.md
    rg -q 'apps/windows' README.md
    rg -q 'not affiliated with or endorsed by OpenAI' README.md

- [ ] **Step 2: Verify the docs test fails**

Run:

    bash scripts/check-project-docs.sh

Expected: failure because root governance files do not exist.

- [ ] **Step 3: Create mandatory documents**

README.md must open with:

    # Lansi_CodexProviderManager

    兰司观察 Codex_Provider 切换器 is a local, cross-platform provider-profile manager for an existing Codex home.

    > This independent project is not affiliated with or endorsed by OpenAI or Codex.

    The application keeps one existing CODEX_HOME. Before every verified switch it backs up the managed configuration and conversation database; it does not copy, delete, or upload conversations, Skills, MCP configuration, plugins, or API keys.

Document only apps/macos and apps/windows commands. CONTRIBUTING.md must require isolated fixtures and prohibit real Codex homes, keys, session JSONL, backups, and diagnostics. SECURITY.md must request private reports without credentials or conversation content. Use Contributor Covenant 2.1 in CODE_OF_CONDUCT.md. Add this Unreleased item to CHANGELOG.md: Initial public monorepo foundation; provider behavior unchanged.

Write docs/development/repository-layout.md:

    | Path | Owner | Rule |
    | --- | --- | --- |
    | apps/macos/ | macOS maintainers | Native SwiftUI and Swift Package implementation |
    | apps/windows/ | Windows maintainers | Native PowerShell UI and Python core implementation |
    | spec/ | Cross-platform maintainers | Shared behavior contracts and non-secret fixtures |
    | docs/ | All maintainers | Reviewed product and release documentation |
    | .github/ | Release maintainers | CI and issue/PR intake only |

- [ ] **Step 4: Verify documents and scan for likely secrets**

Run:

    bash scripts/check-project-docs.sh
    rg -n --glob '!**/.build/**' --glob '!**/dist/**' --glob '!**/__pycache__/**' '(sk-[A-Za-z0-9_-]{20,}|Bearer[[:space:]]+[A-Za-z0-9._-]{20,})' README.md CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md CHANGELOG.md docs

Expected: docs check exits 0; secret scan has no output.

- [ ] **Step 5: Commit governance**

Run:

    git add README.md CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md CHANGELOG.md LICENSE docs/development/repository-layout.md scripts/check-project-docs.sh
    git diff --cached --check
    git commit -m "docs: add open source project governance"

## Task 4: Add CI And Secret-Safe Issue Intake

**Files:**
- Create: .github/workflows/ci.yml
- Create: .github/pull_request_template.md
- Create: .github/ISSUE_TEMPLATE/bug_report.yml
- Create: scripts/check-ci-contract.sh
- Modify: README.md

**Interfaces:**
- Consumes: app entry points and checks from Tasks 2 and 3
- Produces: pull-request validation for macOS and Windows

- [ ] **Step 1: Write the failing CI contract check**

Create scripts/check-ci-contract.sh:

    #!/usr/bin/env bash
    set -euo pipefail
    workflow=.github/workflows/ci.yml
    test -s "$workflow"
    rg -q 'macos-latest' "$workflow"
    rg -q 'windows-latest' "$workflow"
    rg -q 'swift test --disable-index-store' "$workflow"
    rg -q 'Test-Switcher.ps1' "$workflow"
    rg -q 'check-repository-layout.sh' "$workflow"
    rg -q 'check-project-docs.sh' "$workflow"

- [ ] **Step 2: Verify it fails before CI exists**

Run:

    bash scripts/check-ci-contract.sh

Expected: failure because no workflow exists.

- [ ] **Step 3: Create CI**

Create .github/workflows/ci.yml:

    name: CI
    on:
      pull_request:
      push:
        branches: [main]
    jobs:
      repository-checks:
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v4
          - run: bash scripts/check-repository-layout.sh
          - run: bash scripts/check-project-docs.sh
      macos:
        runs-on: macos-latest
        steps:
          - uses: actions/checkout@v4
          - run: swift test --disable-index-store
            working-directory: apps/macos
          - run: ./scripts/package-smoke.sh
            working-directory: apps/macos
      windows:
        runs-on: windows-latest
        steps:
          - uses: actions/checkout@v4
          - shell: powershell
            run: ./Test-Switcher.ps1
            working-directory: apps/windows

The PR template must require a statement about conversation/session/Skill/MCP/plugin preservation. The bug form must request OS, version, provider type, redacted diagnostics, and recovery result, and include: Do not include API keys, auth.json, session JSONL files, database files, or conversation content.

- [ ] **Step 4: Validate workflow syntax and contract**

Run:

    bash scripts/check-ci-contract.sh
    ruby -e 'require "yaml"; YAML.load_file(".github/workflows/ci.yml"); YAML.load_file(".github/ISSUE_TEMPLATE/bug_report.yml")'

Expected: both commands exit 0.

- [ ] **Step 5: Commit CI**

Run:

    git add .github README.md scripts/check-ci-contract.sh
    git diff --cached --check
    git commit -m "ci: validate platform applications"

## Task 5: Final Phase 0 Audit

**Files:**
- Modify: CHANGELOG.md, .gitignore, or README.md only if audit finds a correction
- Test: repository-wide verification

**Interfaces:**
- Consumes: all Phase 0 paths and scripts
- Produces: a clean monorepo ready for the shared contract phase

- [ ] **Step 1: Run root checks**

Run:

    bash scripts/check-repository-layout.sh
    bash scripts/check-project-docs.sh
    bash scripts/check-ci-contract.sh
    git diff --check
    git status --short

Expected: scripts exit 0 and no untracked source or generated files remain.

- [ ] **Step 2: Run final platform checks**

Run on macOS:

    cd apps/macos
    swift test --disable-index-store
    ./scripts/package-smoke.sh

Run on Windows:

    Set-Location apps/windows
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Switcher.ps1

Expected: both suites pass using only temporary test data.

- [ ] **Step 3: Audit tracked files**

Run:

    git ls-files | rg '(^|/)(\.build|dist|__pycache__|backups|diagnostics)(/|$)' && exit 1 || true
    git grep -nE '(sk-[A-Za-z0-9_-]{20,}|Bearer[[:space:]]+[A-Za-z0-9._-]{20,})' && exit 1 || true
    git log --oneline --decorate --max-count=6
    git diff --check HEAD~4..HEAD

Expected: no prohibited paths or likely secrets; import, relocation, governance, and CI are separate commits.

- [ ] **Step 4: Commit only a necessary audit correction**

Run only if an audit correction was made:

    git add CHANGELOG.md .gitignore README.md
    git diff --cached --check
    git commit -m "docs: record monorepo foundation verification"

Expected: no behavior changes and no empty commit.

## Phase 0 Acceptance Checklist

- [ ] apps/macos and apps/windows are the platform roots.
- [ ] Existing switcher behavior is unchanged.
- [ ] Both platform suites run from final paths on their supported OS.
- [ ] Root policies describe local-only operation, independent status, recovery, and secret-safe reporting.
- [ ] CI validates layout, docs, macOS tests/package smoke, and Windows checks.
- [ ] No build output, Codex state, backup, session data, or credential is tracked.
- [ ] Git status is clean and every commit passes git diff --check.

## Execution Handoff

Plan complete and saved to docs/superpowers/plans/2026-08-09-phase-0-monorepo-foundation.md. Two execution options:

1. **Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration.

2. **Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints.
