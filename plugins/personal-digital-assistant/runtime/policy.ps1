Set-StrictMode -Version Latest

function Test-PdaTruthy {
    param($Value)
    return $Value -eq $true
}

function Get-PdaPolicyDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Event,
        [Parameter(Mandatory)]$Store
    )

    $required = @('tenant_id','channel','event_id','conversation_id','conversation_type','sender_id','timestamp','message_type')
    $missing = @($required | Where-Object { $null -eq $Event.PSObject.Properties[$_] -or [string]::IsNullOrWhiteSpace([string]$Event.$_) })
    if ($missing.Count) {
        return [pscustomobject]@{ action='block'; reason="消息信封缺少字段：$($missing -join ', ')"; event_id=$Event.event_id }
    }

    if (-not (Test-PdaTruthy $Event.recipient_verified) -or -not (Test-PdaTruthy $Event.safe_to_reply)) {
        return [pscustomobject]@{ action='block'; reason='身份、收件人或安全性未通过验证'; event_id=$Event.event_id }
    }

    $text = [string]$Event.text_or_caption
    $phrases = @($Store.config.escalationPhrases | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $requestedHuman = @($phrases | Where-Object { $text.IndexOf([string]$_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0
    if ($requestedHuman) {
        return [pscustomobject]@{ action='escalate'; reason='对方明确要求主人或真人介入'; event_id=$Event.event_id }
    }

    $isGroup = [string]$Event.conversation_type -eq 'group'
    if ($isGroup -and -not (Test-PdaTruthy $Event.explicitly_addressed)) {
        return [pscustomobject]@{ action='record_only'; reason='群消息未明确点名助理或主人'; event_id=$Event.event_id }
    }

    $channel = [string]$Event.channel
    $senderId = [string]$Event.sender_id
    $whitelisted = @($Store.whitelist | Where-Object {
        ([string]$_.identity -eq $senderId) -and
        ([string]::IsNullOrWhiteSpace([string]$_.channel) -or [string]$_.channel -eq $channel)
    }).Count -gt 0
    if (-not $whitelisted) {
        return [pscustomobject]@{ action='record_only'; reason='发送者不在当前租户白名单'; event_id=$Event.event_id }
    }

    if (-not (Test-PdaTruthy $Event.answer_supported)) {
        return [pscustomobject]@{ action='escalate'; reason='允许使用的知识不足以可靠回答'; event_id=$Event.event_id }
    }

    if (-not (Test-PdaTruthy $Store.config.autoSendEnabled)) {
        return [pscustomobject]@{ action='approval_required'; reason='自动外发未启用'; event_id=$Event.event_id }
    }

    return [pscustomobject]@{ action='auto_reply'; reason='白名单、安全、知识可靠且自动外发已启用'; event_id=$Event.event_id }
}
