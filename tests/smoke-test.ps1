[CmdletBinding()]
param([string]$RepositoryRoot)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = Split-Path $PSScriptRoot -Parent }
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
    $page = Invoke-WebRequest -Uri $base -UseBasicParsing
    foreach ($label in @('单项跟进','项目','知识库','白名单','沟通渠道','系统')) {
        if ($page.Content -notmatch $label) { throw "完整版控制台缺少入口：$label" }
    }
    $snapshot = Invoke-RestMethod -Uri "$base/api/snapshot"
    if ($null -eq $snapshot.permission_catalog -or $null -eq $snapshot.knowledge_permissions) {
        throw '完整版控制台快照缺少权限管理数据。'
    }
    $profileBody = @{
        action='instance-initialize';owner_name='Test Owner';workspace_name='Test Workspace'
        timezone='Asia/Shanghai';daily_digest_time='20:00'
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/action" -Method Post -Headers $headers -Body $profileBody | Out-Null
    $permissionBody = @{
        action='knowledge-permission-bulk';scope_type='all';scope_value='';visibility='internal_shareable'
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/action" -Method Post -Headers $headers -Body $permissionBody | Out-Null

    $white = Invoke-RestMethod -Uri "$base/api/whitelist" -Method Post -Headers $headers -Body (@{name='测试联系人';channel='dingtalk';identity='user-demo'} | ConvertTo-Json)
    Invoke-RestMethod -Uri "$base/api/tasks" -Method Post -Headers $headers -Body (@{title='测试待办';due='2026-08-10'} | ConvertTo-Json) | Out-Null
    Invoke-RestMethod -Uri "$base/api/followups" -Method Post -Headers $headers -Body (@{title='测试跟进';target='测试联系人';method='平台私聊';cycle='每天';rule='最多提醒一次'} | ConvertTo-Json) | Out-Null

    $snapshot = Invoke-RestMethod -Uri "$base/api/snapshot"
    if ($snapshot.profile.workspace_name -ne 'Test Workspace') { throw '新版控制台基础信息没有保存。' }
    if (@($snapshot.followups).Count -ne 1 -or @($snapshot.whitelist).Count -ne 1) {
        throw '新版控制台没有正确读取任务或白名单。'
    }
    $channelBody = @{
        action='channel-bind';channel_type='wecom';account_id='corp-demo';secret='synthetic-secret-value'
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/api/action" -Method Post -Headers $headers -Body $channelBody | Out-Null
    $rawStore = Get-Content -LiteralPath $storePath -Raw -Encoding UTF8
    if ($rawStore -match 'synthetic-secret-value') { throw '渠道密钥被明文写入用户数据。' }
    $snapshot = Invoke-RestMethod -Uri "$base/api/snapshot"
    $channel = @($snapshot.channels | Where-Object channel_type -eq 'wecom')[0]
    if (-not $channel -or $channel.status -ne 'configured') { throw '沟通渠道配置状态错误。' }
    Invoke-RestMethod -Uri "$base/api/action" -Method Post -Headers $headers -Body (@{action='channel-unbind';id=$channel.id} | ConvertTo-Json) | Out-Null

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

    . (Join-Path $plugin 'runtime\retrieval.ps1')
    $evidence = @(
        [pscustomobject]@{source='project-overview';title='Q05 项目介绍';heading='项目概览';content='产品功能介绍';score=100},
        [pscustomobject]@{source='project-schedule';title='Q05 开发排期';heading='阶段表';content='EVT 第3-10周；DVT 第11-15周；PVT 第15-18周';score=70}
    )
    $selected = @(Select-PdaKnowledgeEvidence -Query 'Q05项目排期发我看看' -Candidates $evidence -Limit 2)
    if ($selected[0].source -ne 'project-schedule') { throw '排期证据没有优先返回阶段表。' }

    . (Join-Path $plugin 'runtime\delivery.ps1')
    $sendKeys = [Collections.Generic.List[string]]::new()
    $verifyCount = 0
    $delivery = Invoke-PdaVerifiedSend -Content '测试排期' -VerificationDelayMs 0 `
        -SendAction {
            param($key, $content)
            $sendKeys.Add($key)
            if ($sendKeys.Count -eq 2) { throw 'duplicate idempotency key' }
            return [pscustomobject]@{ success=$true }
        } `
        -VerifyAction {
            param($content, $key)
            $script:verifyCount++
            if ($script:verifyCount -ge 2) { return [pscustomobject]@{ openMessageId='message-confirmed' } }
            return $false
        }
    if (-not $delivery.confirmed -or $delivery.messageId -ne 'message-confirmed') { throw '真实会话送达确认失败。' }
    if ($sendKeys.Count -ne 2 -or $sendKeys[0] -ne $sendKeys[1]) { throw '发送重试没有复用同一幂等键。' }

    Write-Output '离线冒烟测试通过。'
} finally {
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolvedTest = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTest)) {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    }
}
