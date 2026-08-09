[CmdletBinding()]
param([string]$RepositoryRoot)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = Split-Path $PSScriptRoot -Parent }
$root = [IO.Path]::GetFullPath($RepositoryRoot)
$errors = [Collections.Generic.List[string]]::new()

function Add-CheckError([string]$Message) { $script:errors.Add($Message) }

$required = @(
    'LICENSE', 'README.md', 'SECURITY.md', 'CONTRIBUTING.md', 'VERSION',
    '.agents\plugins\marketplace.json',
    'plugins\personal-digital-assistant\.codex-plugin\plugin.json',
    'plugins\personal-digital-assistant\skills\personal-digital-assistant\SKILL.md'
)
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $relative))) { Add-CheckError "缺少文件：$relative" }
}

Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.json | ForEach-Object {
    try { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null }
    catch { Add-CheckError "JSON 无效：$($_.FullName.Substring($root.Length + 1))" }
}

Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.ps1 | ForEach-Object {
    $tokens = $null; $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    foreach ($parseError in @($parseErrors)) {
        Add-CheckError "PowerShell 语法错误：$($_.FullName.Substring($root.Length + 1))：$($parseError.Message)"
    }
}

$forbiddenExtensions = @('.log','.db','.sqlite','.sqlite3','.secret','.pem','.pfx','.p12','.key')
Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $forbiddenExtensions -contains $_.Extension.ToLowerInvariant() } | ForEach-Object {
    Add-CheckError "发布包包含运行数据或密钥文件：$($_.FullName.Substring($root.Length + 1))"
}

$textExtensions = @('.md','.json','.yaml','.yml','.toml','.ps1','.js','.html','.css','.txt')
$patterns = [ordered]@{
    'Windows 用户绝对路径' = '(?i)[A-Z]:\\Users\\[^<\\\s]+'
    '工作区绝对路径' = '(?i)[A-Z]:\\(?:文档|Documents)\\'
    '钉钉 Open ID' = '(?i)DES[A-Za-z0-9+/]{20,}'
    '机器人代码' = '(?i)ding[a-z0-9]{18,}'
    '疑似私钥' = '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
    '疑似明文密钥' = '(?im)^\s*(?:client_secret|app_secret|bot_secret|api_key|access_token)\s*[:=]\s*["''][^<\$`\{][^"'']{10,}["'']\s*$'
}
Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $textExtensions -contains $_.Extension.ToLowerInvariant() } | ForEach-Object {
    $relative = $_.FullName.Substring($root.Length + 1)
    if ($relative -eq 'scripts\release-check.ps1') { return }
    $text = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
    foreach ($entry in $patterns.GetEnumerator()) {
        if ($text -match $entry.Value) { Add-CheckError "$($entry.Key)：$relative" }
    }
}

$version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw -Encoding UTF8).Trim()
foreach ($manifestPath in @(
    'plugins\personal-digital-assistant\.codex-plugin\plugin.json',
    'plugins\personal-digital-assistant\.codebuddy-plugin\plugin.json'
)) {
    $manifest = Get-Content -LiteralPath (Join-Path $root $manifestPath) -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.version -ne $version) { Add-CheckError "版本不一致：$manifestPath = $($manifest.version)，VERSION = $version" }
}

if ($errors.Count) {
    $errors | ForEach-Object { Write-Error $_ }
    throw "发布检查失败，共 $($errors.Count) 项。"
}

Write-Output "发布检查通过：$version"
