# Changelog

## Unreleased

## 0.2.0-internal.1 - 2026-08-24

- Added Provider v2 lifecycle support on macOS and Windows with stable user-managed IDs, exclusive authentication modes, fixed and environment headers, command-token authentication, standalone web search, and Responses-only transport.
- Added user-governed model catalogs: upstream models remain staged until selected, bulk add/remove is supported, and switching no longer injects an entire upstream catalog.
- Preserved v1 profiles and historical Provider aliases while keeping profile import/export free of secrets.
- Changed desktop switching to request normal application exit before configuration writes; Windows uses non-forcing Restart Manager shutdown and macOS uses the native termination request.
- Added target API/key preflight, previous-key cleanup, managed-runtime quiescence checks, restart/readback verification, and fail-before-write behavior when Codex cannot exit normally.
- Provider v2 生命周期现已在 macOS 与 Windows 对齐，支持稳定用户 ID、互斥认证模式、固定/环境请求头、命令令牌认证、独立网页搜索和仅 `responses` 传输。
- 模型目录改为用户治理：上游模型先暂存，支持批量加入/移除，切换时不再强制注入全部上游模型。
- 保留 v1 Profile 与历史 Provider 别名，Profile 导入导出不包含密钥。
- 切换前必须请求桌面应用正常退出；Windows 使用非强制 Restart Manager，macOS 使用系统原生退出请求，无法退出时在写配置前失败。

## 0.1.0-internal.1 - 2026-08-18

- Initial public monorepo foundation; provider behavior unchanged.
- 初始公开 monorepo 基础；Provider 切换行为未改变。
- Added a shared non-secret Provider Profile schema and synthetic cross-platform configuration fixtures.
- 新增非敏感 Provider Profile 统一 Schema 与跨平台合成配置夹具。
- macOS and Windows now verify the same compatibility-managed Provider output while preserving unrelated configuration.
- macOS 与 Windows 现验证同一份兼容性托管 Provider 输出，同时保留无关配置。
