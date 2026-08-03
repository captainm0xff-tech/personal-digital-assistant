[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Contact,
    [Parameter(Mandatory)][ValidateSet('incoming','outgoing')][string]$Direction,
    [Parameter(Mandatory)][string]$Content,
    [string]$StableContactId,
    [string]$Channel,
    [string]$ConversationId,
    [string]$MessageId,
    [string]$FollowupId,
    [string]$DataRoot
)

$ErrorActionPreference='Stop'
$pluginRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $pluginRoot 'runtime\store.ps1')
$root=Get-PdaDataRoot $DataRoot
$store=Read-PdaStore $root
$event=[ordered]@{
    eventId=[guid]::NewGuid().ToString('N'); time=[DateTime]::UtcNow.ToString('o'); channel=$Channel
    conversationId=$ConversationId; messageId=$MessageId; contact=$Contact; contactId=$StableContactId
    direction=$Direction; content=$Content; followupId=$FollowupId
}
$ledger=Join-Path $root '审计\message-events.ndjson'
($event|ConvertTo-Json -Compress) | Add-Content -LiteralPath $ledger -Encoding UTF8
$contactDoc=Append-PdaContactMessage -Contact $Contact -Direction $Direction -Content $Content -StableId $StableContactId -DataRoot $root
if($FollowupId){
    $item=@($store.followups|Where-Object id -eq $FollowupId)[0]
    if($item){$doc=Write-PdaFollowupDocument $item $root; @("## $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) · 对话记录",'',"- 联系人：$Contact", "- 方向：$Direction",'', $Content,'')|Add-Content -LiteralPath $doc -Encoding UTF8}
}
Write-Output $contactDoc
