# Codex Provider Manager Development Runbook

## Start Or Resume

1. Read `PRODUCT_CONTRACT.md`, `PRODUCT_ROADMAP.md`, and `AGENTS.md`.
2. Reconcile `session-governance/registry.json.program` with the roadmap, Git
   working tree, exact candidate, and current task owner.
3. Preserve all existing dirty files and the two protected pre-migration source
   directories. Select one `LCP-*` ID and its user-visible result.

## Focused Development And Verification

macOS:

```bash
cd apps/macos
swift test --disable-index-store
./scripts/build-app.sh
./scripts/package-smoke.sh
```

Windows, on a real supported Windows host:

```powershell
cd apps\windows
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Switcher.ps1
```

Repository contracts:

```bash
bash scripts/check-repository-layout.sh
bash scripts/check-project-docs.sh
bash scripts/check-ci-contract.sh
```

Use the narrowest checks that prove the active ID. A platform unit suite does
not replace its required real UI lifecycle, persistence, switch, failure, or
restart journey.

## Isolation And Evidence

Every automated switch test uses a newly created temporary Codex home, profile
store, fixture UUID, Keychain service name, and output directory. Record the
fixture, exact source/package identity, command, result counts, UI journey, and
digest comparison. Never read or alter real `~/.codex`, real sessions, Skills,
plugins, MCP configuration, keys, or backups.

## Git And Release

Use a task branch and stage intended files explicitly. Run focused tests,
`git diff --check`, and credential scanning before an authorized commit. Do not
push protected branches directly. Draft PR, merge, signing, notarization,
publishing, and release are separately authorized actions. See platform READMEs
and `docs/architecture/` for contract and recovery details.

## Failure Recovery

Keep the same ID for defects. Run one bounded root-cause audit when direction is
unclear; do not repeatedly rebuild unchanged candidates. A missing real Windows
host, developer identity, or external account can pause the relevant evidence,
but it cannot be relabeled as product `PASS` or used to narrow the contract.
