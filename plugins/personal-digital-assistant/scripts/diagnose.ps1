[CmdletBinding()]
param([string]$DataRoot)

$ErrorActionPreference = 'Stop'
$pluginRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $pluginRoot 'runtime\store.ps1')
$root = Get-PdaDataRoot $DataRoot
$checks = @()
$checks += [pscustomobject]@{ Item='产品文件'; Status=$(if(Test-Path (Join-Path $pluginRoot 'skills\personal-digital-assistant\SKILL.md')){'正常'}else{'缺失'}) }
$checks += [pscustomobject]@{ Item='用户数据'; Status=$(if(Test-Path (Join-Path $root 'store.json')){'正常'}else{'未初始化'}) }
$checks += [pscustomobject]@{ Item='cc-connect'; Status=$(if(Get-Command cc-connect -ErrorAction SilentlyContinue){'已安装'}else{'未安装（仅自动托管需要）'}) }
$checks += [pscustomobject]@{ Item='Codex CLI'; Status=$(if(Get-Command codex -ErrorAction SilentlyContinue){'已安装'}else{'未安装（可选）'}) }
$checks += [pscustomobject]@{ Item='Claude Code'; Status=$(if(Get-Command claude -ErrorAction SilentlyContinue){'已安装'}else{'未安装（可选）'}) }
$checks | Format-Table -AutoSize
