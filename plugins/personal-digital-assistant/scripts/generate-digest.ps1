[CmdletBinding()]
param([string]$DataRoot, [datetime]$Date = (Get-Date))

$ErrorActionPreference='Stop'
$pluginRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $pluginRoot 'runtime\store.ps1')
$root=Get-PdaDataRoot $DataRoot
$store=Read-PdaStore $root
$day=$Date.ToString('yyyy-MM-dd')
$pendingTasks=@($store.tasks | Where-Object status -ne '已完成')
$activeFollowups=@($store.followups | Where-Object status -ne '已关闭')
$todayAudit=@($store.audit | Where-Object { try{([datetime]$_.time).ToLocalTime().ToString('yyyy-MM-dd') -eq $day}catch{$false} } | Sort-Object time)
$lines=@("# $day 工作日报",'',"- 生成时间：$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))",'')
$lines += @('## 今日变化','')
if($todayAudit){$lines += $todayAudit | ForEach-Object {"- $(([datetime]$_.time).ToLocalTime().ToString('HH:mm')) · $($_.detail)"}}else{$lines+='- 今日暂无已记录变化。'}
$lines += @('','## 未完成待办','')
if($pendingTasks){$lines += $pendingTasks | ForEach-Object {"- $($_.title)（截止：$(if($_.due){$_.due}else{'未设置'})）"}}else{$lines+='- 无'}
$lines += @('','## 进行中跟进','')
if($activeFollowups){$lines += $activeFollowups | ForEach-Object {"- $($_.title) → $($_.target)；方式：$($_.method)；周期：$($_.cycle)"}}else{$lines+='- 无'}
$lines += @('','## 风险与人工确认','')
$risk=@($todayAudit | Where-Object {$_.action -match 'blocked|escalat|failed'})
if($risk){$lines += $risk | ForEach-Object {"- $($_.detail)"}}else{$lines+='- 暂无已记录风险。'}
$path=Join-Path $root "日报\$day.md"
$lines | Set-Content -LiteralPath $path -Encoding UTF8
$store.audit=@([pscustomobject]@{id=[guid]::NewGuid().ToString('N');time=[DateTime]::UtcNow.ToString('o');action='digest_generated';detail="生成日报：$day"})+@($store.audit)|Select-Object -First 200
Write-PdaStore $store $root
Write-Output $path
