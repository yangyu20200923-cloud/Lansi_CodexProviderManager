# Codex TOML Field Ownership

## Evidence Rule

Official field documentation was inaccessible from this environment on 2026-08-09. The local Codex CLI confirms TOML configuration and --strict-config but not the semantics of provider-routing keys. Therefore no TOML key is Phase 1 managed yet.

| Field or table | Phase 1 ownership | Rule |
| --- | --- | --- |
| model | preserved | Do not add, delete, or rewrite |
| model_provider | preserved | Do not add, delete, or rewrite |
| model_reasoning_effort | preserved | Do not add, delete, or rewrite |
| review_model | preserved | Do not add, delete, or rewrite |
| history.persistence | preserved | Do not add, delete, or rewrite |
| model_providers.<key>.name | preserved | Do not add, delete, or rewrite |
| model_providers.<key>.base_url | preserved | Do not add, delete, or rewrite |
| model_providers.<key>.wire_api | preserved | Do not add, delete, or rewrite |
| model_providers.<key>.env_key | preserved | Do not add, delete, or rewrite |
| unknown keys and tables | preserved | Preserve byte content where possible; never emit |

Skills, MCP configuration, plugins, marketplace settings, AGENTS instructions, and session files are outside the managed TOML surface and are prohibited from mutation.
