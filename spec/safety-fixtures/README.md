# Safety Fixtures / 安全夹具

All files in this directory are synthetic and are used only for deterministic safety tests. They are not a real Codex home and must never be replaced with user configuration, credentials, sessions, or backups.

本目录中的所有文件均为合成数据，仅用于确定性的安全测试。它们不是真实 Codex 主目录，严禁替换为用户配置、凭据、会话或备份。

`expected-preservation.json` records only counts. `extensions.sha256` protects the Skills, plugin, and MCP samples against unintended mutation. The validator rejects credential-like content, mismatched hashes, and changed preservation counts.

`expected-preservation.json` 仅记录计数。`extensions.sha256` 保护 Skills、插件和 MCP 示例不被意外修改。校验器会拒绝疑似凭据、哈希不匹配和保留计数变化。
