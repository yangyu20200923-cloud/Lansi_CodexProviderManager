# Switch Safety and Recovery Contract / 切换安全与恢复契约

## Purpose / 目的

This contract defines the safety boundary shared by Windows and macOS when changing a Provider in one existing `CODEX_HOME`. It protects recoverability, not Provider compatibility: a successful switch does not claim that an endpoint supports every Codex feature.

本契约定义 Windows 与 macOS 在同一个既有 `CODEX_HOME` 中切换 Provider 时必须遵守的安全边界。它保障可恢复性，不承诺 Provider 完全兼容 Codex 的全部功能。

## Non-Negotiable Invariants / 不可违反的约束

- Use one existing `CODEX_HOME`; never relocate, delete, or recreate session history, Skills, plugins, MCP configuration, `AGENTS.md`, or unrelated configuration.
- Before a write, capture preservation evidence for thread counts, session JSONL count, and extension-tree hashes. A switch may change only compatibility-managed TOML fields and approved thread routing metadata.
- API keys, bearer tokens, auth files, session content, database rows, and absolute home paths must never appear in diagnostics, logs, manifests, fixtures, or UI status.
- A failed switch must either restore the pre-switch config and database state automatically or return a recovery-required result that identifies a redacted backup ID. It must never report success after a failed verification.

- 使用一个既有 `CODEX_HOME`；不得迁移、删除或重建会话历史、Skills、插件、MCP 配置、`AGENTS.md` 或无关配置。
- 写入前必须记录线程计数、会话 JSONL 数量和扩展目录哈希。切换仅可修改兼容性托管 TOML 字段与已批准的线程路由元数据。`plugins/cache` 是由 Codex 独立更新的运行时缓存：切换器既不复制、哈希、移动也不恢复它；其余受保护根目录只做不变性校验，失败回退仅恢复由切换器写入的配置和会话数据库。
- API Key、Bearer Token、认证文件、会话内容、数据库行和绝对主目录路径不得出现在诊断、日志、清单、夹具或 UI 状态中。
- 切换失败时，必须自动恢复切换前的配置和数据库，或返回带脱敏备份 ID 的“需要恢复”结果；验证失败后绝不能报告成功。

## Required Protocol / 必需协议

1. **Preflight / 预检**: validate the non-secret profile, locate required files, reject an unsupported database schema, and refuse a live Codex process. A process that cannot be confirmed quiescent is a refusal, not a condition to kill.
2. **Exclusive lock / 排他锁**: acquire a switcher-owned lock before taking the snapshot. The lock carries an owner ID and creation time; stale-lock reclamation requires a dead-owner check, never age alone.
3. **Snapshot / 快照**: create a timestamped backup directory with a redacted manifest. Copy `config.toml` with metadata. Back up SQLite using the SQLite online-backup API after quiescence; do not create a raw `.sqlite` plus separately copied WAL/SHM snapshot.
4. **Apply / 应用**: render only the Phase 1 compatibility-managed TOML fields into a same-directory temporary file, flush it, and atomically replace `config.toml`. Update approved thread metadata in one `BEGIN IMMEDIATE` transaction.
5. **Readback verification / 读回验证**: reopen the config and database after replacement and commit. Verify the selected Provider, expected routing metadata, preservation snapshot, extension hashes, and absence of inline secrets in managed Provider blocks.
6. **Recovery / 恢复**: on every post-snapshot failure, roll back an open database transaction, restore config atomically, restore SQLite through the online-backup API, remove only switcher-owned temporary files, and verify the restored preservation snapshot.
7. **Release / 释放**: release the lock in a `finally`/`defer` path only after success or completed recovery. Launch Codex only after successful verification or successful restoration.

## Backup and Restore / 备份与恢复

Backup manifests contain only: format version, opaque backup ID, creation time, relative artifact names, SHA-256 checksums, and preservation counts. They never contain file contents, absolute paths, keys, or thread text. Retention may prune only unpinned switcher-created backup directories.

备份清单仅包含：格式版本、不透明备份 ID、创建时间、相对文件名、SHA-256 校验值和保留计数。不得包含文件内容、绝对路径、密钥或线程文本。保留策略只能清理未固定的、由切换器创建的备份目录。

Restore first snapshots the current recoverable state, then restores the selected manifest atomically. The UI presents backup ID, time, verification result, and recovery outcome; it never displays raw paths or credentials.

恢复前必须先快照当前可恢复状态，再原子恢复选定清单。UI 仅显示备份 ID、时间、验证结果和恢复结果；不得显示原始路径或凭据。

## Diagnostics / 诊断

A diagnostic snapshot may contain: active Provider ID, phase, redacted error class, backup ID, lock state, thread/session counts, extension hash verdicts, and verification verdicts. Paths use `<CODEX_HOME>/...`; secrets are replaced with `<REDACTED>`. Redaction occurs before values cross a platform-service boundary.

诊断快照可包含：当前 Provider ID、阶段、脱敏错误类别、备份 ID、锁状态、线程/会话计数、扩展哈希结论和验证结论。路径使用 `<CODEX_HOME>/...`；敏感值替换为 `<REDACTED>`。脱敏必须在数据跨越平台服务边界前完成。

## Fault-Injection Acceptance / 故障注入验收

Both platforms must use synthetic homes to test lock contention, live-process refusal, malformed schema refusal, config replacement failure, database commit failure, verification failure, and restore failure. Each test proves that the preservation snapshot is unchanged after recovery. No test may open a real `CODEX_HOME` or use a real credential.

两个平台必须使用合成主目录测试锁竞争、活动进程拒绝、不支持 schema 拒绝、配置替换失败、数据库提交失败、验证失败和恢复失败。每个测试都要证明恢复后的保留快照未变化。不得使用真实 `CODEX_HOME` 或真实凭据。
