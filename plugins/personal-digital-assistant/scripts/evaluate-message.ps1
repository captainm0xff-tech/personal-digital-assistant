[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EventPath,
    [string]$DataRoot
)

$ErrorActionPreference = 'Stop'
$pluginRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $pluginRoot 'runtime\store.ps1')
. (Join-Path $pluginRoot 'runtime\policy.ps1')

$eventFile = [IO.Path]::GetFullPath($EventPath)
if (-not (Test-Path -LiteralPath $eventFile)) { throw "消息信封不存在：$eventFile" }
$event = Get-Content -LiteralPath $eventFile -Raw -Encoding UTF8 | ConvertFrom-Json
$store = Read-PdaStore $DataRoot
$decision = Get-PdaPolicyDecision -Event $event -Store $store
$decision | ConvertTo-Json -Depth 8
