[CmdletBinding()]
param([string]$DataRoot, [int]$Port = 17680)

$ErrorActionPreference = 'Stop'
$pluginRoot = Split-Path $PSScriptRoot -Parent
$root = if($DataRoot){[IO.Path]::GetFullPath($DataRoot)}else{Join-Path $env:LOCALAPPDATA 'PersonalDigitalAssistant'}
if(-not (Test-Path -LiteralPath (Join-Path $root 'store.json'))){ & (Join-Path $PSScriptRoot 'initialize.ps1') -DataRoot $root }
$url = "http://127.0.0.1:$Port/"
$running = $false
try { $result=Invoke-RestMethod -Uri ($url+'api/health') -TimeoutSec 1; $running=[bool]$result.ok } catch {}
if(-not $running){
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $pluginRoot 'runtime\server.ps1'),'-DataRoot',$root,'-Port',$Port)
    Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Hidden | Out-Null
    $deadline=(Get-Date).AddSeconds(8)
    do { Start-Sleep -Milliseconds 200; try{$result=Invoke-RestMethod -Uri ($url+'api/health') -TimeoutSec 1; $running=[bool]$result.ok}catch{} } while(-not $running -and (Get-Date) -lt $deadline)
}
if(-not $running){throw '管理台启动失败，请运行 diagnose.ps1 检查。'}
Start-Process $url | Out-Null
Write-Output "管理台已打开：$url"
