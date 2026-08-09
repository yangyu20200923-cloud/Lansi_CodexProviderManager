# Provider Profile Contract

## Source Status

Accessed 2026-08-09. Official OpenAI Codex documentation at https://developers.openai.com/codex/ and attempted configuration routes returned HTTP 403 from this environment, so they do not establish field-level semantics.

Observed local compatibility evidence: Codex CLI 0.147.0-alpha.6.5 documents configuration overrides as TOML and offers --strict-config. This does not authorize the switcher to emit any particular provider field.

## Contract Rule

A profile catalog is non-secret. API keys, tokens, auth files, sessions, databases, backups, and conversation content are prohibited from profile JSON and fixtures.

A field may become managed only when a current, accessible official OpenAI source records its semantics. Until then, both platforms preserve it and never add, remove, or rewrite it under the Phase 1 contract.

## Profile Shape

The future portable profile has: stable UUID id, name, enabled, authMode, baseUrl, wireApi, apiKeyEnv, model, reasoningEffort, reviewModel, and whitelisted configOverrides. authMode is chatgpt_login or api_key. Credential values are held only by platform-native secret storage.
