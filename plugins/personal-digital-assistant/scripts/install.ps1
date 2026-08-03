[CmdletBinding()]
param(
    [string]$WorkBuddyHome = (Join-Path $env:USERPROFILE '.workbuddy'),
    [switch]$Initialize
)

$ErrorActionPreference = 'Stop'
$pluginRoot = Split-Path $PSScriptRoot -Parent
$skillSource = Join-Path $pluginRoot 'skills\personal-digital-assistant'
$pluginTarget = Join-Path $WorkBuddyHome 'plugins\personal-digital-assistant'
$skillTarget = Join-Path $WorkBuddyHome 'skills\personal-digital-assistant'

New-Item -ItemType Directory -Path (Split-Path $pluginTarget -Parent) -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path $skillTarget -Parent) -Force | Out-Null

if (Test-Path -LiteralPath $pluginTarget) {
    $backup = "$pluginTarget.backup-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Move-Item -LiteralPath $pluginTarget -Destination $backup
}
Copy-Item -LiteralPath $pluginRoot -Destination $pluginTarget -Recurse -Force
Copy-Item -LiteralPath $skillSource -Destination $skillTarget -Recurse -Force

Write-Output "WorkBuddy Skill 已安装：$skillTarget"
Write-Output "产品运行文件已安装：$pluginTarget"
if ($Initialize) { & (Join-Path $pluginTarget 'scripts\initialize.ps1') }
else { Write-Output '下一步：在 WorkBuddy 中说“初始化我的个人数字助理”。' }
