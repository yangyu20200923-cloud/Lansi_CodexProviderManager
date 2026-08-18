[CmdletBinding()]
param(
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [switch]$DisableWindows11Effects,
    [string]$DebugLogPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'Lansi_CodexProviderManager-startup.log')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DebugLogPath = $DebugLogPath
$script:DebugLogPreinitialized = $env:LANSI_SWITCHER_DEBUG_LOG_INITIALIZED -eq '1' -and (Test-Path -LiteralPath $script:DebugLogPath)
$script:ProviderDrawFallbackLogged = $false
$script:RoundedControlRadii = @{}
$script:FluentButtonKinds = @{}

function ConvertTo-SafeDebugText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $safeText = $Text
    $safeText = $safeText -replace '(?i)(api[_ -]?key|token|secret|password)\s*[:=]\s*[^\s,;]+', '$1=<redacted>'
    $safeText = $safeText -replace '(?i)\b(sk|rk|sess)_[A-Za-z0-9_-]+', '<redacted>'
    return $safeText
}

function Write-StartupDebugLog {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [AllowEmptyString()][string]$Detail = '',
        [AllowNull()][System.Management.Automation.ErrorRecord]$ErrorRecord = $null
    )

    try {
        $message = ConvertTo-SafeDebugText -Text $Detail
        if ($null -ne $ErrorRecord) {
            $exceptionType = $ErrorRecord.Exception.GetType().FullName
            $exceptionMessage = ConvertTo-SafeDebugText -Text $ErrorRecord.Exception.Message
            $message = "type=$exceptionType; message=$exceptionMessage"
        }
        $timestamp = [DateTime]::UtcNow.ToString('o')
        Add-Content -LiteralPath $script:DebugLogPath -Value "[$timestamp] [$Stage] $message" -Encoding UTF8
    }
    catch { }
}

try {
    if (-not $script:DebugLogPreinitialized) {
        Set-Content -LiteralPath $script:DebugLogPath -Value '# Lansi Codex Provider Manager startup debug log' -Encoding UTF8
    }
    Write-StartupDebugLog -Stage 'startup.begin' -Detail "PowerShell=$($PSVersionTable.PSVersion); OS=$([Environment]::OSVersion.Version)"
}
catch { }

trap {
    Write-StartupDebugLog -Stage 'startup.unhandled' -ErrorRecord $_
    break
}

try {
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if ($null -eq ('EnvironmentBroadcast' -as [type])) {
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class EnvironmentBroadcast {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    private static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);

    public static void Notify() {
        UIntPtr result;
        SendMessageTimeout((IntPtr)0xffff, 0x001A, UIntPtr.Zero,
            "Environment", 0x0002, 5000, out result);
    }

    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(
        IntPtr hWnd, int dwAttribute, ref int pvAttribute, int cbAttribute);

    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    public static extern int SetWindowTheme(IntPtr hWnd, string appName, string idList);
}
'@
}
Write-StartupDebugLog -Stage 'startup.interop_ready'
}
catch {
    Write-StartupDebugLog -Stage 'startup.interop_failed' -ErrorRecord $_
    throw
}

$script:Providers = [ordered]@{
    'OpenAI Plus'  = [pscustomobject]@{ Id = 'openai'; EnvKey = $null }
}
$script:CorePath = Join-Path $PSScriptRoot 'switch_provider.py'
$script:ConfigPath = Join-Path $CodexHome 'config.toml'
$script:StatePath = Join-Path $CodexHome 'state_5.sqlite'
$script:CatalogPath = Join-Path $env:APPDATA 'Lansi_CodexProviderManager\profiles.json'
$script:ApplicationIconPath = Join-Path $PSScriptRoot 'LansiObserve.ico'
$script:ActiveProviderId = $null
$script:DraftProfileId = $null
$script:DraftProfile = $null
$script:ProfileEditorLoading = $false
$script:ProfileEditorDirty = $false
$script:Windows11EffectsEnabled = -not $DisableWindows11Effects
Write-StartupDebugLog -Stage 'startup.options' -Detail "windows11Effects=$script:Windows11EffectsEnabled"

function New-RoundedRectanglePath {
    param([Parameter(Mandatory)][System.Drawing.Rectangle]$Bounds, [Parameter(Mandatory)][int]$Radius)

    $diameter = [Math]::Max(2, [Math]::Min($Radius * 2, [Math]::Min($Bounds.Width, $Bounds.Height)))
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($Bounds.Left, $Bounds.Top, $diameter, $diameter, 180, 90)
    $path.AddArc($Bounds.Right - $diameter, $Bounds.Top, $diameter, $diameter, 270, 90)
    $path.AddArc($Bounds.Right - $diameter, $Bounds.Bottom - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($Bounds.Left, $Bounds.Bottom - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function Apply-RoundedRegion {
    param([Parameter(Mandatory)][System.Windows.Forms.Control]$Control, [int]$Radius = 8)

    if (-not $script:Windows11EffectsEnabled) { return }

    if ($Control.Width -lt 4 -or $Control.Height -lt 4) { return }
    $bounds = [System.Drawing.Rectangle]::new(0, 0, [int]$Control.Width, [int]$Control.Height)
    $path = New-RoundedRectanglePath -Bounds $bounds -Radius $Radius
    try { $Control.Region = [System.Drawing.Region]::new($path) }
    finally { $path.Dispose() }
}

function Set-RoundedRegion {
    param([Parameter(Mandatory)][System.Windows.Forms.Control]$Control, [int]$Radius = 8)

    if (-not $script:Windows11EffectsEnabled) { return }

    $script:RoundedControlRadii[$Control] = $Radius
    try {
        Apply-RoundedRegion -Control $Control -Radius $Radius
        $Control.Add_SizeChanged({
            param($sender, $eventArgs)
            try {
                if ($null -eq $sender -or $sender.Width -lt 4 -or $sender.Height -lt 4) { return }
                $controlRadius = $script:RoundedControlRadii[$sender]
                if ($null -eq $controlRadius) { return }
                $bounds = [System.Drawing.Rectangle]::new(0, 0, [int]$sender.Width, [int]$sender.Height)
                $path = New-RoundedRectanglePath -Bounds $bounds -Radius ([int]$controlRadius)
                try { $sender.Region = [System.Drawing.Region]::new($path) }
                finally { $path.Dispose() }
            }
            catch { Write-StartupDebugLog -Stage 'style.rounded_region' -ErrorRecord $_ }
        })
    }
    catch { Write-StartupDebugLog -Stage 'style.rounded_region_hook' -ErrorRecord $_ }
}

function Update-FluentButtonColors {
    param([Parameter(Mandatory)][System.Windows.Forms.Button]$Button)

    try {
        $kind = $script:FluentButtonKinds[$Button]
        if (-not $Button.Enabled) {
            $Button.BackColor = [System.Drawing.Color]::FromArgb(242, 242, 242)
            $Button.ForeColor = [System.Drawing.Color]::FromArgb(137, 137, 137)
            $Button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(226, 226, 226)
            $Button.FlatAppearance.MouseOverBackColor = $Button.BackColor
            $Button.FlatAppearance.MouseDownBackColor = $Button.BackColor
            $Button.Invalidate()
            return
        }

        switch ($kind) {
            'Primary' {
                $Button.BackColor = [System.Drawing.Color]::FromArgb(15, 108, 189)
                $Button.ForeColor = [System.Drawing.Color]::White
                $Button.FlatAppearance.BorderColor = $Button.BackColor
                $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(0, 95, 184)
                $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(0, 82, 158)
            }
            'Danger' {
                $Button.BackColor = [System.Drawing.Color]::FromArgb(253, 243, 242)
                $Button.ForeColor = [System.Drawing.Color]::FromArgb(181, 46, 46)
                $Button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(237, 204, 201)
                $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(250, 231, 229)
                $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(247, 218, 214)
            }
            default {
                $Button.BackColor = [System.Drawing.Color]::FromArgb(251, 251, 251)
                $Button.ForeColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
                $Button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(209, 209, 209)
                $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
                $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(235, 235, 235)
            }
        }
        $Button.Invalidate()
    }
    catch { Write-StartupDebugLog -Stage 'style.button_colors' -ErrorRecord $_ }
}

function Draw-FluentButtonSurface {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Button]$Button,
        [Parameter(Mandatory)][System.Drawing.Graphics]$Graphics
    )

    if ($Button.Width -lt 4 -or $Button.Height -lt 4) { return }
    $Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $bounds = [System.Drawing.Rectangle]::new(0, 0, $Button.Width - 1, $Button.Height - 1)
    $textBounds = [System.Drawing.Rectangle]::new(8, 0, [Math]::Max(0, $Button.Width - 16), $Button.Height)
    $path = New-RoundedRectanglePath -Bounds $bounds -Radius 6
    $background = [System.Drawing.SolidBrush]::new($Button.BackColor)
    $border = [System.Drawing.Pen]::new($Button.FlatAppearance.BorderColor, 1)
    try {
        $Graphics.FillPath($background, $path)
        $Graphics.DrawPath($border, $path)
        $textFlags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor [System.Windows.Forms.TextFormatFlags]::SingleLine
        [System.Windows.Forms.TextRenderer]::DrawText($Graphics, $Button.Text, $Button.Font, $textBounds, $Button.ForeColor, $textFlags)
        if ($Button.Focused -and $Button.ShowFocusCues) {
            [System.Windows.Forms.ControlPaint]::DrawFocusRectangle($Graphics, $textBounds, $Button.ForeColor, $Button.BackColor)
        }
    }
    finally { $border.Dispose(); $background.Dispose(); $path.Dispose() }
}

function Set-FluentButtonStyle {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Button]$Button,
        [ValidateSet('Default', 'Primary', 'Danger')][string]$Kind = 'Default'
    )

    try {
        $Button.FlatStyle = 'Flat'
        # The native rectangular border is clipped by rounded regions at high DPI. Paint one continuous path instead.
        $Button.FlatAppearance.BorderSize = 0
        $Button.UseVisualStyleBackColor = $false
        $Button.Font = New-Object System.Drawing.Font('Segoe UI Variable Text Semibold', 10.5)
        $Button.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $script:FluentButtonKinds[$Button] = $Kind
        Update-FluentButtonColors -Button $Button
        $Button.Add_EnabledChanged({
            param($sender, $eventArgs)
            Update-FluentButtonColors -Button $sender
        })
        $Button.Add_MouseEnter({
            param($sender, $eventArgs)
            if ($sender.Enabled) { $sender.BackColor = $sender.FlatAppearance.MouseOverBackColor; $sender.Invalidate() }
        })
        $Button.Add_MouseLeave({
            param($sender, $eventArgs)
            Update-FluentButtonColors -Button $sender
        })
        $Button.Add_MouseDown({
            param($sender, $eventArgs)
            if ($sender.Enabled -and $eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $sender.BackColor = $sender.FlatAppearance.MouseDownBackColor; $sender.Invalidate() }
        })
        $Button.Add_MouseUp({
            param($sender, $eventArgs)
            if ($sender.Enabled -and $eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $sender.BackColor = $sender.FlatAppearance.MouseOverBackColor; $sender.Invalidate() }
        })
        $Button.Add_Paint({
            param($sender, $eventArgs)
            Draw-FluentButtonSurface -Button $sender -Graphics $eventArgs.Graphics
        })
        Set-RoundedRegion -Control $Button -Radius 6
    }
    catch { Write-StartupDebugLog -Stage 'style.button' -ErrorRecord $_ }
}

function Enable-Windows11Chrome {
    param([Parameter(Mandatory)][System.Windows.Forms.Form]$Window, [Parameter(Mandatory)][System.Windows.Forms.Control[]]$ThemedControls)

    if (-not $script:Windows11EffectsEnabled) { return }

    try {
        $roundPreference = 2 # DWMWCP_ROUND on Windows 11; older Windows ignores the unsupported attribute.
        [void][EnvironmentBroadcast]::DwmSetWindowAttribute($Window.Handle, 33, [ref]$roundPreference, 4)
    }
    catch { Write-StartupDebugLog -Stage 'style.window_corner' -ErrorRecord $_ }
    foreach ($control in $ThemedControls) {
        try { [void][EnvironmentBroadcast]::SetWindowTheme($control.Handle, 'Explorer', $null) }
        catch { Write-StartupDebugLog -Stage 'style.control_theme' -Detail $control.GetType().FullName }
    }
}

function Set-ApplicationIcon {
    param([Parameter(Mandatory)][System.Windows.Forms.Form]$Window)

    if (-not (Test-Path -LiteralPath $script:ApplicationIconPath)) {
        Write-StartupDebugLog -Stage 'startup.icon_missing' -Detail 'LansiObserve.ico was not found next to the application.'
        return
    }
    try {
        $Window.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($script:ApplicationIconPath)
        Write-StartupDebugLog -Stage 'startup.icon_ready'
    }
    catch { Write-StartupDebugLog -Stage 'startup.icon_failed' -ErrorRecord $_ }
}

function Get-ProviderChoices {
    $choices = [System.Collections.Generic.List[object]]::new()
    [void]$choices.Add([pscustomobject]@{ Name = 'OpenAI Plus'; Id = 'openai'; EnvKey = $null; ProfileId = $null; Enabled = $true; AuthMode = 'chatgpt_login' })
    if (Test-Path $script:CatalogPath) {
        $catalog = Get-Content -Raw -Encoding UTF8 $script:CatalogPath | ConvertFrom-Json
        foreach ($profile in @($catalog.profiles)) {
            if ($null -eq $profile) { continue }
            $environmentKey = if ($profile.authMode -eq 'api_key') { $profile.apiKeyEnv } else { $null }
            [void]$choices.Add([pscustomobject]@{
                Name = $profile.name; Id = 'custom'; EnvKey = $environmentKey
                ProfileId = $profile.id; Enabled = $profile.enabled; AuthMode = $profile.authMode
            })
        }
    }
    return $choices.ToArray()
}

function Add-ProviderChoicesToList {
    param([Parameter(Mandatory)][System.Windows.Forms.ListBox]$ListBox)

    foreach ($choice in @(Get-ProviderChoices)) {
        if ($null -ne $choice) { [void]$ListBox.Items.Add($choice) }
    }
}

function Get-ProviderDetail {
    param([Parameter(Mandatory)][object]$Provider)

    if ($null -ne $Provider.ProfileId -and (Test-Path $script:CatalogPath)) {
        $catalog = Get-Content -Raw -Encoding UTF8 $script:CatalogPath | ConvertFrom-Json
        $profile = $catalog.profiles | Where-Object { $_.id -eq $Provider.ProfileId } | Select-Object -First 1
        if ($null -ne $profile) {
            $baseUrl = if ([string]::IsNullOrWhiteSpace($profile.baseUrl)) { '由登录方式管理' } else { $profile.baseUrl }
            $wireApi = if ([string]::IsNullOrWhiteSpace($profile.wireApi)) { '默认' } else { $profile.wireApi }
            $model = if ([string]::IsNullOrWhiteSpace($profile.model)) { '默认' } else { $profile.model }
            $reasoningEffort = if ([string]::IsNullOrWhiteSpace($profile.reasoningEffort)) { '默认' } else { $profile.reasoningEffort }
            $reviewModel = if ([string]::IsNullOrWhiteSpace($profile.reviewModel)) { '默认' } else { $profile.reviewModel }
            return [pscustomobject]@{
                BaseUrl = $baseUrl
                WireApi = $wireApi
                Model = $model
                ReasoningEffort = $reasoningEffort
                ReviewModel = $reviewModel
            }
        }
    }

    return [pscustomobject]@{
        BaseUrl = '由内置 Provider 策略管理'
        WireApi = '由内置 Provider 策略管理'
        Model = '由 Codex 管理'
        ReasoningEffort = '默认'
        ReviewModel = '默认'
    }
}

function Get-ActivityDiagnosticsText {
    param([AllowNull()][object]$Diagnostics)

    if ($null -eq $Diagnostics) {
        return [pscustomobject]@{ History = '诊断信息不可用。'; Extensions = '诊断信息不可用。' }
    }
    $sessionCount = [int]$Diagnostics.session_file_count
    $history = if ($null -ne $Diagnostics.thread_count) {
        "$($Diagnostics.thread_count) 个会话；$sessionCount 个会话文件"
    }
    else {
        $reason = switch ([string]$Diagnostics.history_error) {
            'state_db_missing' { '未找到 state_5.sqlite' }
            'state_db_unreadable' { '会话数据库无法读取' }
            'threads_unavailable' { 'threads 表不可用或不兼容' }
            default { '会话数不可读取' }
        }
        "会话数不可读（$reason）；$sessionCount 个会话文件"
    }
    return [pscustomobject]@{
        History = $history
        Extensions = "Skill $($Diagnostics.skill_count)；插件 $($Diagnostics.plugin_count)；MCP 服务器 $($Diagnostics.mcp_server_count)；MCP 文件 $($Diagnostics.mcp_file_count)"
    }
}

function Find-Python {
    foreach ($name in @('python.exe', 'python')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }
    throw '未找到 Python 3。请安装 Python 3，或将 python.exe 添加到 PATH。'
}

$script:Python = Find-Python

function Invoke-Core {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $baseArguments = @(
        $script:CorePath,
        '--config', $script:ConfigPath,
        '--state-db', $script:StatePath
    )
    $output = & $script:Python @baseArguments @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        try {
            $failure = $text | ConvertFrom-Json
            throw $failure.error
        }
        catch [System.ArgumentException] {
            throw $text
        }
    }
    return $text | ConvertFrom-Json
}

function Get-KeyInfo {
    param([Parameter(Mandatory)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name, 'User')
    $source = '用户环境变量'
    if ([string]::IsNullOrEmpty($value)) {
        $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
        $source = '进程环境变量'
    }
    if ([string]::IsNullOrEmpty($value)) {
        return [pscustomobject]@{ Value = $null; Source = '未配置'; Mask = '未配置' }
    }
    return [pscustomobject]@{ Value = $value; Source = $source; Mask = (Protect-Key $value) }
}

function Protect-Key {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return '未配置' }
    if ($Value.Length -le 6) { return ('*' * $Value.Length) }
    $prefixLength = [Math]::Min(4, $Value.Length - 4)
    $suffixLength = [Math]::Min(4, $Value.Length - $prefixLength)
    return $Value.Substring(0, $prefixLength) + '********' + $Value.Substring($Value.Length - $suffixLength)
}

function Get-CodexProcesses {
    $names = @('ChatGPT', 'codex', 'codex-code-mode-host')
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.ProcessName })
}

function Request-CodexShutdown {
    $processes = @(Get-CodexProcesses)
    if ($processes.Count -eq 0) { return $true }

    $summary = ($processes | Sort-Object ProcessName, Id | ForEach-Object { "$($_.ProcessName) ($($_.Id))" }) -join '、'
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "检测到 Codex 正在运行，本次切换尚未执行。`r`n`r`n进程：$summary`r`n`r`n请确认当前回复、工具调用和文件写入均已结束。是否关闭 Codex 并继续本次操作？",
        '需要关闭 Codex',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }

    foreach ($process in ($processes | Where-Object { $_.ProcessName -eq 'ChatGPT' })) {
        try { [void]$process.CloseMainWindow() } catch { }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 250
        $remaining = @(Get-CodexProcesses)
    } while ($remaining.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)

    if ($remaining.Count -gt 0) {
        $force = [System.Windows.Forms.MessageBox]::Show(
            "Codex 未在 10 秒内完全退出。`r`n`r`n是否强制结束剩余进程并继续？未保存的进行中任务可能丢失。",
            'Codex 尚未退出',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($force -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }
        $remaining | Stop-Process -Force -ErrorAction Stop
        Start-Sleep -Milliseconds 750
        $remaining = @(Get-CodexProcesses)
    }
    if ($remaining.Count -gt 0) {
        throw '无法关闭全部 Codex 进程，切换未执行。'
    }
    return $true
}

function Start-CodexDesktop {
    try {
        Start-Process -FilePath 'explorer.exe' -ArgumentList 'shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App'
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Provider 已切换，但无法自动启动 Codex。`r`n$($_.Exception.Message)",
            '启动失败',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

function Invoke-ProfileCatalog {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & $script:Python (Join-Path $PSScriptRoot 'profile_catalog.py') --catalog $script:CatalogPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($text)) { $text = 'Provider catalog 命令执行失败。' }
        throw $text
    }
    return $text
}

function Get-UpstreamModels {
    param([Parameter(Mandatory)][object]$Profile)

    if ($Profile.AuthMode -ne 'api_key') { throw '只有 API Key Provider 可以从上游获取模型。' }
    if ([string]::IsNullOrWhiteSpace($Profile.BaseUrl) -or [string]::IsNullOrWhiteSpace($Profile.ApiKeyEnv)) {
        throw '请先填写 Base URL 和 API Key 环境变量名。'
    }
    $key = Get-KeyInfo -Name $Profile.ApiKeyEnv
    if ([string]::IsNullOrWhiteSpace($key.Value)) { throw "$($Profile.ApiKeyEnv) 尚未配置，请先输入 key。" }
    $previous = [Environment]::GetEnvironmentVariable($Profile.ApiKeyEnv, 'Process')
    try {
        [Environment]::SetEnvironmentVariable($Profile.ApiKeyEnv, $key.Value, 'Process')
        $result = Invoke-ProfileCatalog -Arguments @('--fetch-models', '--base-url', $Profile.BaseUrl, '--api-key-env', $Profile.ApiKeyEnv)
        $payload = $result | ConvertFrom-Json
        $models = @($payload.models | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($models.Count -eq 0) { throw '供应商没有返回可用模型。' }
        return $models
    }
    finally {
        [Environment]::SetEnvironmentVariable($Profile.ApiKeyEnv, $previous, 'Process')
    }
}

function Show-ProviderDialog {
    param(
        [Parameter(Mandatory)][string]$Title,
        [AllowNull()][object]$Profile = $null
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.StartPosition = 'CenterParent'
    $dialog.ClientSize = New-Object System.Drawing.Size(500, 460)
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false

    function Add-DialogLabel([string]$Text, [int]$Y) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Text; $label.Location = New-Object System.Drawing.Point(18, $Y); $label.Size = New-Object System.Drawing.Size(125, 24)
        $dialog.Controls.Add($label)
    }
    function Add-DialogTextBox([string]$Value, [int]$Y) {
        $input = New-Object System.Windows.Forms.TextBox
        $input.Text = $Value; $input.Location = New-Object System.Drawing.Point(150, $Y); $input.Size = New-Object System.Drawing.Size(325, 26)
        $dialog.Controls.Add($input)
        return $input
    }

    Add-DialogLabel '名称' 18
    $nameInput = Add-DialogTextBox $(if ($null -eq $Profile) { '' } else { $Profile.name }) 15
    Add-DialogLabel '认证方式' 56
    $authMode = New-Object System.Windows.Forms.ComboBox
    $authMode.DropDownStyle = 'DropDownList'; [void]$authMode.Items.AddRange([string[]]@('api_key', 'chatgpt_login'))
    $authMode.SelectedItem = if ($null -eq $Profile) { 'api_key' } else { $Profile.authMode }
    $authMode.Location = New-Object System.Drawing.Point(150, 53); $authMode.Size = New-Object System.Drawing.Size(325, 26); $dialog.Controls.Add($authMode)
    Add-DialogLabel '启用状态' 94
    $enabled = New-Object System.Windows.Forms.CheckBox
    $enabled.Text = '启用此 Provider'; $enabled.Checked = if ($null -eq $Profile) { $true } else { [bool]$Profile.enabled }
    $enabled.Location = New-Object System.Drawing.Point(150, 91); $enabled.Size = New-Object System.Drawing.Size(325, 26); $dialog.Controls.Add($enabled)
    Add-DialogLabel 'Base URL' 132
    $baseUrlInput = Add-DialogTextBox $(if ($null -eq $Profile) { '' } else { $Profile.baseUrl }) 129
    Add-DialogLabel 'Wire API' 170
    $wireApiInput = Add-DialogTextBox 'responses' 167
    $wireApiInput.ReadOnly = $true
    Add-DialogLabel '环境变量名' 208
    $apiKeyEnvInput = Add-DialogTextBox $(if ($null -eq $Profile) { '' } else { $Profile.apiKeyEnv }) 205
    Add-DialogLabel '模型' 246
    $modelInput = Add-DialogTextBox $(if ($null -eq $Profile) { '' } else { $Profile.model }) 243
    Add-DialogLabel '推理强度' 284
    $reasoningInput = Add-DialogTextBox $(if ($null -eq $Profile) { '' } else { $Profile.reasoningEffort }) 281
    Add-DialogLabel '审阅模型' 322
    $reviewInput = Add-DialogTextBox $(if ($null -eq $Profile) { '' } else { $Profile.reviewModel }) 319
    Add-DialogLabel '已批准覆盖项' 360
    $overrides = New-Object System.Windows.Forms.Label
    $overrides.Text = '当前版本没有已批准的覆盖项'; $overrides.Location = New-Object System.Drawing.Point(150, 360); $overrides.Size = New-Object System.Drawing.Size(325, 24)
    $dialog.Controls.Add($overrides)
    $syncAuthMode = {
        $usesKey = $authMode.SelectedItem -eq 'api_key'
        $baseUrlInput.Enabled = $usesKey; $wireApiInput.Enabled = $usesKey; $apiKeyEnvInput.Enabled = $usesKey
    }
    $authMode.Add_SelectedIndexChanged($syncAuthMode); & $syncAuthMode

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'
    $cancel.Location = New-Object System.Drawing.Point(290, 410)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancel)
    $dialog.CancelButton = $cancel

    $save = New-Object System.Windows.Forms.Button
    $save.Text = '保存'
    $save.Location = New-Object System.Drawing.Point(385, 410)
    $save.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($save)
    $dialog.AcceptButton = $save

    if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return [pscustomobject]@{
        Name = $nameInput.Text
        Enabled = $enabled.Checked
        AuthMode = [string]$authMode.SelectedItem
        BaseUrl = $baseUrlInput.Text
        WireApi = $wireApiInput.Text
        ApiKeyEnv = $apiKeyEnvInput.Text
        Model = $modelInput.Text
        ReasoningEffort = $reasoningInput.Text
        ReviewModel = $reviewInput.Text
        ConfigOverrides = '{}'
    }
}

function Get-ProfileCatalogUpsertArguments {
    param([Parameter(Mandatory)][string]$ProfileId, [Parameter(Mandatory)][object]$Profile)

    $arguments = @('--id', $ProfileId, '--name', $Profile.Name, '--enabled', $Profile.Enabled.ToString().ToLowerInvariant(), '--auth-mode', $Profile.AuthMode, '--config-overrides-json', $Profile.ConfigOverrides)
    foreach ($field in @(
        @{ Flag = '--base-url'; Value = $Profile.BaseUrl }, @{ Flag = '--wire-api'; Value = $Profile.WireApi },
        @{ Flag = '--api-key-env'; Value = $Profile.ApiKeyEnv }, @{ Flag = '--model'; Value = $Profile.Model },
        @{ Flag = '--reasoning-effort'; Value = $Profile.ReasoningEffort }, @{ Flag = '--review-model'; Value = $Profile.ReviewModel }
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$field.Value)) { $arguments += @($field.Flag, [string]$field.Value) }
    }
    $modelList = @($Profile.Models | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $arguments += @('--models-json', (ConvertTo-Json $modelList -Compress))
    return $arguments
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Lansi Codex Provider Manager'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(1120, 740)
$form.MinimumSize = New-Object System.Drawing.Size(980, 680)
$form.MaximizeBox = $true
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.Font = New-Object System.Drawing.Font('Segoe UI Variable Text', 10.5)
$form.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
Set-ApplicationIcon -Window $form

# Use the native Windows 11 settings layout: navigation, a settings surface, and a command bar.
$workspace = New-Object System.Windows.Forms.SplitContainer
$workspace.Dock = 'Fill'
$workspace.FixedPanel = 'Panel1'
$workspace.IsSplitterFixed = $false
$workspace.SplitterWidth = 1
$workspace.Panel1MinSize = 230
$workspace.SplitterDistance = 240
$workspace.BackColor = [System.Drawing.Color]::FromArgb(227, 227, 227)
$form.Controls.Add($workspace)

$sidebarLayout = New-Object System.Windows.Forms.TableLayoutPanel
$sidebarLayout.Dock = 'Fill'
$sidebarLayout.ColumnCount = 1
$sidebarLayout.RowCount = 5
$sidebarLayout.BackColor = [System.Drawing.Color]::FromArgb(247, 247, 247)
[void]$sidebarLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, [single]96))
[void]$sidebarLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, [single]38))
[void]$sidebarLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, [single]100))
[void]$sidebarLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, [single]64))
[void]$sidebarLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, [single]78))
$workspace.Panel1.Controls.Add($sidebarLayout)

$sidebarHeader = New-Object System.Windows.Forms.Panel
$sidebarHeader.Dock = 'Fill'
$sidebarTitle = New-Object System.Windows.Forms.Label
$sidebarTitle.Text = 'Provider 管理'
$sidebarTitle.Font = New-Object System.Drawing.Font('Segoe UI Variable Display Semibold', 15)
$sidebarTitle.AutoSize = $true
$sidebarTitle.Location = New-Object System.Drawing.Point(20, 18)
$sidebarHeader.Controls.Add($sidebarTitle)
$shared = New-Object System.Windows.Forms.Label
$shared.Text = '共享 Codex 目录'
$shared.AutoEllipsis = $true
$shared.ForeColor = [System.Drawing.Color]::FromArgb(83, 83, 83)
$shared.Location = New-Object System.Drawing.Point(21, 54)
$shared.Size = New-Object System.Drawing.Size(250, 28)
$sidebarHeader.Controls.Add($shared)
$sidebarLayout.Controls.Add($sidebarHeader, 0, 0)

$providerSectionLabel = New-Object System.Windows.Forms.Label
$providerSectionLabel.Text = 'Provider 列表'
$providerSectionLabel.Dock = 'Fill'
$providerSectionLabel.Padding = New-Object System.Windows.Forms.Padding(20, 10, 0, 0)
$providerSectionLabel.ForeColor = [System.Drawing.Color]::FromArgb(83, 83, 83)
$providerSectionLabel.Font = New-Object System.Drawing.Font('Segoe UI Variable Text Semibold', 10.5)
$sidebarLayout.Controls.Add($providerSectionLabel, 0, 1)

$providerBox = New-Object System.Windows.Forms.ListBox
$providerBox.Dock = 'Fill'
$providerBox.Margin = New-Object System.Windows.Forms.Padding(8, 0, 8, 0)
$providerBox.BorderStyle = 'None'
$providerBox.BackColor = [System.Drawing.Color]::FromArgb(247, 247, 247)
$providerBox.DrawMode = if ($script:Windows11EffectsEnabled) { [System.Windows.Forms.DrawMode]::OwnerDrawFixed } else { [System.Windows.Forms.DrawMode]::Normal }
$providerBox.IntegralHeight = $false
$providerBox.ItemHeight = 48
$providerBox.Font = New-Object System.Drawing.Font('Segoe UI Variable Text', 10.5)
$providerBox.DisplayMember = 'Name'
$providerBox.ValueMember = 'Id'
Add-ProviderChoicesToList -ListBox $providerBox
$providerBox.SelectedIndex = 0
$sidebarLayout.Controls.Add($providerBox, 0, 2)

if ($script:Windows11EffectsEnabled) {
$providerBox.Add_DrawItem({
    param($sender, $eventArgs)
    try {
        if ($eventArgs.Index -lt 0) { return }

        $item = $sender.Items[$eventArgs.Index]
        $selected = (([int]$eventArgs.State -band [int][System.Windows.Forms.DrawItemState]::Selected) -ne 0)
        $drawBounds = [System.Drawing.Rectangle]$eventArgs.Bounds
        $bounds = [System.Drawing.Rectangle]::new(
            ([int]$drawBounds.X + 2),
            ([int]$drawBounds.Y + 2),
            [Math]::Max(1, ([int]$drawBounds.Width - 4)),
            [Math]::Max(1, ([int]$drawBounds.Height - 4))
        )
        $backgroundBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]$sender.BackColor)
        $eventArgs.Graphics.FillRectangle($backgroundBrush, $drawBounds)
        $backgroundBrush.Dispose()
        if ($selected) {
            $selectionPath = New-RoundedRectanglePath -Bounds $bounds -Radius 7
            $selectionBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(218, 232, 252))
            $eventArgs.Graphics.FillPath($selectionBrush, $selectionPath)
            $selectionBrush.Dispose()
            $selectionPath.Dispose()
        }
        $textColor = if ($selected) { [System.Drawing.Color]::FromArgb(0, 82, 154) } else { [System.Drawing.Color]::FromArgb(32, 32, 32) }
        $textBrush = [System.Drawing.SolidBrush]::new($textColor)
        $eventArgs.Graphics.DrawString([string]$item.Name, $sender.Font, $textBrush, [single]($bounds.X + 12), [single]($bounds.Y + 12))
        $textBrush.Dispose()
        $isActive = $script:ActiveProviderId -eq $item.Id -or ($item.ProfileId -and $script:ActiveProviderId -eq $item.ProfileId)
        $stateText = if (-not $item.Enabled) { '已停用' } elseif ($isActive) { '当前' } else { '' }
        if ($stateText) {
            $stateColor = if ($item.Enabled) { [System.Drawing.Color]::FromArgb(0, 103, 192) } else { [System.Drawing.Color]::FromArgb(119, 119, 119) }
            $stateSize = [System.Drawing.SizeF]$eventArgs.Graphics.MeasureString($stateText, $sender.Font)
            $stateBrush = [System.Drawing.SolidBrush]::new($stateColor)
            $stateX = [single]($bounds.Right - [int][Math]::Ceiling($stateSize.Width) - 10)
            $eventArgs.Graphics.DrawString($stateText, $sender.Font, $stateBrush, $stateX, [single]($bounds.Y + 12))
            $stateBrush.Dispose()
        }
        $eventArgs.DrawFocusRectangle()
    }
    catch {
        if (-not $script:ProviderDrawFallbackLogged) {
            $script:ProviderDrawFallbackLogged = $true
            Write-StartupDebugLog -Stage 'style.provider_list_fallback' -ErrorRecord $_
        }
        $eventArgs.DrawBackground()
        if ($eventArgs.Index -ge 0) {
            $eventArgs.Graphics.DrawString([string]$sender.Items[$eventArgs.Index].Name, $sender.Font, [System.Drawing.SystemBrushes]::ControlText, $eventArgs.Bounds)
        }
    }
})
}

$addProviderButton = New-Object System.Windows.Forms.Button
$addProviderButton.Text = '新建 Provider'
$addProviderButton.Dock = 'Fill'
$addProviderButton.Margin = New-Object System.Windows.Forms.Padding(20, 6, 20, 8)
$sidebarLayout.Controls.Add($addProviderButton, 0, 3)

$statusBar = New-Object System.Windows.Forms.Label
$statusBar.Text = '就绪'
$statusBar.Dock = 'Fill'
$statusBar.Padding = New-Object System.Windows.Forms.Padding(20, 8, 20, 8)
$statusBar.AutoEllipsis = $true
$statusBar.ForeColor = [System.Drawing.Color]::FromArgb(83, 83, 83)
$statusBar.Font = New-Object System.Drawing.Font('Segoe UI Variable Text', 9.5)
$sidebarLayout.Controls.Add($statusBar, 0, 4)

$contentLayout = New-Object System.Windows.Forms.TableLayoutPanel
$contentLayout.Dock = 'Fill'
$contentLayout.ColumnCount = 1
$contentLayout.RowCount = 3
$contentLayout.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
[void]$contentLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, [single]112))
[void]$contentLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, [single]100))
[void]$contentLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, [single]84))
$workspace.Panel2.Controls.Add($contentLayout)

$contentHeader = New-Object System.Windows.Forms.Panel
$contentHeader.Dock = 'Fill'
$contentHeader.Padding = New-Object System.Windows.Forms.Padding(32, 16, 32, 12)
$headerLayout = New-Object System.Windows.Forms.TableLayoutPanel
$headerLayout.Dock = 'Fill'
$headerLayout.ColumnCount = 2
$headerLayout.RowCount = 2
[void]$headerLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, [single]100))
[void]$headerLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::AutoSize))
[void]$headerLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, [single]42))
[void]$headerLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, [single]100))
$contentHeader.Controls.Add($headerLayout)
$providerTitle = New-Object System.Windows.Forms.Label
$providerTitle.Text = 'OpenAI Plus'
$providerTitle.Font = New-Object System.Drawing.Font('Segoe UI Variable Display Semibold', 21)
$providerTitle.AutoSize = $false
$providerTitle.AutoEllipsis = $true
$providerTitle.Dock = 'Fill'
$providerTitle.Margin = New-Object System.Windows.Forms.Padding(0)
$providerTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$headerLayout.Controls.Add($providerTitle, 0, 0)
$providerSubtitle = New-Object System.Windows.Forms.Label
$providerSubtitle.Text = '选择 Provider 后可检查连接并安全切换。'
$providerSubtitle.ForeColor = [System.Drawing.Color]::FromArgb(83, 83, 83)
$providerSubtitle.AutoSize = $false
$providerSubtitle.AutoEllipsis = $true
$providerSubtitle.Dock = 'Fill'
$providerSubtitle.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
$providerSubtitle.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
$headerLayout.Controls.Add($providerSubtitle, 0, 1)
$providerState = New-Object System.Windows.Forms.Label
$providerState.Text = '可用'
$providerState.AutoSize = $true
$providerState.Anchor = 'Top, Right'
$providerState.Margin = New-Object System.Windows.Forms.Padding(24, 5, 0, 0)
$providerState.Padding = New-Object System.Windows.Forms.Padding(14, 6, 14, 6)
$providerState.BackColor = [System.Drawing.Color]::FromArgb(225, 245, 231)
$providerState.ForeColor = [System.Drawing.Color]::FromArgb(16, 124, 16)
$providerState.Font = New-Object System.Drawing.Font('Segoe UI Variable Text Semibold', 10)
$headerLayout.Controls.Add($providerState, 1, 0)
$headerLayout.SetRowSpan($providerState, 2)
$contentLayout.Controls.Add($contentHeader, 0, 0)

$detailsHost = New-Object System.Windows.Forms.Panel
$detailsHost.Dock = 'Fill'
$detailsHost.AutoScroll = $true
$detailsHost.Padding = New-Object System.Windows.Forms.Padding(32, 0, 32, 16)
$detailsHost.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$contentLayout.Controls.Add($detailsHost, 0, 1)

$detailsLayout = New-Object System.Windows.Forms.TableLayoutPanel
$detailsLayout.Dock = 'Top'
$detailsLayout.AutoSize = $true
$detailsLayout.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$detailsLayout.ColumnCount = 1
$detailsLayout.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$detailsHost.Controls.Add($detailsLayout)

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 10000
$toolTip.InitialDelay = 500

function New-FormSection {
    param([Parameter(Mandatory)][string]$Title)

    $section = New-Object System.Windows.Forms.TableLayoutPanel
    $section.AutoSize = $true
    $section.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $section.ColumnCount = 2
    $section.Dock = 'Top'
    $section.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 24)
    [void]$section.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, [single]168))
    [void]$section.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, [single]100))

    $caption = New-Object System.Windows.Forms.Label
    $caption.Text = $Title
    $caption.AutoSize = $true
    $caption.Font = New-Object System.Drawing.Font('Segoe UI Variable Display Semibold', 12.5)
    $caption.ForeColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
    $caption.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $section.Controls.Add($caption, 0, 0)
    $section.SetColumnSpan($caption, 2)

    $detailsLayout.Controls.Add($section, 0, $detailsLayout.RowCount)
    $detailsLayout.RowCount++
    return [pscustomobject]@{ Host = $section; NextRow = 1 }
}

function Add-FormRow {
    param(
        [Parameter(Mandatory)][object]$Section,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][System.Windows.Forms.Control]$Value,
        [string]$ToolTipText = ''
    )

    $row = [int]$Section.NextRow
    $fieldLabel = New-Object System.Windows.Forms.Label
    $fieldLabel.Text = $Label
    $fieldLabel.AutoSize = $true
    $fieldLabel.Anchor = 'Left'
    $fieldLabel.MinimumSize = New-Object System.Drawing.Size(0, 36)
    $fieldLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $fieldLabel.Margin = New-Object System.Windows.Forms.Padding(0, 5, 22, 5)
    $fieldLabel.ForeColor = [System.Drawing.Color]::FromArgb(63, 63, 63)
    $fieldLabel.Font = New-Object System.Drawing.Font('Segoe UI Variable Text Semibold', 10.5)
    $Section.Host.Controls.Add($fieldLabel, 0, $row)

    $Value.Dock = 'Fill'
    $Value.Margin = New-Object System.Windows.Forms.Padding(0, 5, 0, 5)
    $Section.Host.Controls.Add($Value, 1, $row)
    if (-not [string]::IsNullOrWhiteSpace($ToolTipText)) {
        $toolTip.SetToolTip($Value, $ToolTipText)
        $toolTip.SetToolTip($fieldLabel, $ToolTipText)
    }
    $Section.NextRow = $row + 1
    return [pscustomobject]@{ Label = $fieldLabel; Value = $Value }
}

function New-EditorTextBox {
    param([switch]$Secret)

    $input = New-Object System.Windows.Forms.TextBox
    $input.Font = New-Object System.Drawing.Font('Segoe UI Variable Text', 10.5)
    $input.Height = 36
    $input.BackColor = [System.Drawing.Color]::White
    $input.BorderStyle = 'None'
    $input.UseSystemPasswordChar = $Secret
    $input.Dock = 'Fill'

    # WinForms TextBox cannot draw a Windows 11 border reliably. Keep the editable control native,
    # but put it in a rounded host that owns the focus and disabled-state treatment.
    $editorHost = New-Object System.Windows.Forms.Panel
    $editorHost.Height = 36
    $editorHost.MinimumSize = New-Object System.Drawing.Size(0, 36)
    $editorHost.BackColor = [System.Drawing.Color]::White
    $editorHost.Padding = New-Object System.Windows.Forms.Padding(10, 7, 10, 7)
    $editorHost.Tag = $input
    $input.Tag = $editorHost
    [void]$editorHost.Controls.Add($input)
    $editorHost.Add_Click({
        param($sender, $eventArgs)
        if ($sender.Tag -is [System.Windows.Forms.Control]) { $sender.Tag.Focus() }
    })
    $editorHost.Add_Paint({
        param($sender, $eventArgs)
        if ($sender.Width -lt 4 -or $sender.Height -lt 4) { return }
        $inputControl = $sender.Tag
        $borderColor = if (-not $inputControl.Enabled) {
            [System.Drawing.Color]::FromArgb(226, 226, 226)
        }
        elseif ($inputControl.Focused) {
            [System.Drawing.Color]::FromArgb(0, 103, 192)
        }
        else {
            [System.Drawing.Color]::FromArgb(138, 138, 138)
        }
        $eventArgs.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $bounds = [System.Drawing.Rectangle]::new(0, 0, $sender.Width - 1, $sender.Height - 1)
        $path = New-RoundedRectanglePath -Bounds $bounds -Radius 6
        $pen = [System.Drawing.Pen]::new($borderColor, 1)
        try { $eventArgs.Graphics.DrawPath($pen, $path) }
        finally { $pen.Dispose(); $path.Dispose() }
    })
    $input.Add_GotFocus({
        param($sender, $eventArgs)
        $editorHost = $sender.Tag
        if ($editorHost -is [System.Windows.Forms.Control]) { $editorHost.Invalidate() }
    })
    $input.Add_LostFocus({
        param($sender, $eventArgs)
        $editorHost = $sender.Tag
        if ($editorHost -is [System.Windows.Forms.Control]) { $editorHost.Invalidate() }
    })
    $input.Add_EnabledChanged({
        param($sender, $eventArgs)
        $editorHost = $sender.Tag
        if ($editorHost -is [System.Windows.Forms.Control]) {
            $editorHost.BackColor = if ($sender.Enabled) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::FromArgb(245, 245, 245) }
            $editorHost.Invalidate()
        }
    })
    Set-RoundedRegion -Control $editorHost -Radius 6
    return $input
}

function Get-EditorHost {
    param([Parameter(Mandatory)][System.Windows.Forms.Control]$EditorInput)

    if ($EditorInput.Tag -is [System.Windows.Forms.Control]) { return $EditorInput.Tag }
    return $EditorInput
}

function New-EditorComboBox {
    param([ValidateSet('DropDown', 'DropDownList')][string]$DropDownStyle)

    $input = New-Object System.Windows.Forms.ComboBox
    $input.DropDownStyle = $DropDownStyle
    $input.Font = New-Object System.Drawing.Font('Segoe UI Variable Text', 10.5)
    $input.FlatStyle = 'Flat'
    $input.Height = 36
    $input.BackColor = [System.Drawing.Color]::White
    $input.ForeColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
    $input.Dock = 'Fill'

    $editorHost = New-Object System.Windows.Forms.Panel
    $editorHost.Height = 36
    $editorHost.MinimumSize = New-Object System.Drawing.Size(0, 36)
    $editorHost.BackColor = [System.Drawing.Color]::White
    $editorHost.Padding = New-Object System.Windows.Forms.Padding(1)
    $editorHost.Tag = $input
    $input.Tag = $editorHost
    [void]$editorHost.Controls.Add($input)
    $editorHost.Add_Paint({
        param($sender, $eventArgs)
        if ($sender.Width -lt 4 -or $sender.Height -lt 4) { return }
        $inputControl = $sender.Tag
        $borderColor = if (-not $inputControl.Enabled) {
            [System.Drawing.Color]::FromArgb(226, 226, 226)
        }
        elseif ($inputControl.Focused) {
            [System.Drawing.Color]::FromArgb(0, 103, 192)
        }
        else {
            [System.Drawing.Color]::FromArgb(138, 138, 138)
        }
        $eventArgs.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $bounds = [System.Drawing.Rectangle]::new(0, 0, $sender.Width - 1, $sender.Height - 1)
        $path = New-RoundedRectanglePath -Bounds $bounds -Radius 6
        $pen = [System.Drawing.Pen]::new($borderColor, 1)
        try { $eventArgs.Graphics.DrawPath($pen, $path) }
        finally { $pen.Dispose(); $path.Dispose() }
    })
    $input.Add_GotFocus({
        param($sender, $eventArgs)
        $editorHost = $sender.Tag
        if ($editorHost -is [System.Windows.Forms.Control]) { $editorHost.Invalidate() }
    })
    $input.Add_LostFocus({
        param($sender, $eventArgs)
        $editorHost = $sender.Tag
        if ($editorHost -is [System.Windows.Forms.Control]) { $editorHost.Invalidate() }
    })
    $input.Add_EnabledChanged({
        param($sender, $eventArgs)
        $editorHost = $sender.Tag
        if ($editorHost -is [System.Windows.Forms.Control]) {
            $editorHost.BackColor = if ($sender.Enabled) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::FromArgb(245, 245, 245) }
            $editorHost.Invalidate()
        }
    })
    Set-RoundedRegion -Control $editorHost -Radius 6
    return $input
}

$builtinSummarySection = New-FormSection '登录状态'
$builtinLoginStatus = New-Object System.Windows.Forms.Label
$builtinLoginStatus.AutoSize = $true
$builtinLoginStatus.Text = '使用现有 ChatGPT / Codex Plus 登录状态。'
Add-FormRow -Section $builtinSummarySection -Label '认证方式' -Value $builtinLoginStatus
$builtinManagedStatus = New-Object System.Windows.Forms.Label
$builtinManagedStatus.AutoSize = $true
$builtinManagedStatus.Text = '模型和服务连接由 Codex 管理，无需填写 API Key 或 Base URL。'
Add-FormRow -Section $builtinSummarySection -Label '配置方式' -Value $builtinManagedStatus

$profileSection = New-FormSection '基本设置'
$displayNameInput = New-EditorTextBox
Add-FormRow -Section $profileSection -Label '显示名称' -Value (Get-EditorHost -EditorInput $displayNameInput) -ToolTipText 'Provider 列表中显示的名称。'
$enabledInput = New-Object System.Windows.Forms.CheckBox
$enabledInput.Text = '启用此 Provider'
$enabledInput.AutoSize = $true
Add-FormRow -Section $profileSection -Label '启用状态' -Value $enabledInput -ToolTipText '停用的 Provider 不可切换。'
$authModeInput = New-EditorComboBox -DropDownStyle DropDownList
[void]$authModeInput.Items.AddRange([string[]]@('API Key', 'ChatGPT / Codex Plus 登录'))
Add-FormRow -Section $profileSection -Label '认证方式' -Value (Get-EditorHost -EditorInput $authModeInput) -ToolTipText 'API Key Provider 使用环境变量；登录方式不保存 API Key。'

$connectionSection = New-FormSection '连接设置'
$baseUrlInput = New-EditorTextBox
Add-FormRow -Section $connectionSection -Label 'Base URL' -Value (Get-EditorHost -EditorInput $baseUrlInput) -ToolTipText 'API Key Provider 必须使用 HTTPS 地址。'
$wireApiInput = New-EditorComboBox -DropDownStyle DropDownList
[void]$wireApiInput.Items.Add('responses')
Add-FormRow -Section $connectionSection -Label 'Wire API' -Value (Get-EditorHost -EditorInput $wireApiInput) -ToolTipText '当前 Codex 版本仅支持 Responses API。'
$apiKeyEnvInput = New-EditorTextBox
$apiKeyEnvInput.Font = New-Object System.Drawing.Font('Consolas', 10.5)
Add-FormRow -Section $connectionSection -Label 'API Key 环境变量' -Value (Get-EditorHost -EditorInput $apiKeyEnvInput) -ToolTipText '只记录环境变量名，不保存密钥。'

$modelSection = New-FormSection '模型设置'
$modelInput = New-EditorTextBox
Add-FormRow -Section $modelSection -Label '模型' -Value (Get-EditorHost -EditorInput $modelInput) -ToolTipText 'API Key Provider 必须填写明确的模型；不会再静默回退到 GPT 模型。'
$modelsInput = New-EditorTextBox
Add-FormRow -Section $modelSection -Label '模型列表' -Value (Get-EditorHost -EditorInput $modelsInput) -ToolTipText '用逗号分隔，可手动填写；也可在“更多”菜单中从上游 /models 获取。'
$reasoningEffortInput = New-EditorTextBox
Add-FormRow -Section $modelSection -Label '推理强度' -Value (Get-EditorHost -EditorInput $reasoningEffortInput) -ToolTipText '可选，例如 low、medium 或 high。'
$reviewModelInput = New-EditorTextBox
Add-FormRow -Section $modelSection -Label '审阅模型' -Value (Get-EditorHost -EditorInput $reviewModelInput) -ToolTipText '可选的审阅模型。'

$credentialSection = New-FormSection '凭据状态'
$newKey = New-EditorTextBox -Secret
Add-FormRow -Section $credentialSection -Label 'API Key（可选）' -Value (Get-EditorHost -EditorInput $newKey) -ToolTipText '留空时保留现有环境变量值；保存 Provider 不会写入密钥。'
$keyStatus = New-Object System.Windows.Forms.Label
$keyStatus.AutoSize = $true
Add-FormRow -Section $credentialSection -Label '当前状态' -Value $keyStatus
$configOverrides = New-Object System.Windows.Forms.Label
$configOverrides.Text = '当前版本没有已批准的覆盖项'
$configOverrides.AutoSize = $true
Add-FormRow -Section $credentialSection -Label '已批准覆盖项' -Value $configOverrides

$diagnosticsSection = New-FormSection '运行状态'
$historySummary = New-Object System.Windows.Forms.Label
$historySummary.AutoSize = $true
$historySummary.MaximumSize = New-Object System.Drawing.Size(720, 0)
Add-FormRow -Section $diagnosticsSection -Label '会话与会话文件' -Value $historySummary
$extensionSummary = New-Object System.Windows.Forms.Label
$extensionSummary.AutoSize = $true
$extensionSummary.MaximumSize = New-Object System.Drawing.Size(720, 0)
Add-FormRow -Section $diagnosticsSection -Label 'Skill / 插件 / MCP' -Value $extensionSummary
$warning = New-Object System.Windows.Forms.Label
$warning.AutoSize = $true
$warning.MaximumSize = New-Object System.Drawing.Size(720, 0)
$warning.ForeColor = [System.Drawing.Color]::FromArgb(166, 82, 20)
$warning.Text = ''
Add-FormRow -Section $diagnosticsSection -Label '安全提示' -Value $warning
Set-RoundedRegion -Control $providerState -Radius 10

$actionBar = New-Object System.Windows.Forms.TableLayoutPanel
$actionBar.Dock = 'Fill'
$actionBar.ColumnCount = 2
$actionBar.RowCount = 1
$actionBar.Margin = New-Object System.Windows.Forms.Padding(32, 0, 32, 0)
$actionBar.Padding = New-Object System.Windows.Forms.Padding(0, 12, 0, 12)
$actionBar.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
[void]$actionBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, [single]100))
[void]$actionBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, [single]400))
$contentLayout.Controls.Add($actionBar, 0, 2)

$profileActions = New-Object System.Windows.Forms.FlowLayoutPanel
$profileActions.Dock = 'Fill'
$profileActions.WrapContents = $false
$profileActions.AutoScroll = $false
$profileActions.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)
$profileActions.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$actionBar.Controls.Add($profileActions, 0, 0)

$editProviderButton = New-Object System.Windows.Forms.Button
$editProviderButton.Text = '保存 Provider'; $editProviderButton.Size = New-Object System.Drawing.Size(116, 40); $editProviderButton.Enabled = $false
$profileActions.Controls.Add($editProviderButton)
$profileMenuButton = New-Object System.Windows.Forms.Button
$profileMenuButton.Text = 'Provider 操作'; $profileMenuButton.Size = New-Object System.Drawing.Size(118, 40); $profileMenuButton.Enabled = $false
$profileActions.Controls.Add($profileMenuButton)
$profileMenu = New-Object System.Windows.Forms.ContextMenuStrip
$profileMenu.Font = New-Object System.Drawing.Font('Segoe UI Variable Text', 10.5)
$editProviderMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('编辑 Provider')
$copyProviderMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('复制 Provider')
$toggleProviderMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('停用 Provider')
$exportProviderMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('导出 Provider')
$deleteProviderMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('删除 Provider')
$deleteProviderMenuItem.ForeColor = [System.Drawing.Color]::FromArgb(181, 46, 46)
[void]$profileMenu.Items.AddRange([System.Windows.Forms.ToolStripItem[]]@(
    $editProviderMenuItem,
    $copyProviderMenuItem,
    $toggleProviderMenuItem,
    $exportProviderMenuItem,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $deleteProviderMenuItem
))
$profileMenuButton.Add_Click({ $profileMenu.Show($profileMenuButton, 0, $profileMenuButton.Height) })
$providerBox.ContextMenuStrip = $profileMenu

$utilityActions = New-Object System.Windows.Forms.FlowLayoutPanel
$utilityActions.Dock = 'Fill'
$utilityActions.WrapContents = $false
$utilityActions.AutoScroll = $false
$utilityActions.FlowDirection = 'LeftToRight'
$utilityActions.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)
$utilityActions.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$actionBar.Controls.Add($utilityActions, 1, 0)
$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = '刷新'; $refreshButton.Size = New-Object System.Drawing.Size(68, 40)
$utilityActions.Controls.Add($refreshButton)
$utilityMenuButton = New-Object System.Windows.Forms.Button
$utilityMenuButton.Text = '更多'; $utilityMenuButton.Size = New-Object System.Drawing.Size(68, 40)
$utilityActions.Controls.Add($utilityMenuButton)
$utilityMenu = New-Object System.Windows.Forms.ContextMenuStrip
$utilityMenu.Font = New-Object System.Drawing.Font('Segoe UI Variable Text', 10.5)
$restoreButton = New-Object System.Windows.Forms.ToolStripMenuItem('恢复最近备份')
$importProviderButton = New-Object System.Windows.Forms.ToolStripMenuItem('导入 Provider')
$fetchModelsMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('从上游获取模型')
[void]$utilityMenu.Items.AddRange([System.Windows.Forms.ToolStripItem[]]@($restoreButton, $importProviderButton, $fetchModelsMenuItem))
$utilityMenuButton.Add_Click({ $utilityMenu.Show($utilityMenuButton, 0, $utilityMenuButton.Height) })
$checkButton = New-Object System.Windows.Forms.Button
$checkButton.Text = '检查'; $checkButton.Size = New-Object System.Drawing.Size(76, 40)
# Keep connection preflight close to the switch command without making it a competing primary action.
$utilityActions.Controls.Add($checkButton)
$switchButton = New-Object System.Windows.Forms.Button
$switchButton.Text = '切换 Provider'
$switchButton.Size = New-Object System.Drawing.Size(132, 42)
$switchButton.Margin = New-Object System.Windows.Forms.Padding(4, 0, 0, 0)
$utilityActions.Controls.Add($switchButton)

Set-FluentButtonStyle -Button $addProviderButton
foreach ($button in @($refreshButton, $checkButton, $utilityMenuButton, $editProviderButton, $profileMenuButton)) {
    Set-FluentButtonStyle -Button $button
}
Set-FluentButtonStyle -Button $switchButton -Kind Primary
Write-StartupDebugLog -Stage 'startup.ui_constructed'

function Get-StoredProfile {
    param([AllowNull()][string]$ProfileId)

    if ([string]::IsNullOrWhiteSpace($ProfileId) -or -not (Test-Path -LiteralPath $script:CatalogPath)) { return $null }
    $catalog = Get-Content -Raw -Encoding UTF8 $script:CatalogPath | ConvertFrom-Json
    return $catalog.profiles | Where-Object { $_.id -eq $ProfileId } | Select-Object -First 1
}

function Get-ProfileTextValue {
    param([AllowNull()][object]$Profile, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Profile) { return '' }
    $property = $Profile.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    return [string]$property.Value
}

function Set-ProfileEditorAvailability {
    param([bool]$CanEdit)

    $usesApiKey = $CanEdit -and $authModeInput.SelectedIndex -eq 0
    foreach ($input in @($displayNameInput, $enabledInput, $authModeInput, $modelInput, $modelsInput, $reasoningEffortInput, $reviewModelInput)) {
        $input.Enabled = $CanEdit
    }
    foreach ($input in @($baseUrlInput, $wireApiInput, $apiKeyEnvInput, $newKey)) {
        $input.Enabled = $usesApiKey
    }
    $builtinSummarySection.Host.Visible = -not $CanEdit
    $profileSection.Host.Visible = $CanEdit
    $connectionSection.Host.Visible = $usesApiKey
    $modelSection.Host.Visible = $CanEdit
    $credentialSection.Host.Visible = $usesApiKey
    $detailsLayout.PerformLayout()
}

function Get-ProfileFromEditor {
    $authMode = if ($authModeInput.SelectedIndex -eq 1) { 'chatgpt_login' } else { 'api_key' }
    return [pscustomobject]@{
        Name = $displayNameInput.Text.Trim()
        Enabled = $enabledInput.Checked
        AuthMode = $authMode
        BaseUrl = $baseUrlInput.Text.Trim()
        WireApi = $wireApiInput.Text.Trim()
        ApiKeyEnv = $apiKeyEnvInput.Text.Trim()
        Model = $modelInput.Text.Trim()
        Models = @($modelsInput.Text -split '[,;\r\n]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        ReasoningEffort = $reasoningEffortInput.Text.Trim()
        ReviewModel = $reviewModelInput.Text.Trim()
        ConfigOverrides = '{}'
    }
}

function Set-ProfileEditorDirty {
    if ($script:ProfileEditorLoading -or $null -eq $providerBox.SelectedItem -or $null -eq $providerBox.SelectedItem.ProfileId) { return }
    $script:ProfileEditorDirty = $true
    $checkButton.Enabled = $false
    $switchButton.Enabled = $false
    $statusBar.Text = 'Provider 配置已修改，请先保存后再检查或切换。'
}

function Update-ProfileActionMenu {
    $selected = $providerBox.SelectedItem
    $isStoredProfile = $null -ne $selected -and -not [string]::IsNullOrWhiteSpace($selected.ProfileId) -and $selected.ProfileId -ne $script:DraftProfileId
    $isActiveProfile = $isStoredProfile -and $script:ActiveProviderId -eq $selected.Id
    $editProviderMenuItem.Enabled = $isStoredProfile
    $copyProviderMenuItem.Enabled = $isStoredProfile
    $toggleProviderMenuItem.Enabled = $isStoredProfile -and -not ($selected.Enabled -and $isActiveProfile)
    $exportProviderMenuItem.Enabled = $isStoredProfile
    $deleteProviderMenuItem.Enabled = $isStoredProfile -and -not $isActiveProfile
    if ($null -ne $selected) {
        $toggleProviderMenuItem.Text = if ($selected.Enabled) { '停用 Provider' } else { '启用 Provider' }
    }
}

function Open-SelectedProviderEditor {
    $selected = $providerBox.SelectedItem
    if ($null -eq $selected -or [string]::IsNullOrWhiteSpace($selected.ProfileId) -or $selected.ProfileId -eq $script:DraftProfileId) {
        [System.Windows.Forms.MessageBox]::Show('请选择已保存的自定义 Provider 后再编辑。', '无法编辑', 'OK', 'Information') | Out-Null
        return
    }
    $detailsHost.ScrollControlIntoView($profileSection.Host)
    $displayNameInput.Focus()
    $statusBar.Text = "正在编辑 $($selected.Name)。修改后请点击保存 Provider。"
}

function Update-View {
    try {
        $selected = $providerBox.SelectedItem
        if ($null -eq $selected) { return }

    # Render selection and draft state first. Diagnostics are informative only and must never block editing.
        $isDraft = $selected.ProfileId -and $selected.ProfileId -eq $script:DraftProfileId
        $storedProfile = if ($isDraft) { $script:DraftProfile } elseif ($selected.ProfileId) { Get-StoredProfile -ProfileId $selected.ProfileId } else { $null }
        $canEdit = $isDraft -or $null -ne $storedProfile
        $script:ProfileEditorLoading = $true
        try {
            if ($canEdit) {
                $displayNameInput.Text = Get-ProfileTextValue -Profile $storedProfile -Name 'name'
                $enabledInput.Checked = (Get-ProfileTextValue -Profile $storedProfile -Name 'enabled') -eq 'True'
                $authModeInput.SelectedIndex = if ((Get-ProfileTextValue -Profile $storedProfile -Name 'authMode') -eq 'chatgpt_login') { 1 } else { 0 }
                $baseUrlInput.Text = Get-ProfileTextValue -Profile $storedProfile -Name 'baseUrl'
                $wireApiInput.Text = 'responses'
                $apiKeyEnvInput.Text = Get-ProfileTextValue -Profile $storedProfile -Name 'apiKeyEnv'
                $modelInput.Text = Get-ProfileTextValue -Profile $storedProfile -Name 'model'
                $modelsInput.Text = if ($null -eq $storedProfile.models) { '' } else { @($storedProfile.models) -join ', ' }
                $reasoningEffortInput.Text = Get-ProfileTextValue -Profile $storedProfile -Name 'reasoningEffort'
                $reviewModelInput.Text = Get-ProfileTextValue -Profile $storedProfile -Name 'reviewModel'
            }
            else {
                $displayNameInput.Text = $selected.Name
                $enabledInput.Checked = $true
                $authModeInput.SelectedIndex = 1
                $baseUrlInput.Clear()
                $wireApiInput.Text = 'responses'
                $apiKeyEnvInput.Clear()
                $modelInput.Clear()
                $modelsInput.Clear()
                $reasoningEffortInput.Clear()
                $reviewModelInput.Clear()
            }
            $newKey.Clear()
        }
        finally {
            $script:ProfileEditorLoading = $false
        }

        Set-ProfileEditorAvailability -CanEdit $canEdit
        $providerTitle.Text = if ($isDraft) { '新建 Provider' } else { $selected.Name }
    $providerSubtitle.Text = if ($isDraft) { '填写连接信息后保存，随后即可检查和安全切换。' } elseif ($canEdit) { '管理连接和模型设置。保存后可检查并安全切换。' } else { '内置 Provider 使用现有 ChatGPT / Codex Plus 登录状态。' }

    $status = $null
    $statusError = $null
    try {
        $status = Invoke-Core -Arguments @('status')
        $script:ActiveProviderId = $status.current_provider
    }
    catch {
        $script:ActiveProviderId = $null
        $statusError = $_.Exception.Message
        Write-StartupDebugLog -Stage 'state.refresh_failed' -ErrorRecord $_
    }

    $isActive = $null -ne $status -and ($status.current_provider -eq $selected.Id -or ($selected.ProfileId -and $status.current_provider -eq $selected.ProfileId))
    $providerState.Text = if ($isDraft) { '草稿' } elseif (-not $selected.Enabled) { '已停用' } elseif ($isActive) { '当前使用' } else { '可用' }
    $providerState.ForeColor = if ($isDraft) { [System.Drawing.Color]::FromArgb(83, 83, 83) } elseif (-not $selected.Enabled) { [System.Drawing.Color]::FromArgb(139, 94, 0) } elseif ($isActive) { [System.Drawing.Color]::FromArgb(0, 82, 154) } else { [System.Drawing.Color]::FromArgb(16, 124, 16) }
    $providerState.BackColor = if ($isDraft) { [System.Drawing.Color]::FromArgb(235, 235, 235) } elseif (-not $selected.Enabled) { [System.Drawing.Color]::FromArgb(255, 244, 206) } elseif ($isActive) { [System.Drawing.Color]::FromArgb(218, 232, 252) } else { [System.Drawing.Color]::FromArgb(225, 245, 231) }
    $providerBox.Invalidate()

    if ($authModeInput.SelectedIndex -eq 1) {
        $keyStatus.Text = '使用登录状态，不保存 API Key。'
    }
    elseif ([string]::IsNullOrWhiteSpace($apiKeyEnvInput.Text)) {
        $keyStatus.Text = '保存前需要填写 API Key 环境变量名。'
    }
    else {
        $key = Get-KeyInfo -Name $apiKeyEnvInput.Text
        $keyStatus.Text = "$($key.Mask)  [$($key.Source)]"
    }

    if ($null -eq $status) {
        $warning.Text = '诊断暂不可用；不影响编辑或保存 Provider。'
        $historySummary.Text = '无法读取会话诊断。'
        $extensionSummary.Text = '请检查 Python 3 和应用文件是否可访问。'
    }
    else {
        $warning.Text = if ($status.inline_token_detected) { '检测到旧版内联 token；切换时会迁移到环境变量方式。' } else { '' }
        $activity = Get-ActivityDiagnosticsText -Diagnostics $status.diagnostics
        $historySummary.Text = $activity.History
        $extensionSummary.Text = $activity.Extensions
    }

    $script:ProfileEditorDirty = $false
    $editProviderButton.Visible = $canEdit
    $editProviderButton.Enabled = $canEdit
    $profileMenuButton.Visible = $null -ne $storedProfile -and -not $isDraft
    $profileMenuButton.Enabled = $profileMenuButton.Visible
    Update-ProfileActionMenu
    $checkButton.Enabled = -not $isDraft -and $selected.Enabled
    $switchButton.Enabled = -not $isDraft -and $selected.Enabled

    $running = @(Get-CodexProcesses)
    if ($running.Count -gt 0) {
        $statusBar.Text = "Codex 正在运行（$($running.Count) 个进程）；切换时会询问是否关闭并继续。"
    }
    elseif ($null -ne $statusError) {
        $statusBar.Text = "状态读取失败：$statusError"
    }
    else {
        $statusBar.Text = 'Codex 已关闭，可以执行切换。'
    }
    }
    catch {
        $statusBar.Text = 'Provider 界面刷新失败；请重新选择 Provider 或查看启动日志。'
        Write-StartupDebugLog -Stage 'state.render_failed' -Detail "$($_.Exception.Message) | $($_.ScriptStackTrace)"
    }
}

function Refresh-ProviderChoices {
    param([AllowNull()][string]$SelectProfileId = $null)

    $providerBox.BeginUpdate()
    try {
        $providerBox.Items.Clear()
        Add-ProviderChoicesToList -ListBox $providerBox
        if (-not [string]::IsNullOrWhiteSpace($SelectProfileId)) {
            foreach ($item in $providerBox.Items) {
                if ($item.ProfileId -eq $SelectProfileId) {
                    $providerBox.SelectedItem = $item
                    break
                }
            }
        }
        if ($null -eq $providerBox.SelectedItem -and $providerBox.Items.Count -gt 0) {
            $providerBox.SelectedIndex = 0
        }
    }
    finally {
        $providerBox.EndUpdate()
    }
    Update-View
}

function Start-NewProfileDraft {
    param([AllowNull()][object]$SourceProfile = $null)

    $script:DraftProfileId = [guid]::NewGuid().ToString()
    $draftName = if ($null -eq $SourceProfile) { '未命名 Provider' } else { "$(Get-ProfileTextValue -Profile $SourceProfile -Name 'name') 副本" }
    $draftEnabled = if ($null -eq $SourceProfile) { $true } else { (Get-ProfileTextValue -Profile $SourceProfile -Name 'enabled') -eq 'True' }
    $draftAuthMode = if ($null -eq $SourceProfile) { 'api_key' } else { Get-ProfileTextValue -Profile $SourceProfile -Name 'authMode' }
    $draftWireApi = 'responses'
    $script:DraftProfile = [pscustomobject]@{
        id = $script:DraftProfileId
        name = $draftName
        enabled = $draftEnabled
        authMode = $draftAuthMode
        baseUrl = Get-ProfileTextValue -Profile $SourceProfile -Name 'baseUrl'
        wireApi = $draftWireApi
        apiKeyEnv = Get-ProfileTextValue -Profile $SourceProfile -Name 'apiKeyEnv'
        model = Get-ProfileTextValue -Profile $SourceProfile -Name 'model'
        models = if ($null -eq $SourceProfile) { @() } else { @($SourceProfile.models) }
        reasoningEffort = Get-ProfileTextValue -Profile $SourceProfile -Name 'reasoningEffort'
        reviewModel = Get-ProfileTextValue -Profile $SourceProfile -Name 'reviewModel'
        configOverrides = @{}
    }
    $draftChoice = [pscustomobject]@{
        Name = $script:DraftProfile.name
        Id = 'custom'
        EnvKey = $script:DraftProfile.apiKeyEnv
        ProfileId = $script:DraftProfileId
        Enabled = $script:DraftProfile.enabled
        AuthMode = $script:DraftProfile.authMode
    }
    $providerBox.BeginUpdate()
    try {
        [void]$providerBox.Items.Add($draftChoice)
        $providerBox.SelectedItem = $draftChoice
    }
    finally {
        $providerBox.EndUpdate()
    }
    Update-View
}

$providerBox.Add_SelectedIndexChanged({
    $newKey.Clear()
    if ($null -eq $providerBox.SelectedItem -or $providerBox.SelectedItem.ProfileId -ne $script:DraftProfileId) {
        $script:DraftProfileId = $null
        $script:DraftProfile = $null
    }
    Update-View
})
$providerBox.Add_MouseDown({
    param($sender, $eventArgs)
    if ($eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
    $index = $sender.IndexFromPoint($eventArgs.Location)
    if ($index -ge 0) { $sender.SelectedIndex = $index }
})
$profileMenu.Add_Opening({
    param($sender, $eventArgs)
    Update-ProfileActionMenu
})
$displayNameInput.Add_TextChanged({
    if (-not $script:ProfileEditorLoading -and $null -ne $providerBox.SelectedItem -and $providerBox.SelectedItem.ProfileId -eq $script:DraftProfileId) {
        $providerBox.SelectedItem.Name = $displayNameInput.Text
        $providerBox.Invalidate()
    }
    Set-ProfileEditorDirty
})
$enabledInput.Add_CheckedChanged({ Set-ProfileEditorDirty })
$baseUrlInput.Add_TextChanged({ Set-ProfileEditorDirty })
$wireApiInput.Add_TextChanged({ Set-ProfileEditorDirty })
$apiKeyEnvInput.Add_TextChanged({ Set-ProfileEditorDirty })
$modelInput.Add_TextChanged({ Set-ProfileEditorDirty })
$modelsInput.Add_TextChanged({ Set-ProfileEditorDirty })
$reasoningEffortInput.Add_TextChanged({ Set-ProfileEditorDirty })
$reviewModelInput.Add_TextChanged({ Set-ProfileEditorDirty })
$authModeInput.Add_SelectedIndexChanged({
    if ($script:ProfileEditorLoading) { return }
    $selected = $providerBox.SelectedItem
    $canEdit = $null -ne $selected -and $null -ne $selected.ProfileId
    Set-ProfileEditorAvailability -CanEdit $canEdit
    $keyStatus.Text = if ($authModeInput.SelectedIndex -eq 1) { '使用现有 ChatGPT / Codex Plus 登录状态；不保存 API Key。' } else { '留空时保留现有 API Key；切换时才会写入环境变量。' }
    Set-ProfileEditorDirty
})
$refreshButton.Add_Click({ Update-View })

$addProviderButton.Add_Click({
    Start-NewProfileDraft
})

$editProviderButton.Add_Click({
    $selected = $providerBox.SelectedItem
    if ($null -eq $selected -or $null -eq $selected.ProfileId) { return }
    try {
        $profile = Get-ProfileFromEditor
        Invoke-ProfileCatalog -Arguments (Get-ProfileCatalogUpsertArguments -ProfileId $selected.ProfileId -Profile $profile)
        $script:DraftProfileId = $null
        $script:DraftProfile = $null
        Refresh-ProviderChoices -SelectProfileId $selected.ProfileId
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '保存失败', 'OK', 'Error') | Out-Null
    }
})

$editProviderMenuItem.Add_Click({ Open-SelectedProviderEditor })

$copyProviderMenuItem.Add_Click({
    $selected = $providerBox.SelectedItem
    if ($null -eq $selected -or $null -eq $selected.ProfileId) { return }
    try {
        $storedProfile = Get-StoredProfile -ProfileId $selected.ProfileId
        if ($null -eq $storedProfile) { throw '未找到要复制的 Provider。' }
        Start-NewProfileDraft -SourceProfile $storedProfile
    }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '复制失败', 'OK', 'Error') | Out-Null }
})

$deleteProviderMenuItem.Add_Click({
    $selected = $providerBox.SelectedItem
    if ($null -eq $selected -or $null -eq $selected.ProfileId) {
        [System.Windows.Forms.MessageBox]::Show('内置 Provider 不可删除。', '无法删除', 'OK', 'Warning') | Out-Null
        return
    }
    if ($script:ActiveProviderId -eq $selected.Id) {
        [System.Windows.Forms.MessageBox]::Show('请先切换到其他 Provider，再删除当前生效的 Provider。', '无法删除', 'OK', 'Warning') | Out-Null
        return
    }
    $answer = [System.Windows.Forms.MessageBox]::Show("确定删除 $($selected.Name)？此操作不会删除环境变量中的 API Key。", '确认删除 Provider', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        Invoke-ProfileCatalog -Arguments @('--id', $selected.ProfileId, '--remove')
        Refresh-ProviderChoices
    }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '删除失败', 'OK', 'Error') | Out-Null }
})

$toggleProviderMenuItem.Add_Click({
    $selected = $providerBox.SelectedItem
    if ($null -eq $selected -or $null -eq $selected.ProfileId) { return }
    if ($selected.Enabled -and $script:ActiveProviderId -eq $selected.Id) {
        [System.Windows.Forms.MessageBox]::Show('请先切换到其他 Provider，再停用当前生效的 Provider。', '无法停用', 'OK', 'Warning') | Out-Null
        return
    }
    try {
        $next = if ($selected.Enabled) { 'false' } else { 'true' }
        Invoke-ProfileCatalog -Arguments @('--id', $selected.ProfileId, '--set-enabled', $next)
        Refresh-ProviderChoices -SelectProfileId $selected.ProfileId
    }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '更新失败', 'OK', 'Error') | Out-Null }
})

$exportProviderMenuItem.Add_Click({
    $selected = $providerBox.SelectedItem
    if ($null -eq $selected -or $null -eq $selected.ProfileId) {
        [System.Windows.Forms.MessageBox]::Show('内置 Provider 不可导出。', '无法导出', 'OK', 'Warning') | Out-Null
        return
    }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = '导出 Provider'
    $dialog.Filter = 'Lansi Provider 配置 (*.lansi-profile.json)|*.lansi-profile.json|JSON 文件 (*.json)|*.json'
    $dialog.DefaultExt = 'json'
    $dialog.AddExtension = $true
    $dialog.FileName = "provider-$($selected.ProfileId).lansi-profile.json"
    try {
        if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        Invoke-ProfileCatalog -Arguments @('--id', $selected.ProfileId, '--export', $dialog.FileName) | Out-Null
        [System.Windows.Forms.MessageBox]::Show('Provider 已导出。导出文件不包含 API Key。', '导出完成', 'OK', 'Information') | Out-Null
    }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '导出失败', 'OK', 'Error') | Out-Null }
    finally { $dialog.Dispose() }
})

$importProviderButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = '导入 Provider'
    $dialog.Filter = 'Lansi Provider 配置 (*.lansi-profile.json)|*.lansi-profile.json|JSON 文件 (*.json)|*.json'
    $dialog.Multiselect = $false
    try {
        if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $result = (Invoke-ProfileCatalog -Arguments @('--import-file', $dialog.FileName)) | ConvertFrom-Json
        $importedProfileIds = @($result.importedProfileIds)
        if ($importedProfileIds.Count -eq 0) { throw '导入文件没有可用的 Provider。' }
        $importedProfileId = [string]$importedProfileIds[0]
        Refresh-ProviderChoices -SelectProfileId $importedProfileId
        [System.Windows.Forms.MessageBox]::Show('Provider 已导入。导入文件不包含 API Key。', '导入完成', 'OK', 'Information') | Out-Null
    }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '导入失败', 'OK', 'Error') | Out-Null }
    finally { $dialog.Dispose() }
})

$fetchModelsMenuItem.Add_Click({
    $selected = $providerBox.SelectedItem
    if ($null -eq $selected -or [string]::IsNullOrWhiteSpace($selected.ProfileId)) {
        [System.Windows.Forms.MessageBox]::Show('请选择一个已保存的自定义 Provider。', '无法获取模型', 'OK', 'Information') | Out-Null
        return
    }
    try {
        $profile = Get-StoredProfile -ProfileId $selected.ProfileId
        if ($null -eq $profile) { throw '未找到 Provider 配置。' }
        $models = @(Get-UpstreamModels -Profile $profile)
        $modelsInput.Text = $models -join ', '
        if ([string]::IsNullOrWhiteSpace($modelInput.Text) -or $models -notcontains $modelInput.Text.Trim()) {
            $modelInput.Text = $models[0]
        }
        [System.Windows.Forms.MessageBox]::Show("已获取 $($models.Count) 个模型。请点击“保存 Provider”写入配置。", '模型列表已更新', 'OK', 'Information') | Out-Null
    }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '获取模型失败', 'OK', 'Error') | Out-Null }
})

$checkButton.Add_Click({
    try {
        $selected = $providerBox.SelectedItem
        if ($selected.ProfileId -and -not $selected.Enabled) { throw '该 Provider 已停用，请先启用后再切换。' }
        if ($selected.AuthMode -eq 'api_key') {
            $key = Get-KeyInfo -Name $selected.EnvKey
            $candidate = $newKey.Text
            if ([string]::IsNullOrWhiteSpace($candidate) -and [string]::IsNullOrEmpty($key.Value)) {
                throw "$($selected.EnvKey) 尚未配置，请先输入 key。"
            }
        }
        $arguments = if ($selected.ProfileId) { @('switch', '--catalog', $script:CatalogPath, '--profile-id', $selected.ProfileId, '--dry-run') } else { @('switch', $selected.Id, '--dry-run') }
        $result = Invoke-Core -Arguments $arguments
        [System.Windows.Forms.MessageBox]::Show(
            "检查通过。`r`nProvider：$($selected.Id)`r`n需要修改配置：$($result.changed)`r`n本次没有修改文件、数据库或环境变量。",
            '检查完成',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '检查失败', 'OK', 'Error') | Out-Null
    }
})

$switchButton.Add_Click({
    $selected = $null
    $oldUserValue = $null
    try {
        $selected = $providerBox.SelectedItem
        if ($selected.ProfileId -and -not $selected.Enabled) { throw '该 Provider 已停用，请先启用后再切换。' }
        $candidate = $null
        if ($selected.AuthMode -eq 'api_key') {
            $existing = Get-KeyInfo -Name $selected.EnvKey
            $candidate = $newKey.Text
            if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $existing.Value }
            if ([string]::IsNullOrEmpty($candidate)) {
                throw "$($selected.EnvKey) 尚未配置，请先输入 key。"
            }
        }
        $credentialText = if ($selected.AuthMode -eq 'chatgpt_login') {
            '认证：现有 Codex Plus 登录状态'
        } else {
            "环境变量：$($selected.EnvKey)`r`nKey：$(Protect-Key $candidate)"
        }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "确定切换到 $($providerBox.SelectedItem)？`r`n`r`n$credentialText`r`n`r`n切换前会备份配置和会话数据库。",
            '确认切换 Provider', 'YesNo', 'Question'
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        if (-not (Request-CodexShutdown)) { return }

        if ($selected.AuthMode -eq 'api_key') {
            $oldUserValue = [Environment]::GetEnvironmentVariable($selected.EnvKey, 'User')
        }
        if ($selected.AuthMode -eq 'api_key' -and -not [string]::IsNullOrWhiteSpace($newKey.Text)) {
            [Environment]::SetEnvironmentVariable($selected.EnvKey, $newKey.Text, 'User')
            [Environment]::SetEnvironmentVariable($selected.EnvKey, $newKey.Text, 'Process')
            [EnvironmentBroadcast]::Notify()
        }
        $arguments = if ($selected.ProfileId) { @('switch', '--catalog', $script:CatalogPath, '--profile-id', $selected.ProfileId) } else { @('switch', $selected.Id) }
        $result = Invoke-Core -Arguments $arguments
        if (-not $result.verified_config) { throw '配置写入后的 Provider 校验失败。' }
        if ($null -ne $result.verified_threads -and -not $result.verified_threads) {
            throw '会话数据库写入后的 Provider 校验失败。'
        }
        $newKey.Clear()
        Update-View
        $launch = [System.Windows.Forms.MessageBox]::Show(
            "切换并校验成功。`r`n当前 Provider：$($selected.Id)`r`n历史会话、Skill、MCP 和插件已保留。`r`n配置备份：$($result.config_backup)`r`n`r`nChatGPT 的登录提示不代表当前 Provider。是否立即启动 Codex？",
            '切换完成', 'YesNo', 'Information'
        )
        if ($launch -eq [System.Windows.Forms.DialogResult]::Yes) { Start-CodexDesktop }
    }
    catch {
        if ($null -ne $selected -and $selected.AuthMode -eq 'api_key' -and -not [string]::IsNullOrWhiteSpace($newKey.Text)) {
            [Environment]::SetEnvironmentVariable($selected.EnvKey, $oldUserValue, 'User')
            [EnvironmentBroadcast]::Notify()
        }
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '切换失败', 'OK', 'Error') | Out-Null
    }
})

$restoreButton.Add_Click({
    try {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            '确定恢复最近一次配置和会话数据库备份？API key 环境变量不会改变。',
            '确认恢复', 'YesNo', 'Warning'
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        if (-not (Request-CodexShutdown)) { return }
        $result = Invoke-Core -Arguments @('restore')
        Update-View
        [System.Windows.Forms.MessageBox]::Show(
            "最近备份已恢复。`r`n配置：$($result.config_backup)`r`n会话数据库：$($result.state_backup)",
            '恢复完成', 'OK', 'Information'
        ) | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '恢复失败', 'OK', 'Error') | Out-Null
    }
})

$form.Add_Shown({
    Write-StartupDebugLog -Stage 'startup.form_shown'
    try {
        # Apply the macOS-aligned navigation width after WinForms has completed DPI scaling.
        $workspace.Panel1MinSize = 230
        $workspace.SplitterDistance = 240
        Enable-Windows11Chrome -Window $form -ThemedControls @($providerBox, $newKey, $addProviderButton, $refreshButton, $checkButton, $utilityMenuButton, $editProviderButton, $profileMenuButton, $switchButton)
    }
    catch { Write-StartupDebugLog -Stage 'startup.chrome_failed' -ErrorRecord $_ }
    Update-View
})
try {
    Write-StartupDebugLog -Stage 'startup.show_dialog'
    [void]$form.ShowDialog()
    Write-StartupDebugLog -Stage 'startup.closed'
}
catch {
    Write-StartupDebugLog -Stage 'startup.show_dialog_failed' -ErrorRecord $_
    try {
        [System.Windows.Forms.MessageBox]::Show("窗口启动失败。`r`n诊断日志：$script:DebugLogPath", 'Lansi Codex Provider Manager', 'OK', 'Error') | Out-Null
    }
    catch { }
    throw
}
