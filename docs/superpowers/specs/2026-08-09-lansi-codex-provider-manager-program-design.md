# Lansi_CodexProviderManager Program Design

## Status And Purpose

This document is the approved architecture and delivery dispatch for the open-source project named **Lan Si Observation Codex_Provider Switcher** (Chinese: `兰司观察 Codex_Provider 切换器`; English repository and release name: `Lansi_CodexProviderManager`).

It consolidates the existing macOS and Windows switchers into one Git monorepo while keeping their native implementations. Its highest-priority outcome is safe provider switching without losing conversations, sessions, Skills, MCP configuration, plugins, or project configuration.

This is a program-level design, not one implementation plan. Each numbered delivery phase must receive its own approved implementation plan before code changes begin.

## Product Guarantees

1. A switch uses the user's existing `CODEX_HOME` (normally `~/.codex` on macOS and `%USERPROFILE%\\.codex` on Windows). It never creates a separate Codex home for a provider.
2. Historical conversations remain present and resumable after a switch. The switcher preserves thread records, session JSONL files, session identifiers, conversation content, and project context.
3. Existing threads are routed to the newly selected provider after a successful switch so a user can resume the previous development conversation using the active provider. The prior state is recoverable from the pre-switch backup.
4. Skills, MCP definitions, plugin configuration, plugin and skill directories, marketplace settings, AGENTS instructions, and unrelated Codex configuration are preserved.
5. A failed switch must leave the pre-switch configuration and session database restored. A failure can never be reported as success.
6. API keys are never written into the profile catalog, repository, diagnostics, logs, or backup manifests. They are masked in the UI.

## Repository Architecture

The repository becomes a monorepo with native platform clients and a shared behavioral contract.

```text
Lansi_CodexProviderManager/
  apps/
    macos/                 # Existing SwiftUI + Swift Package app, migrated from CodexProviderManager/
    windows/               # Existing WinForms PowerShell UI + Python core, migrated from CodexProviderSwitcherWindows/
  spec/
    provider-profile.schema.json
    config-fixtures/
    switch-contract.md
  docs/
    architecture/
    development/
    release/
    superpowers/specs/
  .github/
    workflows/
    ISSUE_TEMPLATE/
  README.md
  CONTRIBUTING.md
  SECURITY.md
  CODE_OF_CONDUCT.md
  CHANGELOG.md
  LICENSE
```

The two applications deliberately do not share runtime source code: Swift and the Windows PowerShell/Python stack retain native process management, credential integration, and packaging. They share schemas, fixtures, expected rendered configuration, invariants, documentation, and CI acceptance criteria.

The repository must state that it is an independent local utility and is not affiliated with or endorsed by OpenAI or Codex.

## Current Alignment Analysis

| Concern | macOS current state | Windows current state | Alignment target |
| --- | --- | --- | --- |
| UI/runtime | SwiftUI app with Swift core | PowerShell WinForms UI with Python core | Preserve native UI/runtime on both platforms |
| Provider catalog | Closed `ProviderID` enum: OpenAI, Qilin, VectorEngine | Fixed Python dictionary and fixed UI list | Dynamic profile catalog with built-in templates |
| Editable fields | Name, URL, wire API; model disabled in UI | No provider connection fields exposed | Same editable profile fields on both platforms |
| Config writes | Mainly `model_provider` and selected provider block | `model`, `model_provider`, reasoning effort, `review_model`, history persistence, managed tables | One documented managed-field contract and equivalent output |
| Credentials | macOS Keychain | Windows user environment variables | Platform-native secret stores; no secret in profile files |
| History handling | SQLite thread provider update and snapshot invariant | SQLite thread provider update, preview repair, post-write readback | One transaction/backup/recovery contract |
| Extensions | Existence-set snapshot of `skills`, `plugins`, `mcp` | Configuration preservation tests | Content-aware extension fingerprint checks on both platforms |
| Restore | Automatic restore after failed switch | Manual latest-backup restore | Automatic rollback plus user-visible restore on both platforms |

## Shared Provider Profile Contract

Profiles are stored in a non-secret catalog, validated against `spec/provider-profile.schema.json`, and carry a stable UUID independent of display name or endpoint.

Required behavior for every profile:

| Field | Meaning |
| --- | --- |
| `id` | Immutable UUID used for local profile identity; the generated Codex provider key is separately validated |
| `name` | User-visible provider name |
| `enabled` | Whether it appears as a selectable target |
| `authMode` | `chatgpt_login` or `api_key` |
| `baseUrl` | API base URL for `api_key` profiles |
| `wireApi` | `responses`, `chat_completions`, or a validated custom Codex wire API value |
| `apiKeyEnv` | Optional validated environment-variable name for Windows and import compatibility |
| `model` | Default model supplied to Codex |
| `reasoningEffort` | Optional Codex reasoning level |
| `reviewModel` | Optional review model |
| `configOverrides` | Explicitly whitelisted additional managed configuration values; arbitrary TOML injection is prohibited |

Built-in templates are OpenAI/ChatGPT, Qilin, and VectorEngine. A user can create, edit, duplicate, disable, export, import, and delete non-built-in profiles. Built-in templates are editable copies rather than permanently privileged fixed records, except that `chatgpt_login` has no API key field.

The catalog must exclude secret values. macOS stores an API key in Keychain under the profile UUID. Windows stores an API key in the selected user-scoped environment variable; its value must not enter command-line arguments or subprocess output.

## Switching Transaction

The two implementations must satisfy this common transaction sequence:

1. Resolve `CODEX_HOME`, load the target profile, validate every required field, and run a read-only preflight.
2. Detect active Codex/Desktop/CLI processes and obtain an explicit user decision to close them. Do not mutate SQLite while relevant processes remain active.
3. Acquire a per-Codex-home exclusive lock with stale-lock recovery and a bounded timeout.
4. Capture an invariant snapshot and create a timestamped backup of `config.toml`, `state_5.sqlite`, and SQLite WAL/SHM state when present.
5. Render configuration by changing only documented root keys, the selected generated provider table, the `history.persistence` setting, and approved overrides. Preserve all unrelated TOML tables and comments to the degree supported by the chosen editor.
6. Atomically replace the configuration file and update `threads.model_provider` in a single SQLite transaction. Repair only documented compatibility fields such as an empty preview when required by a tested Codex schema.
7. Re-read files and database, verify the target provider routing and all preservation invariants, then commit the database transaction.
8. On any error after backup creation, restore config and SQLite state, clear temporary files, release the lock, and report recovery status with no secret values.
9. Offer to relaunch Codex only after verified success or verified recovery.

No profile is allowed to direct the switcher to delete, move, truncate, or replace the `sessions`, `skills`, `plugins`, or MCP directories.

## Preservation Invariants

The preflight snapshot and post-switch verification must compare:

| Asset | Required invariant |
| --- | --- |
| Threads database | Total thread count cannot decrease; visible thread count cannot decrease; each existing thread remains addressable |
| Session files | JSONL file relative-path set, count, byte length, and SHA-256 digest cannot change |
| Skills | Relative-path manifest with SHA-256 digests cannot change |
| Plugins | Relative-path manifest with SHA-256 digests cannot change |
| MCP | MCP-related config tables and local MCP manifest cannot change except for fields expressly owned by a profile override |
| Unrelated Codex config | A normalized diff must contain only the documented managed fields |

The target Provider assignment for existing threads is a deliberate routing update, not a history deletion. The backup must retain the original thread metadata so the user can recover it through the application.

## Open-Source Baseline

Before public release, add and maintain:

- Root `README.md` in Chinese and English, including supported platforms, safe-use limitations, recovery steps, and independent-project notice.
- `CONTRIBUTING.md` with local test commands, fixture policy, and no-secret rules.
- `SECURITY.md` with a private vulnerability reporting path and scope.
- `CODE_OF_CONDUCT.md`, `CHANGELOG.md`, MIT `LICENSE`, `.gitignore`, and release versioning policy.
- GitHub issue and pull-request templates that require platform, Codex version, anonymized diagnostics, and rollback outcome.
- A release checklist with checksums, SBOM/dependency inventory, signing/notarization status, and verified artifacts.

## Delivery Dispatch

### Phase 0: Monorepo Foundation

Initialize the root Git repository; move existing applications into `apps/macos` and `apps/windows`; add root documentation, ignore rules, license, release policy, and source-of-truth ownership rules. Do not rewrite platform behavior in this phase.

**Exit criteria:** clean CI skeleton, no build products or local credentials tracked, and both apps remain buildable from their new paths.

### Phase 1: Shared Contract And Fixtures

Define the profile JSON Schema, TOML ownership map, config/database fixtures, invariant snapshot format, and cross-platform expected-output tests. Resolve actual supported Codex configuration semantics against current upstream documentation before freezing fields.

**Exit criteria:** both platforms pass the same fixture suite or explicitly documented platform adaptation tests.

### Phase 2: Shared Safety Guarantees

Implement equivalent locking, process quiescence, SQLite-consistent backup including sidecars, atomic replacement, readback verification, automatic rollback, restore UI, and fully redacted diagnostics.

**Exit criteria:** fault-injection tests prove config/database rollback; all preservation invariants pass before and after successful and failed switches.

### Phase 3: Windows Dynamic Profiles

Replace the fixed provider dictionary and fixed UI selection with catalog-driven profile management. Add profile CRUD, duplicate/import/export, editable connection and Codex fields, environment-variable validation, masked credentials, and contract rendering.

**Exit criteria:** a user-created fixture profile can be preflighted, switched, restored, and removed without affecting unrelated Codex state.

### Phase 4: macOS Dynamic Profiles And Contract Parity

Replace the closed provider enum with UUID-backed dynamic profiles. Enable model editing, reasoning effort, review model, history persistence, safe profile CRUD/import/export, and equivalent config rendering and diagnostics.

**Exit criteria:** macOS generates the same managed configuration outcome as Windows for every shared fixture.

### Phase 5: Contract, Regression, And Compatibility Testing

Add tests for all profiles, malformed TOML, duplicate keys, unknown database schemas, lock contention, live-process refusal, missing credentials, failed config replacement, failed SQLite commit, recovery, extension mutation detection, and secret redaction.

**Exit criteria:** CI tests are deterministic and isolated; no test opens a real Codex home or accesses a real credential.

### Phase 6: CI, Packaging, And Public Release

Create GitHub Actions for Swift build/test on macOS and Python/PowerShell tests on Windows. Publish signed or clearly unsigned artifacts with checksums and platform-specific installation/recovery instructions. Add macOS signing/notarization as a release requirement when a Developer ID is available.

**Exit criteria:** a tagged release has reproducible build instructions, tested artifacts, checksums, changelog entries, and documented known limitations.

## Risks And Non-Goals

- Provider compatibility is external: each endpoint must support the selected Codex wire API, model, tool behavior, and context capacity. Connection success does not guarantee full Codex feature parity.
- A provider switch cannot make an incompatible model preserve unsupported tool states. The app must preflight and clearly warn; it must never falsely promise provider equivalence.
- The switcher manages only its explicitly owned configuration fields. It is not a general TOML editor and must not serialize arbitrary user configuration.
- Cloud synchronization of profiles or keys is out of scope for the first open-source release.
- Real user Codex homes and live credentials are never CI fixtures or submitted bug-report artifacts.

## Documentation Dispatch

After this approved program design, create these reviewed documents in order:

1. `docs/superpowers/plans/` Phase 0 implementation plan.
2. `docs/architecture/provider-profile-contract.md` and `spec/provider-profile.schema.json` design/contract.
3. Phase 1 implementation plan.
4. `docs/architecture/switch-safety-and-recovery.md` design/contract.
5. Phase 2 implementation plan.
6. Separate Windows and macOS dynamic-profile specifications and plans for Phases 3 and 4.
7. `docs/release/open-source-release-checklist.md` and Phase 6 plan.

Every plan must reference this document, define exact file ownership, use isolated fixtures, and include platform-specific verification.
