[CmdletBinding()]
param([string]$DataRoot, [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')][string]$At = '20:00')

$ErrorActionPreference='Stop'
$pluginRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $pluginRoot 'runtime\store.ps1')
$root=Get-PdaDataRoot $DataRoot
$store=Read-PdaStore $root
$taskName='PersonalDigitalAssistant-Digest-'+$store.instanceId.Substring(0,8)
$script=Join-Path $PSScriptRoot 'generate-digest.ps1'
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -DataRoot `"$root`""
$trigger=New-ScheduledTaskTrigger -Daily -At $At
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description '个人数字助理每日工作总结' -Force | Out-Null
$store.config.digestTime=$At
Add-PdaAudit $store 'digest_schedule_updated' "日报生成时间设置为 $At"
Write-PdaStore $store $root
Write-Output "日报定时任务已启用：每天 $At，后台隐藏运行。"
Write-Output '默认只生成本地日报。通过沟通平台自动发送需另行绑定控制通道并明确授权。'
