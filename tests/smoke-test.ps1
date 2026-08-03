[CmdletBinding()]
param([string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($RepositoryRoot)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('pda-smoke-' + [guid]::NewGuid().ToString('N'))
$dataRoot = Join-Path $testRoot 'data'
$server = $null
$port = Get-Random -Minimum 21000 -Maximum 39000

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $plugin = Join-Path $root 'plugins\personal-digital-assistant'
    & (Join-Path $plugin 'scripts\initialize.ps1') -DataRoot $dataRoot -OwnerName '测试用户'

    $storePath = Join-Path $dataRoot 'store.json'
    $store = Get-Content -LiteralPath $storePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($store.config.autoSendEnabled -ne $false) { throw '自动外发必须默认关闭。' }
    if (@($store.whitelist).Count -ne 0) { throw '新实例白名单必须为空。' }

    $powershell = (Get-Process -Id $PID).Path
    $serverScript = Join-Path $plugin 'runtime\server.ps1'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$serverScript`" -DataRoot `"$dataRoot`" -Port $port"
    $server = Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru

    $base = "http://127.0.0.1:$port"
    $ready = $false
    foreach ($attempt in 1..40) {
        try { $health = Invoke-RestMethod -Uri "$base/api/health" -TimeoutSec 1; if ($health.ok) { $ready = $true; break } }
        catch { Start-Sleep -Milliseconds 100 }
    }
    if (-not $ready) { throw '管理台服务未能启动。' }

    $headers = @{ 'Content-Type'='application/json; charset=utf-8' }
    $white = Invoke-RestMethod -Uri "$base/api/whitelist" -Method Post -Headers $headers -Body (@{name='测试联系人';channel='dingtalk';identity='user-demo'} | ConvertTo-Json)
    Invoke-RestMethod -Uri "$base/api/tasks" -Method Post -Headers $headers -Body (@{title='测试待办';due='2026-08-10'} | ConvertTo-Json) | Out-Null
    Invoke-RestMethod -Uri "$base/api/followups" -Method Post -Headers $headers -Body (@{title='测试跟进';target='测试联系人';method='平台私聊';cycle='每天';rule='最多提醒一次'} | ConvertTo-Json) | Out-Null

    $store = Get-Content -LiteralPath $storePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $store.config.autoSendEnabled = $true
    $store | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $storePath -Encoding UTF8

    $eventPath = Join-Path $testRoot 'event.json'
    $event = [ordered]@{
        tenant_id='tenant-demo'; channel='dingtalk'; event_id='evt-demo-001'; conversation_id='conversation-demo'
        conversation_type='direct'; sender_id='user-demo'; sender_display_name='测试联系人'
        timestamp='2026-08-03T20:00:00+08:00'; message_type='text'; text_or_caption='请确认安排'
        mentions=@(); reply_to_message_id=$null; attachments=@(); explicitly_addressed=$true
        safe_to_reply=$true; answer_supported=$true; recipient_verified=$true
    }
    $event | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $eventPath -Encoding UTF8
    $decision = & (Join-Path $plugin 'scripts\evaluate-message.ps1') -EventPath $eventPath -DataRoot $dataRoot | ConvertFrom-Json
    if ($decision.action -ne 'auto_reply') { throw "白名单策略判断错误：$($decision.action)" }

    $event.sender_id = 'outside-user'
    $event | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $eventPath -Encoding UTF8
    $decision = & (Join-Path $plugin 'scripts\evaluate-message.ps1') -EventPath $eventPath -DataRoot $dataRoot | ConvertFrom-Json
    if ($decision.action -ne 'record_only') { throw "白名单外策略判断错误：$($decision.action)" }

    Write-Output '离线冒烟测试通过。'
} finally {
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolvedTest = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTest)) {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    }
}
