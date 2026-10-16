# SPDX-License-Identifier: Apache-2.0
<#
.SYNOPSIS
    Deploy all three Tazama stacks in sequence.

.DESCRIPTION
    Runs deploy-core.ps1, deploy-extensions.ps1, and deploy-biar.ps1 in
    order.  Each script waits for its server's bootstrap to complete before
    proceeding, so this script is safe to run immediately after `tofu apply`.

    Secrets come from SSM /tazama/* (rendered into each group's secrets.env
    by the individual deploy scripts); there is no password parameter.

    Run from infra/aws/scripts/ or anywhere - paths are resolved relative
    to this script's location.

.EXAMPLE
    .\deploy.ps1
    .\deploy.ps1 -NoPull
#>

[CmdletBinding()]
param(
    [switch]$NoPull
)

$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host '  Tazama Full-Stack Deploy'                            -ForegroundColor Cyan
Write-Host '=====================================================' -ForegroundColor Cyan

$pullArgs  = if ($NoPull)  { @('-NoPull') }              else { @() }

& "$PSScriptRoot\deploy-core.ps1"       @pullArgs
& "$PSScriptRoot\deploy-extensions.ps1" @pullArgs
& "$PSScriptRoot\deploy-biar.ps1"       @pullArgs

Write-Host ''
Write-Host '=====================================================' -ForegroundColor Green
Write-Host '  All stacks deployed successfully.'                   -ForegroundColor Green
Write-Host '=====================================================' -ForegroundColor Green
