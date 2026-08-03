[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$WorkBuddyHome = (Join-Path $env:USERPROFILE '.workbuddy'),
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'PersonalDigitalAssistant'),
    [switch]$RemoveUserData
)

$storePath = Join-Path $DataRoot 'store.json'
if(Test-Path -LiteralPath $storePath){
    try{
        $store=Get-Content -LiteralPath $storePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $taskName='PersonalDigitalAssistant-Bridge-'+$store.instanceId.Substring(0,8)
        $digestTask='PersonalDigitalAssistant-Digest-'+$store.instanceId.Substring(0,8)
        foreach($name in @($taskName,$digestTask)){
            if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){
                Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName $name -Confirm:$false
            }
        }
    }catch{Write-Warning "后台任务清理未完成：$($_.Exception.Message)"}
}
$targets = @(
    (Join-Path $WorkBuddyHome 'plugins\personal-digital-assistant'),
    (Join-Path $WorkBuddyHome 'skills\personal-digital-assistant')
)
foreach ($target in $targets) {
    if ((Test-Path -LiteralPath $target) -and $PSCmdlet.ShouldProcess($target, '移除个人助理程序文件')) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}
if ($RemoveUserData -and (Test-Path -LiteralPath $DataRoot) -and $PSCmdlet.ShouldProcess($DataRoot, '永久移除个人助理用户数据')) {
    $resolvedData = [IO.Path]::GetFullPath($DataRoot).TrimEnd('\')
    $forbidden = @(
        [IO.Path]::GetPathRoot($resolvedData).TrimEnd('\'),
        [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\'),
        [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')
    )
    if ($forbidden -contains $resolvedData) { throw "拒绝删除过宽的数据目录：$resolvedData" }
    Remove-Item -LiteralPath $resolvedData -Recurse -Force
    if ($store -and $store.instanceId) {
        $secretRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'PersonalDigitalAssistantSecrets') $store.instanceId
        if (Test-Path -LiteralPath $secretRoot) { Remove-Item -LiteralPath $secretRoot -Recurse -Force }
    }
}
Write-Output $(if($RemoveUserData){'程序和用户数据已移除。'}else{'程序已移除，用户数据已保留。'})
