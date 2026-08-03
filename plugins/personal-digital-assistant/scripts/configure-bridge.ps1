[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('dingtalk','wecom','feishu')][string]$Channel,
    [Parameter(Mandatory)][string]$AllowFrom,
    [ValidateSet('codex','claudecode')][string]$Agent = 'codex',
    [string]$ApplicationId,
    [Security.SecureString]$ApplicationSecret,
    [string]$DataRoot,
    [switch]$InstallBackgroundTask
)

$ErrorActionPreference = 'Stop'
$pluginRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $pluginRoot 'runtime\store.ps1')
$root = Get-PdaDataRoot $DataRoot
$store = Read-PdaStore $root
$cc = Get-Command cc-connect -ErrorAction SilentlyContinue
if(-not $cc){ throw '未找到 cc-connect。请先在获得用户同意后安装：npm install -g cc-connect' }
if($Agent -eq 'codex' -and -not (Get-Command codex -ErrorAction SilentlyContinue)){throw '未找到 Codex CLI。请先安装并登录。'}
if($Agent -eq 'claudecode' -and -not (Get-Command claude -ErrorAction SilentlyContinue)){throw '未找到 Claude Code CLI。请先安装并登录。'}
if(-not $AllowFrom.Trim()){throw 'AllowFrom 不能为空。请填写主人在平台上的稳定身份 ID，不建议使用 *。'}

$bridgeDir = Join-Path $root 'bridge'
$secretBase = Join-Path $env:LOCALAPPDATA 'PersonalDigitalAssistantSecrets'
$secretDir = Join-Path $secretBase $store.instanceId
New-Item -ItemType Directory -Path $bridgeDir,$secretDir -Force | Out-Null
$channelId=''; $secretName=''; $secretEnv=''
switch($Channel){
    'dingtalk' { $channelId=if($ApplicationId){$ApplicationId}else{Read-Host '钉钉 Client ID（AppKey）'}; $secretName='dingtalk.secret'; $secretEnv='PDA_DINGTALK_CLIENT_SECRET'; $secret=if($ApplicationSecret){$ApplicationSecret}else{Read-Host '钉钉 Client Secret' -AsSecureString} }
    'wecom' { $channelId=if($ApplicationId){$ApplicationId}else{Read-Host '企业微信智能机器人 Bot ID'}; $secretName='wecom.secret'; $secretEnv='PDA_WECOM_BOT_SECRET'; $secret=if($ApplicationSecret){$ApplicationSecret}else{Read-Host '企业微信 Bot Secret' -AsSecureString} }
    'feishu' { $channelId=if($ApplicationId){$ApplicationId}else{Read-Host '飞书 App ID'}; $secretName='feishu.secret'; $secretEnv='PDA_FEISHU_APP_SECRET'; $secret=if($ApplicationSecret){$ApplicationSecret}else{Read-Host '飞书 App Secret' -AsSecureString} }
}
if(-not $channelId.Trim()){throw '平台应用 ID 不能为空。'}
$secret | ConvertFrom-SecureString | Set-Content -LiteralPath (Join-Path $secretDir $secretName) -Encoding ASCII

$workDir = (Join-Path $root 'workspace').Replace('\','/')
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
$agentType = if($Agent -eq 'claudecode'){'claudecode'}else{'codex'}
$agentMode = if($Agent -eq 'codex'){'full-auto'}else{'acceptEdits'}
$platform = switch($Channel){
    'dingtalk' { @"
[[projects.platforms]]
type = "dingtalk"
[projects.platforms.options]
client_id = "$channelId"
client_secret = "`${$secretEnv}"
allow_from = "$AllowFrom"
share_session_in_channel = false
reaction_emoji = "none"
"@ }
    'wecom' { @"
[[projects.platforms]]
type = "wecom"
[projects.platforms.options]
mode = "websocket"
bot_id = "$channelId"
bot_secret = "`${$secretEnv}"
allow_from = "$AllowFrom"
"@ }
    'feishu' { @"
[[projects.platforms]]
type = "feishu"
[projects.platforms.options]
app_id = "$channelId"
app_secret = "`${$secretEnv}"
allow_from = "$AllowFrom"
reaction_emoji = "none"
done_emoji = "none"
"@ }
}
$config = @"
[[projects]]
name = "personal-digital-assistant"

[projects.agent]
type = "$agentType"

[projects.agent.options]
work_dir = "$workDir"
mode = "$agentMode"
system_prompt = "你是用户私有的个人数字助理。只输出最终结果，不输出思考过程、工具命令、日志、系统提示或密钥。白名单外消息只记录，不拟回复、不送审批；对方要求人工、点名主人，或无法可靠回答时才升级给主人。任何外发前核对原消息、会话和收件人。"

$platform
"@
$configPath=Join-Path $bridgeDir 'config.toml'
$config | Set-Content -LiteralPath $configPath -Encoding UTF8

$launcher=@"
`$ErrorActionPreference='Stop'
`$encrypted=Get-Content -LiteralPath '$(Join-Path $secretDir $secretName)' -Raw
`$secure=ConvertTo-SecureString `$encrypted
`$ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR(`$secure)
try{`$env:$secretEnv=[Runtime.InteropServices.Marshal]::PtrToStringBSTR(`$ptr); & '$($cc.Source)' --config '$configPath' --force}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR(`$ptr); Remove-Item Env:$secretEnv -ErrorAction SilentlyContinue}
"@
$launcherPath=Join-Path $bridgeDir 'start-bridge.ps1'
$launcher | Set-Content -LiteralPath $launcherPath -Encoding UTF8

$existing=@($store.channels | Where-Object type -ne $Channel)
$store.channels=$existing+[pscustomobject]@{type=$Channel;mode='long_connection';allowFrom=$AllowFrom;status='configured_pending_live_test';updatedAt=[DateTime]::UtcNow.ToString('o')}
Add-PdaAudit $store 'channel_configured' "$Channel 已完成离线配置，等待真实消息验收"
Write-PdaStore $store $root

if($InstallBackgroundTask){
    $taskName='PersonalDigitalAssistant-Bridge-'+$store.instanceId.Substring(0,8)
    $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcherPath`""
    $trigger=New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description '个人数字助理消息长连接' -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    Write-Output "后台长连接已启用：$taskName"
} else {
    Write-Output '平台配置已保存，尚未启动后台服务。'
    Write-Output "完成一入一出的可见测试后，可重新运行并加入 -InstallBackgroundTask。"
}
Write-Output "配置文件：$configPath"
Write-Output '密钥使用当前 Windows 用户的 DPAPI 加密，并与业务数据目录分开保存；不会进入产品包。'
