# Lansi Codex Provider Manager Roadmap

Status: GOVERNED_BASELINE

This roadmap orders `PRODUCT_CONTRACT.md`; it grants no access to a real Codex
home and no merge, publication, signing, notarization, or release authority.

## Autopilot Status

| Field | Value |
| --- | --- |
| Execution | `CONTINUOUS` |
| Lifecycle | `PAUSED` |
| Current Phase | `P3` — packaged artifacts and open-source release evidence |
| Current acceptance | `LCP-06` / `PASS` |
| Next Phase | release close |
| Next acceptance | `RELEASE-CLOSE` — authorize GitHub push, PR/merge, and internal-candidate publication |
| Exact candidate | `agent/lcp-phase0-rescue-20260810` working tree rebuilt on the 00:46 baseline: macOS switch flow enforces `wire_api = "responses"`, restores the recorded OpenAI root configuration, routes threads and rollout `session_meta.model_provider`, normalizes plaintext `reasoning.content` before snapshot so qilin / vectorengine / DeepSeek and the OpenAI official login switch freely, writes the managed model catalog with upstream `/models` fetch and in-app search, detects ChatGPT/Codex processes through `/bin/ps`, reclaims a Provider Manager lock only when its recorded owner PID is confirmed dead, and restarts the ChatGPT runtime reliably after a switch: `quit()` now terminates the full ChatGPT-owned process tree (main app plus crashpad/renderer/helper processes that keep LaunchServices reporting the app as running), `launch()` polls for the main process and retries with `open -n` as a forced-new-instance fallback, every switch writes a phase-by-phase `state/switch.log` under the managed Codex home for real-machine diagnosis, and all subprocess capture goes through temporary files instead of pipes because the real `ps -axo pid=,ppid=,args=` table (~126 KB) exceeds the 64 KB pipe buffer and previously deadlocked `quit()` right after `switch start` (proven by the stale lock owner PID and the untouched ChatGPT process), preserved roots (sessions/skills/plugins) are snapshotted with APFS clones instead of physical copies (3.2 GB sessions: 0.07 s vs ~90 s; checksums cover only managed files, restore verifies preserved roots by count/size), session rollout normalization scans in parallel, and the switch reports live phase progress to the UI so users no longer mistake the snapshot step for a hang and force-quit the app. The 99-test suite (including pipe-buffer, clone-backup, restore-stats, and phase-callback acceptance) passes. Real-machine switch smoke on the actual Codex home passed for qilin, vectorengine, and DeepSeek in sequence: each switch completed in ~30 s (`runtime quit and quiescent` -> `normalized ... of 422 session files` -> `backup created` -> `config applied` -> `environment set` -> `configuration verified` -> `runtime launch requested` -> `runtime launch verified` -> `switch complete`, see `~/.codex/state/switch.log`), the ChatGPT main process PID matches the launch-verified timestamp, `launchctl` carries all three provider keys, and each switch produced a clone-backed 3.2 GB session backup under `~/.codex/backups/CodexProviderManager/`. macOS window now opens at a default size and is auto-grown at launch directly through NSApp whenever the restored frame is smaller than the full form grid (so a remembered small frame can no longer clip content), status rows (history/extensions/backup and the live status message) render fully without line-count truncation, the form grid's fixed-width placeholder column and the model-catalog list now compress responsively so custom providers stay fully visible at any window width, model-list governance landed on macOS with a clear two-zone UI: the managed list section (explicitly labeled as written to Codex, current-model selector, manual add field, per-row checkbox selection, Select All / Remove Selected / Clear List batch actions, 100-model cap) is separated from the upstream section (explicitly labeled as not written, Fetch Models, Add-All/Ignore, per-row checkboxes with Add Selected batch action and single Add-to-List); fetching never auto-writes, search filters both zones, and provider switches render only the user-managed list instead of injecting the full upstream catalog, backup governance landed on both platforms (keep newest 5, 20 GB logical byte cap, 14-day age limit, oldest-first eviction with pinned exemption, backup-management UI with count/size/delete/pin/clean-up on macOS and count/size/clean-up on Windows, legacy manifests decoded with zero-byte fallback and background size backfill), and Windows parity landed: the Windows source was restored from the 00:46 worktree snapshot (fixing broken profile_catalog/switch_provider imports and the missing normalized_session_items field), preservation snapshots now use fast count/size stats instead of hashing gigabytes of session rollouts, and every Windows switch/restore writes phase lines to `state/switch.log` exactly like macOS (Windows 111-test suite green, macOS 99-test suite green). Remaining: real-machine return-switch to the OpenAI official login on macOS. |
| Pause reason | GitHub HTTPS push failed twice on August 18, 2026: HTTP/2 framing error, then `github.com:443` connection timeout. |
| Windows implementation | Windows 原生编辑器现与 macOS 对齐：上游模型在非阻塞、可取消的请求后仅暂存，用户可手动添加、搜索、全选移除、清空或批量加入受管模型列表，列表上限 `100`；编辑已保存 Provider 时的加入/移除立即持久化。切换链路现在会预检目标 API，验证目标服务的访问密钥，清除上一服务的用户环境变量，关闭完整 Codex 进程树，并直接定位已安装的 Codex 可执行文件，以“旧密钥已移除、目标密钥已注入”的新进程环境重新启动和验证 Codex；旧会话中的 `qilin`、旧自定义 ID 等历史 Provider 名称会生成指向当前目标服务的兼容表，不再出现 `Model provider ... not found`。Windows 模型目录字段已与 Mac 的 Codex 目录一致，使用真实模型显示名、`shell_type=default`、并行调用和 `model_messages`，不再把所有模型归类为泛化的“自定义”。找不到可执行文件或任一校验失败时明确失败，绝不将切换标为成功。UI 按“预检、关闭、整理会话、备份、应用、验证、启动、完成”显示当前步骤。 |
| Latest evidence | `2026-08-18`: Windows 自动回归 `124/124 PASS`，涵盖旧密钥清理、目标 API 预检、配置注入、阶段回调、进程树切换、直接环境启动、历史 Provider 兼容表、多选添加、当前模型不在已选列表时的后续添加，以及模型目录显示字段；等待 Windows 真机确认完整切换与模型显示链路。macOS 已真机通过“获取模型”和取消、仅保留 `gpt-*` 受管模型时的 Provider 切换，以及切回 OpenAI 官方登录；`swift test --disable-index-store` 为 `104/104 PASS`。 |
| Current verdict | `LCP-01`、`LCP-02`、`LCP-03`、`LCP-04`、`LCP-05`、`LCP-06` 证据均已通过，当前候选达到 `RELEASE_READY`（发布边界：`INTERNAL_CANDIDATE`）。按项目规则，当前产品仍不标记为 Beta 或 Stable。 |
| Last reconciled | `2026-08-18` |

## Phase Map

| Phase | Status | Goal and user result | Acceptance IDs | Entry | Exit | Next |
| --- | --- | --- | --- | --- | --- | --- |
| `P0` | complete | Establish the open-source monorepo, shared profile semantics, and isolated safety foundations. | Supporting foundation | Product contract available | Both platform implementations can be exercised in isolated homes | `P1` |
| `P1` | in progress | Users manage and switch arbitrary Providers end to end from native Windows and macOS desktop applications without editing config files. | `LCP-01`, `LCP-02` | P0 ready | Both platform lifecycle journeys pass with persistence | `P2` |
| `P2` | approved | Users get identical profile fields and preservation/recovery behavior on both platforms. | `LCP-03`, `LCP-04` | P1 behaviors exist | Shared fixtures and failure recovery prove parity and continuity | `P3` |
| `P3` | approved | Normal users can install, diagnose, switch, restore, uninstall, build, and audit exact Beta artifacts. | `LCP-05`, `LCP-06` | P2 exact candidate passes | All six core IDs pass against exact packaged artifacts | release close |

## Mainline

Resume at `LCP-04` to remove volatile plugin-cache copying and prove that
switch recovery changes only managed configuration and database state. Then
complete the Windows Python native desktop lifecycle for `LCP-01`; keep
macOS/Windows profile fields tied to the same fixture semantics.

## Transition Rules

- A fixed Provider list is a prototype, not completion.
- Never use real `~/.codex`, real keys, or user sessions as automated fixtures.
- After the last ID, reconcile every core acceptance and release requirement
  against the exact packaged artifacts before declaring Beta readiness.
- Signing, notarization, public release, push, merge, and publication retain
  separate explicit authorization.
