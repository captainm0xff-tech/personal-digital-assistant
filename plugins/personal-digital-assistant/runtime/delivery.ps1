Set-StrictMode -Version Latest

function Get-PdaMessageId {
    param($Value)
    if ($null -eq $Value) { return '' }
    foreach ($name in @('messageId','message_id','openMessageId','open_message_id')) {
        $property = $Value.PSObject.Properties[$name]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }
    foreach ($property in @($Value.PSObject.Properties)) {
        if ($property.Value -is [pscustomobject] -or $property.Value -is [Collections.IDictionary]) {
            $nested = Get-PdaMessageId $property.Value
            if ($nested) { return $nested }
        }
    }
    return ''
}

function Invoke-PdaVerifiedSend {
    <#
    Adapter-facing delivery guard. SendAction receives (idempotencyKey, content),
    VerifyAction receives (content, idempotencyKey). A transport acknowledgement
    without a message id is not treated as delivery until the conversation confirms it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][scriptblock]$SendAction,
        [Parameter(Mandatory)][scriptblock]$VerifyAction,
        [string]$IdempotencyKey = ([guid]::NewGuid().ToString()),
        [ValidateRange(1, 3)][int]$MaxAttempts = 2,
        [ValidateRange(0, 10000)][int]$VerificationDelayMs = 1000
    )

    $lastError = $null
    foreach ($attempt in 1..$MaxAttempts) {
        $response = $null
        try {
            $response = & $SendAction $IdempotencyKey $Content
            $messageId = Get-PdaMessageId $response
            if ($messageId) {
                return [pscustomobject]@{ confirmed=$true; messageId=$messageId; attempts=$attempt; idempotencyKey=$IdempotencyKey }
            }
        } catch {
            $lastError = $_
        }

        if ($VerificationDelayMs -gt 0) { Start-Sleep -Milliseconds $VerificationDelayMs }
        try {
            $verified = & $VerifyAction $Content $IdempotencyKey
            $messageId = Get-PdaMessageId $verified
            if ($messageId -or $verified -eq $true) {
                return [pscustomobject]@{ confirmed=$true; messageId=$messageId; attempts=$attempt; idempotencyKey=$IdempotencyKey }
            }
        } catch {
            $lastError = $_
        }
    }

    $detail = if ($lastError) { $lastError.Exception.Message } else { 'Transport acknowledged the request, but conversation delivery was not confirmed.' }
    throw "Message delivery failed: $detail"
}
