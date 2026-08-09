# Codex Windows API 切换器

本工具使用中文图形界面，在同一个 `C:\Users\Lansi\.codex` 中切换 OpenAI Plus、Qilin 和 VectorEngine。它不会创建独立的 `CODEX_HOME`，因此会话历史、插件、skills、MCP、AGENTS 和项目配置继续共用。

## 文件说明

- `Start-CodexProviderSwitcher.cmd`：双击启动。
- `CodexProviderSwitcher.ps1`：Windows 图形界面。
- `switch_provider.py`：配置、备份、SQLite 同步和恢复核心。
- `Install-DesktopShortcut.ps1`：创建桌面快捷方式。
- `Test-Switcher.ps1`：运行隔离测试和静态检查。

## 首次使用

1. 保持整个文件夹结构不变。
2. 确认 Codex 当前没有生成回复、执行工具或写入文件。切换器检测到 Codex 正在运行时，会询问是否关闭并继续同一次切换。
3. 双击 `Start-CodexProviderSwitcher.cmd`。
4. 选择 Provider。
5. Qilin/VectorEngine 会显示环境变量及 key 掩码；未设置时填写 key，已设置时留空可继续使用。OpenAI Plus 直接复用现有登录状态，不显示 key 输入。
6. 可先点击“仅检查”。它不修改配置、环境变量或数据库。
7. 点击“切换 Provider”，确认 Provider、认证方式和 key 掩码。
8. 切换成功后选择是否重新打开 Codex Desktop。

## 环境变量

| Provider | Windows 用户环境变量 |
|---|---|
| OpenAI Plus | 无，使用 `.codex\auth.json` 中现有 `chatgpt` 登录状态 |
| Qilin | `QILIN_API_KEY` |
| VectorEngine | `VECTORENGINE_API_KEY` |

Qilin/VectorEngine key 存在当前 Windows 用户的环境变量中。界面只显示前后少数字符及掩码；脚本不会把完整 key 写入参数、日志或配置文件。Windows 用户环境变量本质上保存在当前用户注册表中，并非加密保险库，请保护 Windows 账户。OpenAI Plus 不使用 API key 环境变量。

## 历史、插件、skills 和 MCP

工具始终使用原来的 `.codex` 目录。切换时只调整：

- `model`
- `model_provider`
- `model_reasoning_effort`
- `review_model`
- `[history].persistence`
- Qilin 和 VectorEngine 的受管 provider 表
- `state_5.sqlite` 中现有线程的 `model_provider`

核心写入完成后会重新读取 `config.toml`，并检查全部线程的 `model_provider`；只有两项都匹配目标 Provider，界面才会显示“切换并校验成功”。

其他 provider、插件、MCP、市场、项目白名单和 Codex 状态均保留。切换前会备份配置和会话数据库。

## 备份与恢复

备份目录：

```text
C:\Users\Lansi\.codex\backups\windows-provider-switch
```

点击 `Restore latest` 可恢复最近一次切换前的 `config.toml` 和匹配的 `state_5.sqlite`。恢复不会修改 API key 环境变量。恢复前也会创建 `pre-restore-*` 备份。

## 创建桌面快捷方式

右键 PowerShell 打开以下脚本，或在本目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-DesktopShortcut.ps1
```

## 自检

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Switcher.ps1
```

自检仅使用临时测试目录，不会修改真实 `.codex`、key 或会话库。

## 注意事项

- 切换或恢复时，界面检测到 `ChatGPT`、`codex` 或 `codex-code-mode-host` 进程会先询问是否关闭；关闭完成后会继续同一次操作，不需要再次点击。
- 不要在模型回复、工具调用、patch 或测试执行中途切换 Provider。
- Provider 是否支持配置中的模型名称和 Responses API，取决于对应服务端能力。
- 如果服务端不支持 `gpt-5.6-sol` 或 `gpt-5.5`，需要由服务商确认实际模型映射后再调整脚本。
