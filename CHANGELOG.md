# Changelog

## Unreleased

## 0.1.0-beta.1

- Added verified backup, restore, lock ownership, process refusal, and preservation checks for the Windows switcher.
- Added content-level session and extension preservation checks for both platforms.
- Added CI gates for shared Profile schema, safety fixtures, and the macOS integration probe.
- Added the Windows non-secret Profile catalog data layer; GUI profile editing is not included in this beta.
- Windows 切换器新增经验证的备份、恢复、锁所有权、进程拒绝与保留校验。
- 两个平台新增会话与扩展文件内容级保留校验。
- CI 新增共享 Profile schema、安全夹具与 macOS 集成探针门禁。
- Windows 新增非秘密 Profile catalog 数据层；本 Beta 不包含 GUI Profile 编辑。

- Initial public monorepo foundation; provider behavior unchanged.
- 初始公开 monorepo 基础；Provider 切换行为未改变。
- Added a shared non-secret Provider Profile schema and synthetic cross-platform configuration fixtures.
- 新增非敏感 Provider Profile 统一 Schema 与跨平台合成配置夹具。
- macOS and Windows now verify the same compatibility-managed Provider output while preserving unrelated configuration.
- macOS 与 Windows 现验证同一份兼容性托管 Provider 输出，同时保留无关配置。
