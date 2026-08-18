# LCP-04 基线重建检查点（2026-08-17）

- 状态：基线已重建，macOS 90/90 测试通过（含污染会话规范化验收测试）。
- 00:46 时 tracked 文件的工作区状态未快照，回滚后与 00:46 前 untracked 文件契约断裂；
  用 17:35 备份恢复 17 个被回滚文件 + CodexConfigService 完整版，并重新接入
  SessionCompatService / SessionMetadataSyncService / ModelCatalogService 及对应测试。
- 修复面：切换时在 before snapshot 之前规范化 rollout 中明文 reasoning.content
  （content=[]、encrypted_content=null），使 qilin / vectorengine / DeepSeek 与
  OpenAI 官方登录互切不再报 array_above_max_length；wire_api 硬性 responses 由
  ProviderValidator + ProfileStore 迁移 + 默认配置强制。
- 下一步：macOS 真机切换 smoke（真实 Codex home，四个 provider 各切一次并回 OpenAI），
  然后 Windows 端同步（switch_provider.py 规范化 + desktop_app.py 字段 + 测试）。
- 边界：不 release / push / merge / 部署 / 暴露凭据；不触碰真实 ~/.codex 做自动化测试。
