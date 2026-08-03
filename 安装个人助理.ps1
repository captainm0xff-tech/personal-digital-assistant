[CmdletBinding()]
param([string]$OwnerName = $env:USERNAME)

$ErrorActionPreference='Stop'
$plugin=Join-Path $PSScriptRoot 'plugins\personal-digital-assistant'
& (Join-Path $plugin 'scripts\install.ps1')
$installed=Join-Path $env:USERPROFILE '.workbuddy\plugins\personal-digital-assistant'
& (Join-Path $installed 'scripts\initialize.ps1') -OwnerName $OwnerName
Write-Output '安装完成。请重启 WorkBuddy，然后说“打开个人助理管理台”。'
