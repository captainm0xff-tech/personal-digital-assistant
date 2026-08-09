[CmdletBinding()]
param(
    [string]$DataRoot,
    [int]$Port = 17680
)

$ErrorActionPreference = 'Stop'
$pluginRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'store.ps1')
. (Join-Path $PSScriptRoot 'console-api.ps1')
$root = Get-PdaDataRoot $DataRoot
if (-not (Test-Path -LiteralPath (Join-Path $root 'store.json'))) {
    & (Join-Path $pluginRoot 'scripts\initialize.ps1') -DataRoot $root
}

function Send-Response {
    param($Context, [int]$Status, [string]$Content, [string]$ContentType = 'application/json; charset=utf-8')
    $bytes = [Text.Encoding]::UTF8.GetBytes($Content)
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Send-Json { param($Context, [int]$Status, $Value) Send-Response $Context $Status ($Value | ConvertTo-Json -Depth 12) }
function Read-JsonBody {
    param($Request)
    $reader = [IO.StreamReader]::new($Request.InputStream, $Request.ContentEncoding)
    $text = $reader.ReadToEnd()
    $reader.Dispose()
    if (-not $text) { return [pscustomobject]@{} }
    return $text | ConvertFrom-Json
}
function New-ItemId { return [guid]::NewGuid().ToString('N') }

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
$pid | Set-Content -LiteralPath (Join-Path $root '运行日志\console.pid') -Encoding ASCII

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            $request = $context.Request
            $path = $request.Url.AbsolutePath
            $method = $request.HttpMethod.ToUpperInvariant()

            if ($method -eq 'GET' -and $path -eq '/api/health') {
                Send-Json $context 200 @{ ok=$true; dataRoot=$root }
                continue
            }
            if ($method -eq 'GET' -and $path -eq '/favicon.ico') {
                Send-Response $context 204 '' 'image/x-icon'
                continue
            }
            if ($method -eq 'GET' -and $path -eq '/api/state') {
                $state = Read-PdaStore $root
                Send-Json $context 200 $state
                continue
            }
            if ($method -eq 'GET' -and $path -eq '/api/snapshot') {
                Send-Json $context 200 (Get-PdaConsoleSnapshot -DataRoot $root)
                continue
            }
            if ($method -eq 'GET' -and $path -eq '/api/knowledge') {
                $query = [Uri]::UnescapeDataString([string]$request.QueryString['q'])
                Send-Json $context 200 @{ results=@(Search-PdaKnowledge -Query $query -DataRoot $root) }
                continue
            }
            if ($method -eq 'POST' -and $path -eq '/api/action') {
                $body = Read-JsonBody $request
                Send-Json $context 200 (Invoke-PdaConsoleAction -Body $body -DataRoot $root)
                continue
            }
            if ($method -eq 'POST' -and $path -eq '/api/config') {
                $body = Read-JsonBody $request
                $store = Read-PdaStore $root
                foreach ($name in @('ownerName','timeZone','digestTime','aiLabelEnabled','autoSendEnabled')) {
                    if ($null -ne $body.PSObject.Properties[$name]) { $store.config.$name = $body.$name }
                }
                Add-PdaAudit $store 'config_updated' '通过管理台更新配置'
                Write-PdaStore $store $root
                Send-Json $context 200 $store
                continue
            }
            if ($method -eq 'POST' -and $path -eq '/api/whitelist') {
                $body = Read-JsonBody $request
                if (-not $body.name) { throw '联系人姓名不能为空' }
                $store = Read-PdaStore $root
                $item = [pscustomobject]@{ id=New-ItemId; name=$body.name; channel=$body.channel; identity=$body.identity; createdAt=[DateTime]::UtcNow.ToString('o') }
                $store.whitelist = @($store.whitelist) + $item
                Add-PdaAudit $store 'whitelist_added' "添加白名单：$($item.name)"
                Write-PdaStore $store $root
                Send-Json $context 201 $item
                continue
            }
            if ($method -eq 'DELETE' -and $path -match '^/api/whitelist/([a-f0-9]+)$') {
                $id = $Matches[1]; $store = Read-PdaStore $root
                $store.whitelist = @($store.whitelist | Where-Object id -ne $id)
                Add-PdaAudit $store 'whitelist_removed' "移除白名单：$id"
                Write-PdaStore $store $root
                Send-Json $context 200 @{ ok=$true }
                continue
            }
            if ($method -eq 'POST' -and $path -eq '/api/tasks') {
                $body = Read-JsonBody $request
                if (-not $body.title) { throw '待办标题不能为空' }
                $store = Read-PdaStore $root
                $item = [pscustomobject]@{ id=New-ItemId; title=$body.title; due=$body.due; status='待办'; createdAt=[DateTime]::UtcNow.ToString('o') }
                $store.tasks = @($store.tasks) + $item
                $safe = ConvertTo-PdaFileName $item.title
                @("# $($item.title)",'',"- 编号：$($item.id)","- 截止：$($item.due)",'- 状态：待办','') | Set-Content -LiteralPath (Join-Path $root "日常工作（待办）\$safe-$($item.id.Substring(0,8)).md") -Encoding UTF8
                Add-PdaAudit $store 'task_added' "新增待办：$($item.title)"
                Write-PdaStore $store $root
                Send-Json $context 201 $item
                continue
            }
            if ($method -eq 'PUT' -and $path -match '^/api/tasks/([a-f0-9]+)$') {
                $id=$Matches[1]; $body=Read-JsonBody $request; $store=Read-PdaStore $root
                $item=@($store.tasks | Where-Object id -eq $id)[0]; if(-not $item){throw '待办不存在'}
                foreach($name in @('title','due','status')){if($null -ne $body.PSObject.Properties[$name]){$item.$name=$body.$name}}
                Add-PdaAudit $store 'task_updated' "更新待办：$($item.title)"; Write-PdaStore $store $root; Send-Json $context 200 $item
                continue
            }
            if ($method -eq 'DELETE' -and $path -match '^/api/tasks/([a-f0-9]+)$') {
                $id=$Matches[1]; $store=Read-PdaStore $root; $store.tasks=@($store.tasks | Where-Object id -ne $id)
                Add-PdaAudit $store 'task_removed' "删除待办：$id"; Write-PdaStore $store $root; Send-Json $context 200 @{ok=$true}
                continue
            }
            if ($method -eq 'POST' -and $path -eq '/api/followups') {
                $body = Read-JsonBody $request
                if (-not $body.title -or -not $body.target) { throw '跟进标题和跟进对象不能为空' }
                $store = Read-PdaStore $root
                $item = [pscustomobject]@{ id=New-ItemId; title=$body.title; target=$body.target; method=$body.method; cycle=$body.cycle; rule=$body.rule; status='进行中'; createdAt=[DateTime]::UtcNow.ToString('o') }
                $store.followups = @($store.followups) + $item
                $document = Write-PdaFollowupDocument $item $root
                Add-PdaAudit $store 'followup_added' "新增跟进：$($item.title) -> $($item.target)"
                Write-PdaStore $store $root
                Send-Json $context 201 @{item=$item; document=$document}
                continue
            }
            if ($method -eq 'PUT' -and $path -match '^/api/followups/([a-f0-9]+)$') {
                $id=$Matches[1]; $body=Read-JsonBody $request; $store=Read-PdaStore $root
                $item=@($store.followups | Where-Object id -eq $id)[0]; if(-not $item){throw '跟进任务不存在'}
                foreach($name in @('title','target','method','cycle','rule','status')){if($null -ne $body.PSObject.Properties[$name]){$item.$name=$body.$name}}
                $doc=Write-PdaFollowupDocument $item $root
                @("## $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) · 配置更新",'',"- 跟进对象：$($item.target)","- 跟进方式：$($item.method)","- 跟进周期：$($item.cycle)","- 状态：$($item.status)","- 补充规则：$($item.rule)",'') | Add-Content -LiteralPath $doc -Encoding UTF8
                Add-PdaAudit $store 'followup_updated' "更新跟进：$($item.title)"; Write-PdaStore $store $root; Send-Json $context 200 $item
                continue
            }
            if ($method -eq 'DELETE' -and $path -match '^/api/followups/([a-f0-9]+)$') {
                $id=$Matches[1]; $store=Read-PdaStore $root; $store.followups=@($store.followups | Where-Object id -ne $id)
                Add-PdaAudit $store 'followup_removed' "删除跟进记录：$id（过程文档保留）"; Write-PdaStore $store $root; Send-Json $context 200 @{ok=$true}
                continue
            }

            $static = switch ($path) {
                '/' { 'index.html' }
                '/app.js' { 'app.js' }
                '/app.css' { 'styles.css' }
                '/styles.css' { 'styles.css' }
                default { $null }
            }
            if ($method -eq 'GET' -and $static) {
                $file = Join-Path $pluginRoot "console\$static"
                $type = if($static.EndsWith('.js')){'application/javascript; charset=utf-8'}elseif($static.EndsWith('.css')){'text/css; charset=utf-8'}else{'text/html; charset=utf-8'}
                Send-Response $context 200 (Get-Content -LiteralPath $file -Raw -Encoding UTF8) $type
                continue
            }
            Send-Json $context 404 @{ error='not_found' }
        } catch {
            Send-Json $context 400 @{ error=$_.Exception.Message }
        }
    }
} finally {
    $listener.Stop(); $listener.Close()
}
