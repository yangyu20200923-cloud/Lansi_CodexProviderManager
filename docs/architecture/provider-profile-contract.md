# Provider Profile Contract

## Source Status

Accessed 2026-08-14. The official [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference) documents `model_provider`, `env_key`, `requires_openai_auth`, and `wire_api`. Current Codex accepts only `wire_api = "responses"`; saved legacy profiles are migrated in memory before switching, and new or edited profiles must use that value.

## Contract Rule

A profile catalog is non-secret. API keys, tokens, auth files, sessions, databases, backups, and conversation content are prohibited from profile JSON and fixtures.

A field is managed only when a current official OpenAI source records its semantics. Unknown TOML keys and tables remain preserved byte content.

## Profile Shape

The portable profile has: stable UUID id, name, enabled, authMode, baseUrl, wireApi, apiKeyEnv, model, models, reasoningEffort, reviewModel, and whitelisted configOverrides. `models` is an optional non-secret, unique list of provider model IDs used by the manager UI; `model` is the selected value rendered to Codex. `authMode` is `chatgpt_login` or `api_key`. Credential values never belong in the portable profile: macOS uses its platform credential mechanism; the Windows local-browser UI writes an entered key only to the current user's named environment variable.

For API-key Providers, a model must be explicit before switching. The switcher must never silently substitute a GPT model for a provider such as DeepSeek. The manager may populate `models` manually or by a read-only `GET <baseUrl>/models` request using the provider's environment-backed key; the response is reduced to model IDs and never persisted with credentials.

The Windows browser UI sends an entered key only to a loopback, session-token-protected write endpoint after the non-secret Provider has been saved. The endpoint returns only a success flag; it does not put key material in the catalog, exported JSON, state payload, diagnostics, logs, or error messages. A boolean credential status may be shown to the local UI without exposing the value. Windows user environment variables are not an encrypted vault, so the Windows account must be protected.
