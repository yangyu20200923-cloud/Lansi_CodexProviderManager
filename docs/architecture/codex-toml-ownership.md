# Codex TOML Field Ownership

## Evidence Rule

The official [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference), checked on 2026-08-14, defines the managed provider-routing surface below. `wire_api` is constrained to `responses`; `requires_openai_auth = true` is rendered only for a custom ChatGPT-login profile.

| Field or table | Phase 1 ownership | Rule |
| --- | --- | --- |
| model | compatibility-managed | Existing Windows behavior; must match fixture contract |
| model_provider | compatibility-managed | Existing macOS and Windows behavior; must match fixture contract |
| model_reasoning_effort | compatibility-managed | Existing Windows behavior; macOS parity required |
| review_model | compatibility-managed | Existing Windows behavior; macOS parity required |
| history.persistence | compatibility-managed | Existing Windows behavior; macOS parity required |
| model_providers.<key>.name | compatibility-managed | Existing platform provider configuration |
| model_providers.<key>.base_url | compatibility-managed | Existing platform provider configuration |
| model_providers.<key>.wire_api | compatibility-managed | Existing platform provider configuration |
| model_providers.<key>.env_key | compatibility-managed | Existing platform provider configuration |
| model_providers.<key>.requires_openai_auth | managed | Needed for a custom profile that uses ChatGPT authentication instead of `env_key` |
| unknown keys and tables | preserved | Preserve byte content where possible; never emit |

Skills, MCP configuration, plugins, marketplace settings, AGENTS instructions, and session files are outside the managed TOML surface and are prohibited from mutation.
