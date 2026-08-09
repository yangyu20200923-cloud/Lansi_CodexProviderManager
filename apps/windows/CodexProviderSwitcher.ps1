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
$script:CatalogPath = Join-Path $env:APPDATA 'Lansi_CodexProviderManager\profiles.json'

function Get-ProviderChoices {
    $choices = @($script:Providers.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = $_.Key; Id = $_.Value.Id; EnvKey = $_.Value.EnvKey; ProfileId = $null; Enabled = $true } })
    if (Test-Path $script:CatalogPath) {
        $catalog = Get-Content -Raw $script:CatalogPath | ConvertFrom-Json
        $choices += @($catalog.profiles | ForEach-Object { [pscustomobject]@{ Name = $_.name; Id = 'custom'; EnvKey = $_.apiKeyEnv; ProfileId = $_.id; Enabled = $_.enabled } })
    }
    return $choices
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

function Show-ProviderDialog {
    param(
        [Parameter(Mandatory)][string]$Title,
        [AllowNull()][object]$Profile = $null
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.StartPosition = 'CenterParent'
    $dialog.ClientSize = New-Object System.Drawing.Size(440, 280)
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false

    $fields = @('名称', 'Base URL', 'Wire API', '环境变量名', '模型')
    $values = if ($null -eq $Profile) {
        @('', '', 'responses', '', '')
    } else {
        @($Profile.name, $Profile.baseUrl, $Profile.wireApi, $Profile.apiKeyEnv, $Profile.model)
    }
    $inputs = @()
    for ($i = 0; $i -lt $fields.Count; $i++) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $fields[$i]
        $label.Location = New-Object System.Drawing.Point(18, (18 + $i * 38))
        $label.Size = New-Object System.Drawing.Size(105, 24)
        $dialog.Controls.Add($label)

        $input = New-Object System.Windows.Forms.TextBox
        $input.Text = $values[$i]
        $input.Location = New-Object System.Drawing.Point(130, (15 + $i * 38))
        $input.Size = New-Object System.Drawing.Size(285, 26)
        $dialog.Controls.Add($input)
        $inputs += $input
    }

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'
    $cancel.Location = New-Object System.Drawing.Point(220, 230)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancel)
    $dialog.CancelButton = $cancel

    $save = New-Object System.Windows.Forms.Button
    $save.Text = '保存'
    $save.Location = New-Object System.Drawing.Point(310, 230)
    $save.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($save)
    $dialog.AcceptButton = $save

    if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return [pscustomobject]@{
        Name = $inputs[0].Text
        BaseUrl = $inputs[1].Text
        WireApi = $inputs[2].Text
        ApiKeyEnv = $inputs[3].Text
        Model = $inputs[4].Text
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Codex API 切换器'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(640, 575)
$form.MinimumSize = New-Object System.Drawing.Size(656, 614)
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
$providerBox.DisplayMember = 'Name'
$providerBox.ValueMember = 'Id'
[void]$providerBox.Items.AddRange([object[]](Get-ProviderChoices))
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

$addProviderButton = New-Object System.Windows.Forms.Button
$addProviderButton.Text = '新增 Provider'
$addProviderButton.Location = New-Object System.Drawing.Point(352, 410)
$addProviderButton.Size = New-Object System.Drawing.Size(104, 34)
$form.Controls.Add($addProviderButton)

$editProviderButton = New-Object System.Windows.Forms.Button
$editProviderButton.Text = '编辑 Provider'; $editProviderButton.Location = New-Object System.Drawing.Point(24, 450); $editProviderButton.Size = New-Object System.Drawing.Size(104, 30); $editProviderButton.Enabled = $false
$form.Controls.Add($editProviderButton)
$copyProviderButton = New-Object System.Windows.Forms.Button
$copyProviderButton.Text = '复制 Provider'; $copyProviderButton.Location = New-Object System.Drawing.Point(248, 450); $copyProviderButton.Size = New-Object System.Drawing.Size(104, 30); $copyProviderButton.Enabled = $false
$form.Controls.Add($copyProviderButton)
$deleteProviderButton = New-Object System.Windows.Forms.Button
$deleteProviderButton.Text = '删除 Provider'; $deleteProviderButton.Location = New-Object System.Drawing.Point(136, 450); $deleteProviderButton.Size = New-Object System.Drawing.Size(104, 30); $deleteProviderButton.Enabled = $false
$form.Controls.Add($deleteProviderButton)
$toggleProviderButton = New-Object System.Windows.Forms.Button
$toggleProviderButton.Location = New-Object System.Drawing.Point(360, 450); $toggleProviderButton.Size = New-Object System.Drawing.Size(96, 30); $toggleProviderButton.Enabled = $false
$form.Controls.Add($toggleProviderButton)
$exportProviderButton = New-Object System.Windows.Forms.Button
$exportProviderButton.Text = '导出 Provider'; $exportProviderButton.Location = New-Object System.Drawing.Point(464, 450); $exportProviderButton.Size = New-Object System.Drawing.Size(152, 30); $exportProviderButton.Enabled = $false
$form.Controls.Add($exportProviderButton)
$importProviderButton = New-Object System.Windows.Forms.Button
$importProviderButton.Text = '导入 Provider'; $importProviderButton.Location = New-Object System.Drawing.Point(24, 490); $importProviderButton.Size = New-Object System.Drawing.Size(104, 30)
$form.Controls.Add($importProviderButton)

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
$statusBar.Location = New-Object System.Drawing.Point(27, 534)
$statusBar.Size = New-Object System.Drawing.Size(585, 24)
$statusBar.ForeColor = [System.Drawing.Color]::FromArgb(85, 92, 104)
$form.Controls.Add($statusBar)

function Update-View {
    try {
        $status = Invoke-Core -Arguments @('status')
        $selected = $providerBox.SelectedItem
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

function Refresh-ProviderChoices {
    param([AllowNull()][string]$SelectProfileId = $null)

    $providerBox.BeginUpdate()
    try {
        $providerBox.Items.Clear()
        [void]$providerBox.Items.AddRange([object[]](Get-ProviderChoices))
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

$providerBox.Add_SelectedIndexChanged({
    $newKey.Clear()
    $isCustom = $null -ne $providerBox.SelectedItem -and $null -ne $providerBox.SelectedItem.ProfileId
    $editProviderButton.Enabled = $isCustom; $copyProviderButton.Enabled = $isCustom; $deleteProviderButton.Enabled = $isCustom; $toggleProviderButton.Enabled = $isCustom; $exportProviderButton.Enabled = $isCustom
    $toggleProviderButton.Text = if ($isCustom -and $providerBox.SelectedItem.Enabled) { '停用 Provider' } else { '启用 Provider' }
    Update-View
})
$refreshButton.Add_Click({ Update-View })

$addProviderButton.Add_Click({
    try {
        $profile = Show-ProviderDialog -Title '新增 Provider'
        if ($null -eq $profile) { return }
        $profileId = [guid]::NewGuid().ToString()
        Invoke-ProfileCatalog -Arguments @(
            '--id', $profileId, '--name', $profile.Name, '--base-url', $profile.BaseUrl,
            '--wire-api', $profile.WireApi, '--api-key-env', $profile.ApiKeyEnv, '--model', $profile.Model
        )
        Refresh-ProviderChoices -SelectProfileId $profileId
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '保存失败', 'OK', 'Error') | Out-Null
    }
})

$editProviderButton.Add_Click({
    $selected = $providerBox.SelectedItem
    if ($null -eq $selected -or $null -eq $selected.ProfileId) { return }
    try {
        $catalog = Get-Content -Raw $script:CatalogPath | ConvertFrom-Json
        $storedProfile = $catalog.profiles | Where-Object { $_.id -eq $selected.ProfileId } | Select-Object -First 1
        if ($null -eq $storedProfile) { throw '未找到要编辑的 Provider。' }
        $profile = Show-ProviderDialog -Title '编辑 Provider' -Profile $storedProfile
        if ($null -eq $profile) { return }
        Invoke-ProfileCatalog -Arguments @(
            '--id', $selected.ProfileId, '--name', $profile.Name, '--base-url', $profile.BaseUrl,
            '--wire-api', $profile.WireApi, '--api-key-env', $profile.ApiKeyEnv, '--model', $profile.Model
        )
        Refresh-ProviderChoices -SelectProfileId $selected.ProfileId
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '保存失败', 'OK', 'Error') | Out-Null
    }
})

$copyProviderButton.Add_Click({
    $selected = $providerBox.SelectedItem
    if ($null -eq $selected -or $null -eq $selected.ProfileId) { return }
    try {
        $catalog = Get-Content -Raw $script:CatalogPath | ConvertFrom-Json
        $storedProfile = $catalog.profiles | Where-Object { $_.id -eq $selected.ProfileId } | Select-Object -First 1
        if ($null -eq $storedProfile) { throw '未找到要复制的 Provider。' }
        $profile = Show-ProviderDialog -Title '复制 Provider' -Profile $storedProfile
        if ($null -eq $profile) { return }
        $newProfileId = [guid]::NewGuid().ToString()
        Invoke-ProfileCatalog -Arguments @('--id', $newProfileId, '--name', $profile.name, '--base-url', $profile.baseUrl, '--wire-api', $profile.wireApi, '--api-key-env', $profile.apiKeyEnv, '--model', $profile.model)
        Refresh-ProviderChoices -SelectProfileId $newProfileId
    }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '复制失败', 'OK', 'Error') | Out-Null }
})

$deleteProviderButton.Add_Click({
    $selected = $providerBox.SelectedItem
    if ($null -eq $selected -or $null -eq $selected.ProfileId) {
        [System.Windows.Forms.MessageBox]::Show('内置 Provider 不可删除。', '无法删除', 'OK', 'Warning') | Out-Null
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

$toggleProviderButton.Add_Click({
    $selected = $providerBox.SelectedItem
    if ($null -eq $selected -or $null -eq $selected.ProfileId) { return }
    try {
        $next = if ($selected.Enabled) { 'false' } else { 'true' }
        Invoke-ProfileCatalog -Arguments @('--id', $selected.ProfileId, '--set-enabled', $next)
        Refresh-ProviderChoices -SelectProfileId $selected.ProfileId
    }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '更新失败', 'OK', 'Error') | Out-Null }
})

$exportProviderButton.Add_Click({
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

$checkButton.Add_Click({
    try {
        $selected = $providerBox.SelectedItem
        if ($selected.ProfileId -and -not $selected.Enabled) { throw '该 Provider 已停用，请先启用后再切换。' }
        if ($selected.Id -ne 'openai') {
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
        $arguments = if ($selected.ProfileId) { @('switch', '--catalog', $script:CatalogPath, '--profile-id', $selected.ProfileId) } else { @('switch', $selected.Id) }
        $result = Invoke-Core -Arguments $arguments
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
