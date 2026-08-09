[CmdletBinding()]
param(
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
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
}
'@

$script:Providers = [ordered]@{
    'OpenAI Plus'  = [pscustomobject]@{ Id = 'openai'; EnvKey = $null }
    'Qilin'        = [pscustomobject]@{ Id = 'qilin'; EnvKey = 'QILIN_API_KEY' }
    'VectorEngine' = [pscustomobject]@{ Id = 'vectorengine'; EnvKey = 'VECTORENGINE_API_KEY' }
}
$script:CorePath = Join-Path $PSScriptRoot 'switch_provider.py'
$script:ConfigPath = Join-Path $CodexHome 'config.toml'
$script:StatePath = Join-Path $CodexHome 'state_5.sqlite'

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

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Codex API 切换器'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(640, 500)
$form.MinimumSize = New-Object System.Drawing.Size(656, 539)
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(247, 248, 250)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Codex API 切换器'
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 17)
$title.Location = New-Object System.Drawing.Point(24, 20)
$title.AutoSize = $true
$form.Controls.Add($title)

$shared = New-Object System.Windows.Forms.Label
$shared.Text = "共用 Codex 目录：$CodexHome"
$shared.ForeColor = [System.Drawing.Color]::FromArgb(85, 92, 104)
$shared.Location = New-Object System.Drawing.Point(27, 57)
$shared.Size = New-Object System.Drawing.Size(580, 22)
$form.Controls.Add($shared)

$panel = New-Object System.Windows.Forms.Panel
$panel.Location = New-Object System.Drawing.Point(24, 91)
$panel.Size = New-Object System.Drawing.Size(592, 300)
$panel.BackColor = [System.Drawing.Color]::White
$panel.BorderStyle = 'FixedSingle'
$form.Controls.Add($panel)

function Add-FieldLabel([string]$Text, [int]$Y) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point(20, $Y)
    $label.Size = New-Object System.Drawing.Size(145, 24)
    $label.ForeColor = [System.Drawing.Color]::FromArgb(70, 76, 88)
    $panel.Controls.Add($label)
}

Add-FieldLabel '目标 Provider' 24
Add-FieldLabel '当前 Provider' 70
Add-FieldLabel '认证方式 / 环境变量' 112
Add-FieldLabel '当前认证状态' 154
Add-FieldLabel '更改 API Key（可选）' 198

$providerBox = New-Object System.Windows.Forms.ComboBox
$providerBox.DropDownStyle = 'DropDownList'
$providerBox.Location = New-Object System.Drawing.Point(176, 20)
$providerBox.Size = New-Object System.Drawing.Size(380, 28)
[void]$providerBox.Items.AddRange([object[]]$script:Providers.Keys)
$providerBox.SelectedIndex = 0
$panel.Controls.Add($providerBox)

$currentProvider = New-Object System.Windows.Forms.Label
$currentProvider.Location = New-Object System.Drawing.Point(176, 70)
$currentProvider.Size = New-Object System.Drawing.Size(380, 24)
$panel.Controls.Add($currentProvider)

$envName = New-Object System.Windows.Forms.Label
$envName.Location = New-Object System.Drawing.Point(176, 112)
$envName.Size = New-Object System.Drawing.Size(380, 24)
$envName.Font = New-Object System.Drawing.Font('Consolas', 9)
$panel.Controls.Add($envName)

$keyStatus = New-Object System.Windows.Forms.Label
$keyStatus.Location = New-Object System.Drawing.Point(176, 154)
$keyStatus.Size = New-Object System.Drawing.Size(380, 24)
$panel.Controls.Add($keyStatus)

$newKey = New-Object System.Windows.Forms.TextBox
$newKey.Location = New-Object System.Drawing.Point(176, 194)
$newKey.Size = New-Object System.Drawing.Size(380, 27)
$newKey.UseSystemPasswordChar = $true
$panel.Controls.Add($newKey)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = '留空表示继续使用当前 key；输入新值会更新当前用户环境变量。'
$hint.Location = New-Object System.Drawing.Point(176, 227)
$hint.Size = New-Object System.Drawing.Size(380, 38)
$hint.ForeColor = [System.Drawing.Color]::FromArgb(100, 107, 119)
$panel.Controls.Add($hint)

$warning = New-Object System.Windows.Forms.Label
$warning.Location = New-Object System.Drawing.Point(20, 267)
$warning.Size = New-Object System.Drawing.Size(540, 23)
$warning.ForeColor = [System.Drawing.Color]::FromArgb(166, 82, 20)
$panel.Controls.Add($warning)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = '刷新状态'
$refreshButton.Location = New-Object System.Drawing.Point(24, 410)
$refreshButton.Size = New-Object System.Drawing.Size(92, 34)
$form.Controls.Add($refreshButton)

$checkButton = New-Object System.Windows.Forms.Button
$checkButton.Text = '仅检查'
$checkButton.Location = New-Object System.Drawing.Point(124, 410)
$checkButton.Size = New-Object System.Drawing.Size(100, 34)
$form.Controls.Add($checkButton)

$restoreButton = New-Object System.Windows.Forms.Button
$restoreButton.Text = '恢复最近备份'
$restoreButton.Location = New-Object System.Drawing.Point(232, 410)
$restoreButton.Size = New-Object System.Drawing.Size(112, 34)
$form.Controls.Add($restoreButton)

$switchButton = New-Object System.Windows.Forms.Button
$switchButton.Text = '切换 Provider'
$switchButton.Location = New-Object System.Drawing.Point(464, 410)
$switchButton.Size = New-Object System.Drawing.Size(152, 34)
$switchButton.BackColor = [System.Drawing.Color]::FromArgb(26, 115, 232)
$switchButton.ForeColor = [System.Drawing.Color]::White
$switchButton.FlatStyle = 'Flat'
$form.Controls.Add($switchButton)

$statusBar = New-Object System.Windows.Forms.Label
$statusBar.Text = '就绪'
$statusBar.Location = New-Object System.Drawing.Point(27, 462)
$statusBar.Size = New-Object System.Drawing.Size(585, 24)
$statusBar.ForeColor = [System.Drawing.Color]::FromArgb(85, 92, 104)
$form.Controls.Add($statusBar)

function Update-View {
    try {
        $status = Invoke-Core -Arguments @('status')
        $selected = $script:Providers[$providerBox.SelectedItem.ToString()]
        $currentProvider.Text = if ($status.current_provider) { $status.current_provider } else { '未检测到' }
        if ($selected.Id -eq 'openai') {
            $envName.Text = 'Codex Plus 登录（auth.json）'
            $keyStatus.Text = '使用现有 ChatGPT / Codex Plus 登录状态'
            $newKey.Enabled = $false
            $newKey.Clear()
            $hint.Text = 'OpenAI 不使用 API key，直接复用 Codex Plus 登录状态。'
        }
        else {
            $key = Get-KeyInfo -Name $selected.EnvKey
            $envName.Text = $selected.EnvKey
            $keyStatus.Text = "$($key.Mask)  [$($key.Source)]"
            $newKey.Enabled = $true
            $hint.Text = '留空表示继续使用当前 key；输入新值会更新当前用户环境变量。'
        }
        $warning.Text = if ($status.inline_token_detected) {
            '检测到旧版内联 token；切换时会迁移到环境变量方式。'
        } else { '' }
        $running = @(Get-CodexProcesses)
        $statusBar.Text = if ($running.Count -gt 0) {
            "Codex 正在运行（$($running.Count) 个进程）；切换时会询问是否关闭并继续。"
        } else { 'Codex 已关闭，可以执行切换。' }
    }
    catch {
        $statusBar.Text = "状态读取失败：$($_.Exception.Message)"
    }
}

$providerBox.Add_SelectedIndexChanged({
    $newKey.Clear()
    Update-View
})
$refreshButton.Add_Click({ Update-View })

$checkButton.Add_Click({
    try {
        $selected = $script:Providers[$providerBox.SelectedItem.ToString()]
        if ($selected.Id -ne 'openai') {
            $key = Get-KeyInfo -Name $selected.EnvKey
            $candidate = $newKey.Text
            if ([string]::IsNullOrWhiteSpace($candidate) -and [string]::IsNullOrEmpty($key.Value)) {
                throw "$($selected.EnvKey) 尚未配置，请先输入 key。"
            }
        }
        $result = Invoke-Core -Arguments @('switch', $selected.Id, '--dry-run')
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
        $selected = $script:Providers[$providerBox.SelectedItem.ToString()]
        $candidate = $null
        if ($selected.Id -ne 'openai') {
            $existing = Get-KeyInfo -Name $selected.EnvKey
            $candidate = $newKey.Text
            if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $existing.Value }
            if ([string]::IsNullOrEmpty($candidate)) {
                throw "$($selected.EnvKey) 尚未配置，请先输入 key。"
            }
        }
        $credentialText = if ($selected.Id -eq 'openai') {
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

        if ($selected.Id -ne 'openai') {
            $oldUserValue = [Environment]::GetEnvironmentVariable($selected.EnvKey, 'User')
        }
        if ($selected.Id -ne 'openai' -and -not [string]::IsNullOrWhiteSpace($newKey.Text)) {
            [Environment]::SetEnvironmentVariable($selected.EnvKey, $newKey.Text, 'User')
            [Environment]::SetEnvironmentVariable($selected.EnvKey, $newKey.Text, 'Process')
            [EnvironmentBroadcast]::Notify()
        }
        $result = Invoke-Core -Arguments @('switch', $selected.Id)
        if (-not $result.verified_config) { throw '配置写入后的 Provider 校验失败。' }
        if ($null -ne $result.verified_threads -and -not $result.verified_threads) {
            throw '会话数据库写入后的 Provider 校验失败。'
        }
        $newKey.Clear()
        Update-View
        $launch = [System.Windows.Forms.MessageBox]::Show(
            "切换并校验成功。`r`n当前 Provider：$($selected.Id)`r`n同步会话：$($result.synced_threads) 条`r`n配置备份：$($result.config_backup)`r`n`r`n是否立即启动 Codex？",
            '切换完成', 'YesNo', 'Information'
        )
        if ($launch -eq [System.Windows.Forms.DialogResult]::Yes) { Start-CodexDesktop }
    }
    catch {
        if ($null -ne $selected -and $selected.Id -ne 'openai' -and -not [string]::IsNullOrWhiteSpace($newKey.Text)) {
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

$form.Add_Shown({ Update-View })
[void]$form.ShowDialog()
