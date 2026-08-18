# Lansi Codex Provider Manager for Windows

简体中文 | [English](#english)

这是 Windows 原生桌面 Provider 管理器。它采用 Python/Tk 原生窗口与 Windows 11 蓝白界面，让你创建、编辑、复制、启用、导入、导出、删除和切换自定义 Provider，无需手动编辑 TOML 或 JSON。它不启动浏览器、本地 HTTP 服务或监听端口。只有 OpenAI / ChatGPT 登录是内置选项；第三方 Provider 由你自行创建，软件不会附带私有 Provider 或 API key。

## 安装和启动

1. 解压 `Lansi_CodexProviderManager-windows-portable.zip`，不要只移动其中一个文件。
2. 双击 `Install-Lansi_CodexProviderManager.cmd`。它安装到当前用户的 `%LOCALAPPDATA%\Programs\Lansi_CodexProviderManager` 并创建桌面快捷方式。
3. 从桌面打开 **Lansi Codex Provider Manager**。也可直接双击 `Start-CodexProviderSwitcher.cmd` 以便携方式运行。

解压后的普通用户不需要安装 Python。双击 `Lansi_CodexProviderManager.exe` 或启动器会打开原生桌面窗口；它不会启动浏览器，也不会监听网络端口。

## 生成便携包

在 Windows 构建机上双击 `Build-PortablePackage.cmd`。它会临时创建 Python 构建环境、下载 PyInstaller 并生成 `Lansi_CodexProviderManager.exe`，随后打包为 `dist\Lansi_CodexProviderManager-windows-portable.zip`。构建机需要 Python 3.10 或更高版本和网络；临时构建环境会在完成后删除。ZIP 只包含 EXE、安装/卸载文件和图标，不包含 `.py` 源码、Codex home、会话、Skill、MCP、插件、备份或凭据。

## 使用

1. 点击“＋ 新增 Provider”，填写名称、Base URL、Wire API、环境变量名、API Key 和明确的模型；可在模型列表中手动填写多个模型，或从“从上游获取模型”读取供应商的 `/models` 列表。右键“＋ 新增 Provider”可导入文件或粘贴 Provider；右键列表中的 Provider 可编辑、复制、导出或粘贴。对于 DeepSeek 等非 GPT Provider，切换器不会再静默写入 GPT 模型。
2. 保存时，填写的 API Key 会写入你指定的当前 Windows 用户环境变量；留空则保留该环境变量现有值。Provider、导出文件、UI 状态和诊断日志不会保存或显示完整 key。Windows 用户环境变量不是加密保险库，请保护 Windows 账户。
3. 点击详情卡右上角的“仅检查”确认该 Provider 的配置可切换；点击底部右侧的“应用并重启 ChatGPT”才会实际写入。切换改变的是新任务的默认路由；关闭并重新打开 Codex 后，请新建任务验证模型与 API。已有任务会继续使用创建时的 Provider。
4. 如需撤销最近一次受控切换，点击底部按钮栏的“恢复最近备份”。恢复前会先创建当前状态的回退备份。

主窗口布局与 macOS 版本对齐：左侧 Provider 列表、中间详情与系统状态、底部右对齐的操作按钮栏（编辑 Provider、刷新状态、恢复最近备份、停用/启用、删除、应用并重启 ChatGPT）。

切换前会确认 Codex 已关闭：程序优先使用 Windows 原生进程快照，并在该接口不可用时自动改用 `tasklist`。只有两种本机检查都无法执行时才会拒绝切换，且不会写入配置或备份；这时请关闭 Codex 后，以当前登录的 Windows 用户重新启动本程序再试。

切换只更新受管 Provider 配置和本地模型目录；会话数据库仅用于备份与完整性校验，既有任务的 `model_provider` 不会被重写。它会校验现有会话、线程路由、Skills、MCP、插件、AGENTS 和不相关的 Codex 配置保持不变；失败时只回退切换器实际写入的配置和本地模型目录。`plugins/cache` 是 Codex 自行更新的运行时缓存，切换器不会复制、移动或恢复它。

## 诊断与卸载

启动失败时，请提供 `%TEMP%\Lansi_CodexProviderManager-startup.log`。该日志记录启动阶段和错误摘要，自动隐藏 `api_key`、token、secret 和 password 值。

双击已安装目录或便携目录中的 `Uninstall-Lansi_CodexProviderManager.cmd` 进行卸载。它只删除 `%LOCALAPPDATA%\Programs\Lansi_CodexProviderManager` 和本应用桌面快捷方式；不会删除 Codex home、Profile、会话、Skill、MCP、插件、备份或凭据。

## 发布限制

当前候选 Windows 包是未签名的 EXE 便携包，不是 Microsoft Store 或已签名 MSI。Windows 可能显示来自未知发布者的提示；请只使用发布项目提供的校验包，并在提示不符合预期时停止运行。需要组织级代码签名或集中部署时，应由发布方提供签名后的安装包。

## English

This native Windows desktop Provider manager uses a Python/Tk desktop window with a Windows 11-inspired blue and white surface. It does not start a browser, local HTTP server, or listening port. It lets you create, edit, duplicate, enable, import, export, delete, select, and switch custom Providers without hand-editing TOML or JSON.

Extract the portable ZIP, then double-click `Install-Lansi_CodexProviderManager.cmd`. It installs only for the current user under `%LOCALAPPDATA%\Programs\Lansi_CodexProviderManager` and creates a desktop shortcut. End users do not need Python: double-clicking either `Lansi_CodexProviderManager.exe` or `Start-CodexProviderSwitcher.cmd` opens the native desktop UI. The extracted package also runs without installation.

To create the portable ZIP on a Windows build machine, double-click `Build-PortablePackage.cmd`. It needs Python 3.10+ and network access only for the build, creates a temporary PyInstaller environment, builds `Lansi_CodexProviderManager.exe`, then replaces the archive at `dist\Lansi_CodexProviderManager-windows-portable.zip`. The temporary build environment is removed after packaging; end users do not need Python.

Use **Add Provider**, fill in the Provider fields, run **Check**, then use **Apply & Restart ChatGPT**. Right-click **Add Provider** to import or paste a Provider, and right-click a listed Provider to edit, copy, export, or paste. A switch changes the default route for new tasks only: restart Codex and create a new task to verify the model and API; existing tasks retain the Provider used when they were created. Use **Restore Latest Backup** to recover the latest verified switch backup. The window layout mirrors the macOS build: Provider sidebar, detail and system-status cards, and a right-aligned bottom action bar. The startup diagnostic log is `%TEMP%\Lansi_CodexProviderManager-startup.log`; it redacts secret values. To remove the app, double-click `Uninstall-Lansi_CodexProviderManager.cmd`. It removes only the app and its desktop shortcut, never Codex homes, profiles, sessions, Skills, MCP, plugins, backups, or credentials.

The current candidate is an unsigned portable EXE package, not a Microsoft Store or signed MSI installer. Windows can show an unknown-publisher warning. Only run artifacts obtained from the project release and stop when a warning does not match the expected publisher or source. Organization-managed signing and deployment require a separately signed installer.
