# Lansi Codex Provider Manager Roadmap

Status: GOVERNED_BASELINE

This roadmap orders `PRODUCT_CONTRACT.md`; it grants no access to a real Codex
home and no merge, publication, signing, notarization, or release authority.

## Autopilot Status

| Field | Value |
| --- | --- |
| Execution | `CONTINUOUS` |
| Lifecycle | `RELEASE_CLOSE` |
| Current Phase | `P5` — Windows Provider v2 alignment |
| Current acceptance | `LCP-08` / `VERIFY` |
| Next Phase | `P5` |
| Next acceptance | `LCP-09` — close cross-platform Provider v2 migration and exchange |
| Exact candidate | `v0.2.0-internal.1` candidate on `agent/lcp-phase0-rescue-20260810`: accepted macOS LCP-07 implementation plus Windows Provider v2 package with Restart Manager normal-exit repair; iOS frozen. |
| Active delta | Publish the user-accepted Windows Provider v2 repair and matching macOS source as a clearly labelled internal candidate with exact checksums. `LCP-09` cross-platform package exchange remains the next unmet acceptance item. iOS is frozen and excluded. |
| Pause reason | None. |
| Windows implementation | Windows 原生编辑器现与 macOS 对齐：上游模型仅暂存并由用户加入受管列表。切换链路会预检目标 API、验证访问密钥并清除其他 Provider 的用户环境变量。运行时先向可见主窗口发送 `WM_CLOSE`，再通过 Windows Restart Manager 对识别出的桌面主进程请求非强制正常退出，解决窗口关闭后后台进程继续驻留的问题；静止判定只等待主程序与带 `--analytics-default-enabled` 的受管 app-server，忽略 renderer、crashpad 和独立 `app-server --listen stdio://`。正常退出被拒绝或超时会在备份和配置写入前明确失败，代码中不存在强制终止路径。随后重启 Codex 并验证配置、环境和历史别名。 |
| Latest evidence | `2026-08-24`: Windows Restart Manager 修复后自动回归 `131/131 PASS`；用户已使用 `22:59` 构建的最终 EXE/portable ZIP 完成真机 Provider 切换复验，正常关闭、真实切换、重启与读回均通过。发布资产 SHA-256 为 EXE `52baa3e8941ef4dcf50e9f0f053b03811a8202217978910fafa80872b1fbbb01`、ZIP `341d192e9e422b85bad67aaca5d4e3ee93369b018d880fc8b5e37c246f122997`。macOS 支持修复保留 `109/109 PASS`；iOS 未改动。 |
| Current verdict | `LCP-08 PASS`：Windows Provider v2 最终包已通过真机复验。本次获明确授权推送分支并发布内部候选 Release，不授权合并 PR；发布收口后导航到 `LCP-09`。 |
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
