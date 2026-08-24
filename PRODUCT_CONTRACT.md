# Lansi Codex Provider Manager Product Contract

Status: USER_APPROVED_BASELINE

This contract defines product completion for the Windows and macOS Provider
Manager. The user's latest explicit instruction overrides it; engineering plans,
tests, governance, and release documents do not.

## Product Goal

Deliver open-source macOS and Windows native desktop applications that let a user
create and manage arbitrary Codex Provider profiles, safely switch the active
Provider in the user's existing Codex home, and continue existing conversations
without losing sessions, Skills, MCP configuration, plugins, or project state.

## Core Acceptance

| ID | User-visible capability | Acceptance evidence |
| --- | --- | --- |
| `LCP-01` | A Windows user can create, edit, duplicate, enable/disable, import, export, delete, select, and switch a custom Provider from the native desktop UI without editing TOML or JSON manually. | On Windows, complete the full desktop UI flow with a non-secret fixture profile; restart the app, prove persistence, switch successfully, and remove the profile. |
| `LCP-02` | A macOS user can perform the same custom Provider lifecycle and switch flow through the native app. | On macOS, complete the full UI flow with the same fixture semantics; restart, prove persistence, switch successfully, and remove the profile. |
| `LCP-03` | Both platforms expose and interpret the same Provider fields. | A shared fixture proves parity for stable UUID, name, enabled state, auth mode, base URL, wire API, secret reference, model, reasoning effort, review model, and approved overrides. |
| `LCP-04` | A successful or failed switch preserves the user's Codex working environment and offers verified recovery. | On isolated Codex homes, prove conversation/session continuity, thread routing, unrelated config preservation, Skill/plugin/MCP digest preservation, locking, backup, readback, rollback, and secret redaction on both platforms. |
| `LCP-05` | A normal user can install, launch the native desktop UI, diagnose, switch, restore, and uninstall the Beta on each supported platform. | Test packaged artifacts on real Windows and macOS hosts, including one custom Provider preflight/switch/restore flow and documented unsigned/signing limitations. |
| `LCP-06` | An open-source user can understand, build, and recover the application without private Lansi configuration. | Public repository documentation, license, build instructions, fixtures, release checksums, independent-project notice, and no-secret scan match the shipped artifacts. |
| `LCP-07` | A macOS user can manage and switch Provider v2 profiles under the Codex `26.818.41509` custom-Provider rules. | On macOS, complete create, edit, duplicate, import, export, persistence, migration, model management, and isolated switching for stable Provider IDs, reserved-ID rejection, three exclusive auth modes, Responses-only transport, fixed/environment headers, command-token auth, standalone web-search capability, and historical aliases. |
| `LCP-08` | A Windows user gets the same Provider v2 lifecycle and switching semantics after the macOS contract is proven. | Shared v1/v2 fixtures and Windows real-machine smoke prove field parity, migration, model governance, key cleanup, normal desktop exit without force-terminating the process tree, fail-before-write behavior when exit is refused or times out, process restart, readback, compatibility checks, and historical-session continuity. |
| `LCP-09` | macOS and Windows preserve v1 profiles and historical Provider aliases while exchanging Provider v2 profiles without secrets. | Cross-platform round trips preserve every approved field, reject unknown or secret-bearing input, keep old sessions resolvable, and pass exact packaged-artifact lifecycle smoke on both platforms. |

`LCP-01` through `LCP-09` are all core for the next approved increment. A fixed provider selector, a catalog
data layer without an end-to-end UI flow, passing tests, or
packaged ZIP files do not satisfy this contract by themselves.

## Release Definition

- `Prototype`: either platform may still use fixed Provider choices.
- `Internal candidate`: `LCP-01` through `LCP-04` have acceptance evidence.
- `v0.1 Beta`: all six core IDs pass against the exact packaged artifacts.
- `Stable`: Beta evidence remains valid across the supported Codex compatibility
  matrix and any required signing/notarization policy is satisfied.

The release definition may not be narrowed to fit the current implementation
without an explicit user-approved scope change.

## Product Order

1. Complete `LCP-01` as a vertical Windows user flow.
2. Complete `LCP-02` using the same profile semantics on macOS.
3. Close cross-platform parity and preservation gaps in `LCP-03` and `LCP-04`.
4. Package and prove the exact artifacts for `LCP-05` and `LCP-06`.
5. Complete macOS Provider v2 under `LCP-07`.
6. Align Windows and close cross-platform migration under `LCP-08` and `LCP-09`.

Supporting tests and safety work should be implemented inside the acceptance
slice they prove, not as independent product phases.

## Non-Goals For v0.1 Beta

- Cloud synchronization of profiles or secrets.
- Guaranteeing that incompatible third-party models support every Codex feature.
- A general-purpose editor for arbitrary Codex TOML.
- Payment, hosted accounts, telemetry collection, or automatic strategy changes.

## Change Control

Replies such as `确认`, `继续`, or `下一步` authorize work within this contract.
Only `批准范围变更：...` or an equivalently explicit instruction may add,
remove, or weaken an acceptance criterion.

Scope change recorded on 2026-08-16: the user explicitly replaced the Windows
local-browser surface with a Python native desktop surface. The replacement
must preserve the same Provider lifecycle and safety acceptance criteria.

Scope change recorded on 2026-08-17: the user explicitly restricted the bundled
default Provider catalog to the OpenAI default only. The applications must not
ship third-party Provider entries, API endpoints, or unredacted keys; third-party
Providers remain available only as user-created profiles.

Scope correction recorded on 2026-08-22: the user confirmed the earlier iOS
instruction was an input error. iOS development is fully frozen and excluded
from the active product candidate. Provider v2 delivery proceeds on macOS first,
then Windows, while any existing untracked iOS files remain untouched.
