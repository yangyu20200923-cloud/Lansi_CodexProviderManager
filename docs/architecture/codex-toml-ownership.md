# Codex TOML Field Ownership

## Evidence Rule

Official field documentation was inaccessible from this environment on 2026-08-09. The local Codex CLI confirms TOML configuration and --strict-config but not the semantics of provider-routing keys. The following existing cross-platform compatibility fields are temporarily managed only through synthetic fixture comparisons.

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
| unknown keys and tables | preserved | Preserve byte content where possible; never emit |

Skills, MCP configuration, plugins, marketplace settings, AGENTS instructions, and session files are outside the managed TOML surface and are prohibited from mutation.
