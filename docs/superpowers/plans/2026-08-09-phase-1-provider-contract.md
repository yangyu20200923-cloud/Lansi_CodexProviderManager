# Phase 1 Shared Provider Contract Implementation Plan

**Goal:** Define one non-secret Provider Profile contract, TOML ownership map, and fixture corpus that both native applications must implement identically.

**Architecture:** JSON Schema is the portable validation source. A human-readable contract records which Codex configuration fields are managed, preserved, or prohibited. Fixtures use synthetic configuration and SQLite data only; platform tests compare normalized rendered output.

**Tech Stack:** JSON Schema Draft 2020-12, TOML fixtures, Swift XCTest, Python unittest.

## Global Constraints

- Do not use a real CODEX_HOME, key, auth file, session, backup, or database.
- Schema catalogs never contain credential values.
- Confirm every Codex-managed TOML field against current official OpenAI documentation before making it writable.
- Unknown or unsupported Codex fields are preserved, never emitted.
- Test fixtures must prove that conversations, Skills, MCP configuration, and plugins are not changed.

## Task 1: Establish Contract Sources

**Files:**
- Create: docs/architecture/provider-profile-contract.md
- Create: docs/architecture/codex-toml-ownership.md
- Create: spec/README.md

- [ ] Fetch the current official OpenAI Codex configuration documentation and record URL, access date, supported version, and exact field semantics.
- [ ] Mark every field as managed, preserved, or prohibited. Start with model, model_provider, model_reasoning_effort, review_model, history.persistence, model_providers.<key>.name, base_url, wire_api, and env_key.
- [ ] State that a missing official source leaves the field preserved-only.
- [ ] Commit: git commit -m "docs: define provider contract ownership"

## Task 2: Add Profile JSON Schema

**Files:**
- Create: spec/provider-profile.schema.json
- Create: spec/examples/openai-chatgpt.profile.json
- Create: spec/examples/openai-compatible.profile.json
- Test: spec/tests/validate_profiles.py

- [ ] Write a failing validator test for valid built-in and API-key profiles, invalid UUIDs, invalid environment-variable names, credentials in JSON, and unapproved configOverrides.
- [ ] Implement Draft 2020-12 schema with id, name, enabled, authMode, baseUrl, wireApi, apiKeyEnv, model, reasoningEffort, reviewModel, and whitelisted configOverrides.
- [ ] Run: python3 spec/tests/validate_profiles.py. Expected: valid examples pass; invalid examples fail.
- [ ] Commit: git commit -m "feat: add provider profile schema"

## Task 3: Add Shared Configuration Fixtures

**Files:**
- Create: spec/config-fixtures/base-config.toml
- Create: spec/config-fixtures/expected-openai.toml
- Create: spec/config-fixtures/expected-compatible.toml
- Create: spec/config-fixtures/README.md
- Create: spec/fixtures/threads.sql

- [ ] Create synthetic TOML with unrelated plugin, MCP, custom-provider, and comment content.
- [ ] Create expected normalized outputs that change only contract-managed fields.
- [ ] Create synthetic threads data with no real conversation content.
- [ ] Add a fixture manifest containing SHA-256 hashes for immutable extension samples.
- [ ] Commit: git commit -m "test: add provider contract fixtures"

## Task 4: Wire Platform Contract Tests

**Files:**
- Modify: apps/macos/Tests/ProviderCoreTests/CodexConfigServiceTests.swift
- Modify: apps/windows/tests/test_switch_provider.py
- Create: apps/macos/Tests/ProviderCoreTests/ContractFixtureTests.swift
- Create: apps/windows/tests/test_contract_fixtures.py

- [ ] Write failing tests that load the same fixture profiles and expected TOML outputs.
- [ ] Add fixture-path resolution without reading user configuration.
- [ ] Implement only the contract adapter necessary for both suites to compare normalized output.
- [ ] Run macOS: cd apps/macos && swift test --disable-index-store.
- [ ] Run Windows: cd apps/windows && powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Switcher.ps1.
- [ ] Commit: git commit -m "test: enforce cross-platform provider contract"

## Task 5: Phase 1 Audit

- [ ] Run JSON validation, fixture hash verification, macOS tests, Windows tests, secret scan, and git diff --check.
- [ ] Verify all new profiles and fixtures are synthetic and no unsupported TOML key is marked managed.
- [ ] Update CHANGELOG.md with the contract addition.
- [ ] Commit only required audit corrections.
