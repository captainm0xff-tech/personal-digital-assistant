[CmdletBinding()]
param(
    [string]$DataRoot,
    [string]$OwnerName = $env:USERNAME,
    [string]$TimeZone = 'Asia/Shanghai',
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')][string]$DigestTime = '20:00',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$pluginRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $pluginRoot 'runtime\store.ps1')
$root = Get-PdaDataRoot $DataRoot
$storePath = Join-Path $root 'store.json'

if ((Test-Path -LiteralPath $storePath) -and -not $Force) {
    Write-Output "个人助理已经初始化：$root"
    exit 0
}

$folders = @(
    '知识库',
    '工作推进\单项跟进',
    '工作推进\项目',
    '日常工作（待办）',
    '邮箱',
    '联系人对话',
    '日报',
    '审计',
    '运行日志'
)
New-Item -ItemType Directory -Path $root -Force | Out-Null
foreach ($folder in $folders) { New-Item -ItemType Directory -Path (Join-Path $root $folder) -Force | Out-Null }

$now = [DateTime]::UtcNow.ToString('o')
$store = [pscustomobject]@{
    schemaVersion = 1
    instanceId = [guid]::NewGuid().ToString('N')
    createdAt = $now
    updatedAt = $now
    config = [pscustomobject]@{
        ownerName = $OwnerName
        timeZone = $TimeZone
        digestTime = $DigestTime
        aiLabelEnabled = $false
        autoSendEnabled = $false
        escalationPhrases = @('人工','现身','请现真身',$OwnerName)
    }
    whitelist = @()
    tasks = @()
    followups = @()
    channels = @()
    audit = @()
}
Add-PdaAudit -Store $store -Action 'instance_initialized' -Detail "创建独立用户实例：$OwnerName"
Write-PdaStore -Store $store -DataRoot $root

@('# 私有知识库', '', '> 这里只存放当前用户确认允许沉淀的知识。聊天内容不会自动升级为正式知识。', '') |
    Set-Content -LiteralPath (Join-Path $root '知识库\README.md') -Encoding UTF8
@('# 表达风格', '', '- 尚未学习。只有用户明确授权后才从用户自己的消息中提炼。', '') |
    Set-Content -LiteralPath (Join-Path $root '知识库\表达风格.md') -Encoding UTF8

Write-Output "初始化完成：$root"
Write-Output '自动外发默认关闭；请先在管理台确认白名单和消息策略。'
