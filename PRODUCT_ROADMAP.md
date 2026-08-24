# Lansi Codex Provider Manager Roadmap

Status: GOVERNED_BASELINE

This roadmap orders `PRODUCT_CONTRACT.md`; it grants no access to a real Codex
home and no merge, publication, signing, notarization, or release authority.

## Autopilot Status

| Field | Value |
| --- | --- |
| Execution | `CONTINUOUS` |
| Lifecycle | `ADVANCE` |
| Current Phase | `P5` — Windows Provider v2 alignment |
| Current acceptance | `LCP-08` / `VERIFY` |
| Next Phase | `P5` |
| Next acceptance | `LCP-09` — close cross-platform Provider v2 migration and exchange |
| Exact candidate | Published prerelease `v0.2.0-internal.1` at commit `d0d495c3d3cbce01ca22e4e64d7551525ba80655`: accepted macOS LCP-07 implementation plus Windows Provider v2 package with Restart Manager normal-exit repair; iOS frozen. |
| Active delta | `LCP-08` release close is complete. Advance to `LCP-09` exact packaged cross-platform migration and exchange without merging PR #2 or changing the frozen iOS scope. |
| Pause reason | None. |
| Windows implementation | Windows 原生编辑器现与 macOS 对齐：上游模型仅暂存并由用户加入受管列表。切换链路会预检目标 API、验证访问密钥并清除其他 Provider 的用户环境变量。运行时先向可见主窗口发送 `WM_CLOSE`，再通过 Windows Restart Manager 对识别出的桌面主进程请求非强制正常退出，解决窗口关闭后后台进程继续驻留的问题；静止判定只等待主程序与带 `--analytics-default-enabled` 的受管 app-server，忽略 renderer、crashpad 和独立 `app-server --listen stdio://`。正常退出被拒绝或超时会在备份和配置写入前明确失败，代码中不存在强制终止路径。随后重启 Codex 并验证配置、环境和历史别名。 |
| Latest evidence | `2026-08-24`: Windows Restart Manager 修复后自动回归 `131/131 PASS`；用户已使用 `22:59` 构建的最终 EXE/portable ZIP 完成真机 Provider 切换复验，正常关闭、真实切换、重启与读回均通过。PR #2 的 repository/Windows/macOS CI 在 `d0d495c` 全部通过。`v0.2.0-internal.1` 已发布为 GitHub prerelease，含 macOS DMG、Windows EXE/ZIP 和 SHA-256 清单；iOS 未改动。 |
| Current verdict | `LCP-08 PASS` 且内部候选发布完成：`v0.2.0-internal.1` 固定到 `d0d495c`。PR #2 保持开放且未合并；下一验收为 `LCP-09`。 |
| Last reconciled | `2026-08-24` |

## Phase Map

| Phase | Status | Goal and user result | Acceptance IDs | Entry | Exit | Next |
| --- | --- | --- | --- | --- | --- | --- |
| `P0` | complete | Establish the open-source monorepo, shared profile semantics, and isolated safety foundations. | Supporting foundation | Product contract available | Both platform implementations can be exercised in isolated homes | `P1` |
| `P1` | in progress | Users manage and switch arbitrary Providers end to end from native Windows and macOS desktop applications without editing config files. | `LCP-01`, `LCP-02` | P0 ready | Both platform lifecycle journeys pass with persistence | `P2` |
| `P2` | approved | Users get identical profile fields and preservation/recovery behavior on both platforms. | `LCP-03`, `LCP-04` | P1 behaviors exist | Shared fixtures and failure recovery prove parity and continuity | `P3` |
| `P3` | approved | Normal users can install, diagnose, switch, restore, uninstall, build, and audit exact Beta artifacts. | `LCP-05`, `LCP-06` | P2 exact candidate passes | All six core IDs pass against exact packaged artifacts | release close |
| `P4` | complete | macOS users manage and switch Provider v2 profiles under current Codex custom-Provider rules. | `LCP-07` | Internal candidate published and Provider v2 scope approved | macOS v1 migration, v2 lifecycle, isolated switch, strict config, and real-machine smoke pass | `P5` |
| `P5` | in progress | Windows adopts the proven macOS v2 semantics and both desktop apps exchange profiles safely. | `LCP-08`, `LCP-09` | P4 schema and real-machine lifecycle passed | Shared v1/v2 fixtures and exact desktop package journeys prove parity | release close |

## Mainline

Complete Windows parity under `LCP-08`, using the accepted macOS Provider v2
contract as the source of truth. Continue to cross-platform migration closure
under `LCP-09`. iOS remains frozen.

## Transition Rules

- A fixed Provider list is a prototype, not completion.
- Never use real `~/.codex`, real keys, or user sessions as automated fixtures.
- After the last ID, reconcile every core acceptance and release requirement
  against the exact packaged artifacts before declaring Beta readiness.
- Signing, notarization, public release, push, merge, and publication retain
  separate explicit authorization.
