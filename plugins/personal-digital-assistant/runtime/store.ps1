Set-StrictMode -Version Latest

function Get-PdaDataRoot {
    param([string]$DataRoot)
    if ($DataRoot) { return [IO.Path]::GetFullPath($DataRoot) }
    return Join-Path $env:LOCALAPPDATA 'PersonalDigitalAssistant'
}

function Get-PdaStorePath {
    param([string]$DataRoot)
    return Join-Path (Get-PdaDataRoot $DataRoot) 'store.json'
}

function Read-PdaStore {
    param([string]$DataRoot)
    $path = Get-PdaStorePath $DataRoot
    if (-not (Test-Path -LiteralPath $path)) { throw "个人助理尚未初始化：$path" }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-PdaStore {
    param([Parameter(Mandatory)]$Store, [string]$DataRoot)
    $path = Get-PdaStorePath $DataRoot
    $tmp = "$path.tmp"
    $Store.updatedAt = [DateTime]::UtcNow.ToString('o')
    $Store | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Add-PdaAudit {
    param([Parameter(Mandatory)]$Store, [string]$Action, [string]$Detail)
    $entry = [pscustomobject]@{
        id = [guid]::NewGuid().ToString('N')
        time = [DateTime]::UtcNow.ToString('o')
        action = $Action
        detail = $Detail
    }
    $Store.audit = @($entry) + @($Store.audit) | Select-Object -First 200
}

function ConvertTo-PdaFileName {
    param([string]$Text)
    $name = if ($Text) { $Text.Trim() } else { '未命名' }
    foreach ($char in [IO.Path]::GetInvalidFileNameChars()) { $name = $name.Replace([string]$char, '_') }
    if ($name.Length -gt 60) { $name = $name.Substring(0, 60) }
    return $name
}

function Write-PdaFollowupDocument {
    param([Parameter(Mandatory)]$Item, [string]$DataRoot)
    $root = Get-PdaDataRoot $DataRoot
    $safe = ConvertTo-PdaFileName $Item.title
    $path = Join-Path $root "工作推进\单项跟进\$safe-$($Item.id.Substring(0,8)).md"
    if (-not (Test-Path -LiteralPath $path)) {
        $lines = @(
            "# $($Item.title)", '',
            "- 跟进编号：$($Item.id)",
            "- 跟进对象：$($Item.target)",
            "- 跟进方式：$($Item.method)",
            "- 跟进周期：$($Item.cycle)",
            "- 状态：$($Item.status)",
            "- 创建时间：$($Item.createdAt)", '',
            '## 补充跟进规则', '',
            $(if ($Item.rule) { $Item.rule } else { '无' }), '',
            '## 跟进过程与聊天记录', '',
            '> 后续外发消息、对方回复、决策、失败重试和关闭证据按时间顺序追加到这里。', ''
        )
        $lines | Set-Content -LiteralPath $path -Encoding UTF8
    }
    return $path
}

function Append-PdaContactMessage {
    param(
        [Parameter(Mandatory)][string]$Contact,
        [Parameter(Mandatory)][string]$Direction,
        [Parameter(Mandatory)][string]$Content,
        [string]$StableId,
        [string]$DataRoot
    )
    $root = Get-PdaDataRoot $DataRoot
    $safe = ConvertTo-PdaFileName $Contact
    $suffix = if ($StableId) { '-' + (ConvertTo-PdaFileName $StableId) } else { '' }
    $path = Join-Path $root "联系人对话\$safe$suffix.md"
    if (-not (Test-Path -LiteralPath $path)) { @("# 与 $Contact 的对话", '') | Set-Content -LiteralPath $path -Encoding UTF8 }
    $time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    @("## $time · $Direction", '', $Content, '') | Add-Content -LiteralPath $path -Encoding UTF8
    return $path
}
