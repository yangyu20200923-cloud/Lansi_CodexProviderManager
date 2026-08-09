# Repository Layout

| Path | Owner | Rule |
| --- | --- | --- |
| apps/macos/ | macOS maintainers | Native SwiftUI and Swift Package implementation |
| apps/windows/ | Windows maintainers | Native PowerShell UI and Python core implementation |
| spec/ | Cross-platform maintainers | Shared behavior contracts and non-secret fixtures |
| docs/ | All maintainers | Reviewed product and release documentation |
| .github/ | Release maintainers | CI and issue/PR intake only |

中文说明：`apps/macos/` 与 `apps/windows/` 分别维护原生平台实现；`spec/` 保存跨平台、非敏感的行为契约与 fixture；`docs/` 保存经审阅的产品和发布文档；`.github/` 仅保存 CI 与 Issue/PR 入口。
