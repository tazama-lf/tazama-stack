#requires -Version 7
# Tests for the AWS pgAdmin server-mode overlay: pgAdmin is reachable through the internet-facing load balancer, so on AWS it
# must run with a login (PGADMIN_CONFIG_SERVER_MODE='True') while the committed local-development defaults stay 'False'.
# Covers Set-ServerEnvOverlays (helpers.ps1) and deploy-extensions.ps1, which resets the checkouts on A and B itself.
# Needs pwsh 7 and bash (Linux, Git Bash or WSL). Run from anywhere: pwsh -NoProfile -File infra/aws/scripts/tests/Test-ServerEnvOverlays.ps1
# The exit code is the number of failed tests.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptsDir = Split-Path -Parent $PSScriptRoot
$repoRoot   = (Resolve-Path (Join-Path $scriptsDir '../../..')).Path
. (Join-Path $scriptsDir 'helpers.ps1')
$realSetRemoteEnvOverlay = ${function:Set-RemoteEnvOverlay}

$Script:Events = [System.Collections.Generic.List[object]]::new()
function Add-Event([string]$Kind, $Id, $Command, $Target, $Content, $File) {
    $Script:Events.Add([pscustomobject]@{ Kind = $Kind; Id = $Id; Command = $Command; Target = $Target; Content = $Content; File = $File })
}

# Replace everything that reaches a server so the logic under test runs offline and records what it would do, in order.
function Invoke-RemoteCommand { param($InstanceId, $Command) Add-Event 'cmd' $InstanceId $Command $null $null $null }
function Set-RemoteEnvOverlay { param($InstanceId, $OverlayFile, $OverlayContent, $RemoteEnvFile) Add-Event 'overlay' $InstanceId $null $RemoteEnvFile $OverlayContent $OverlayFile }
function Set-ServerSecretsEnv { param($InstanceId, $Group, $Server, $ServerLabel) Add-Event 'other' $InstanceId 'secrets' $null $null $null }
function Set-DemoUiOverlay { param($InstanceId, $DemoPublicUrl, $ServerLabel) }
function Set-JupyterHubOidcOverlay { param($InstanceId, $JupyterPublicUrl, $ServerLabel) }
function Set-NifiOidcOverlay { param($InstanceId, $NifiPublicUrl, $ServerLabel) }
function Set-NifiAuthOverlay { param($InstanceId, $TofuOutputs, $ServerLabel) }
function Set-BiarServiceEnvOverlay { param($InstanceId, $TofuOutputs, $ServerLabel) }
function Copy-ToRemote { param($InstanceId, $LocalPath, $RemotePath) }
function Wait-Bootstrap { param($InstanceId, $ServerName) }
function Get-TofuOutputs { @{ ServerA_InstanceId = 'i-A'; ServerB_InstanceId = 'i-B'; ServerC_InstanceId = 'i-C' } }

$tofu = @{ KeycloakHostname = 'kc.example.org'; DemoPublicUrl = 'https://demo.example.org'; JupyterPublicUrl = 'https://jupyter.example.org'; NifiPublicUrl = 'https://nifi.example.org' }
$serverModeLine = "PGADMIN_CONFIG_SERVER_MODE='True'"
$coreSuffix     = 'core/env/core-pgadmin.env'
$extSuffix      = 'extensions/env/extensions-pgadmin.env'

$Script:Failed = 0
function Test-That([string]$Name, [scriptblock]$Condition) {
    $detail = ''
    try { $ok = [bool](& $Condition) } catch { $ok = $false; $detail = $_.Exception.Message }
    if ($ok) { Write-Host "PASS  $Name" }
    else { $Script:Failed++; Write-Host "FAIL  $Name $detail" -ForegroundColor Red }
}

function Get-OverlayLines($Event) {
    $source = if ($Event.File) { Get-Content $Event.File } elseif ($Event.Content) { $Event.Content -split "`n" } else { @() }
    , @($source | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '=' } | ForEach-Object { $_.Trim() })
}
# Overlay events (in order) whose target path ends with $Suffix.
function Get-TargetEvents($Events, [string]$Suffix) { , @($Events | Where-Object { $_.Kind -eq 'overlay' -and $_.Target -like "*/$Suffix" }) }
# Every PGADMIN_CONFIG_SERVER_MODE value those events would write.
function Get-ModeValues($Events, [string]$Suffix) {
    $vals = foreach ($e in (Get-TargetEvents $Events $Suffix)) { Get-OverlayLines $e | Where-Object { $_ -like 'PGADMIN_CONFIG_SERVER_MODE=*' } }
    , @($vals)
}
function Test-ModeIsTrue($Events, [string]$Suffix) {
    $v = Get-ModeValues $Events $Suffix
    $v.Count -ge 1 -and (@($v | Where-Object { $_ -ne $serverModeLine })).Count -eq 0
}
function Get-Overlays([string]$Server, [switch]$SkipExtensionsOverlay) {
    $Script:Events.Clear()
    if ($SkipExtensionsOverlay) { Set-ServerEnvOverlays -Server $Server -InstanceId "i-$Server" -TofuOutputs $tofu -SkipExtensionsOverlay *>$null }
    else { Set-ServerEnvOverlays -Server $Server -InstanceId "i-$Server" -TofuOutputs $tofu *>$null }
    , @($Script:Events)
}
# Runs deploy-extensions.ps1 with the helpers import removed (the stubs above stay in place) and returns the ordered events.
function Get-DeployExtensionsEvents {
    $src = Get-Content (Join-Path $scriptsDir 'deploy-extensions.ps1') -Raw
    $import = '. "$PSScriptRoot\helpers.ps1"'
    if (-not $src.Contains($import)) { throw 'helpers import line not found in deploy-extensions.ps1; update this test' }
    $src = $src.Replace($import, '').Replace('$PSScriptRoot', "'$scriptsDir'")
    $Script:Events.Clear()
    & ([scriptblock]::Create($src)) -NoPull *>$null
    , @($Script:Events)
}
function Get-EventIndex($Events, [scriptblock]$Match) {
    for ($i = 0; $i -lt $Events.Count; $i++) { if (& $Match $Events[$i]) { return $i } }
    -1
}

# --- bash harness: apply overlay events with the REAL Set-RemoteEnvOverlay to given file bytes and read the result back ---
$bash = Get-Command bash -ErrorAction SilentlyContinue
function Invoke-RealOverlays($Events, [byte[]]$Bytes, [int]$Passes = 2) {
    $target = "/tmp/overlay-test-$([guid]::NewGuid().ToString('N')).env"
    $cmds = foreach ($e in $Events) {
        $before = $Script:Events.Count
        $splat = @{ InstanceId = 'i-test'; RemoteEnvFile = $target }
        if ($e.File) { $splat.OverlayFile = $e.File } else { $splat.OverlayContent = $e.Content }
        & $realSetRemoteEnvOverlay @splat
        $c = $Script:Events[$before].Command
        $Script:Events.RemoveRange($before, $Script:Events.Count - $before)
        $c
    }
    $body = (1..$Passes | ForEach-Object { $cmds }) -join "`n"
    $script = "echo $([Convert]::ToBase64String($Bytes)) | base64 -d > $target`n$body`necho ---RESULT---`ncat $target`nrm -f $target`n"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $out = & $bash.Source -c "echo $b64 | base64 -d | bash" 2>$errFile
        if ($LASTEXITCODE -ne 0) { throw "bash exited $LASTEXITCODE; stderr: $(Get-Content $errFile -Raw)" }
    }
    finally { Remove-Item $errFile -Force -ErrorAction SilentlyContinue }
    $lines = @($out | ForEach-Object { "$_".TrimEnd("`r") })
    $i = [array]::IndexOf($lines, '---RESULT---')
    if ($i -lt 0) { throw 'no result marker in the bash output' }
    , @($lines[($i + 1)..($lines.Count - 1)])
}
function Get-CommittedBytes([string]$Rel) {
    [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText((Join-Path $repoRoot $Rel)).Replace("`r`n", "`n"))
}

# --- 1. Set-ServerEnvOverlays: which pgAdmin overlays are applied where -------------------------------
$a     = Get-Overlays 'A'
$aSkip = Get-Overlays 'A' -SkipExtensionsOverlay
$b     = Get-Overlays 'B'
$c     = Get-Overlays 'C'

Test-That 'A: core pgAdmin env is set to server mode (and to nothing else)' { Test-ModeIsTrue $a $coreSuffix }
Test-That 'A with -SkipExtensionsOverlay (deploy-core path): core pgAdmin env is set to server mode' { Test-ModeIsTrue $aSkip $coreSuffix }
Test-That 'A: extensions pgAdmin env is never touched (A runs only the core pgAdmin)' { (Get-TargetEvents $a $extSuffix).Count -eq 0 -and (Get-TargetEvents $aSkip $extSuffix).Count -eq 0 }
Test-That 'B: extensions pgAdmin env is set to server mode (and to nothing else)' { Test-ModeIsTrue $b $extSuffix }
Test-That 'B: core pgAdmin env is never touched' { (Get-TargetEvents $b $coreSuffix).Count -eq 0 }
Test-That 'C: no pgAdmin overlay (no pgAdmin on the biar server)' { (@($c | Where-Object { $_.Target -like '*pgadmin*' })).Count -eq 0 }

# --- 2. deploy-extensions.ps1 resets both checkouts itself, so it must restore the overlay too ------------
$d = Get-DeployExtensionsEvents
foreach ($case in @(@{ Id = 'i-A'; Name = 'A'; Suffix = $coreSuffix; Other = $extSuffix }, @{ Id = 'i-B'; Name = 'B'; Suffix = $extSuffix; Other = $coreSuffix })) {
    $reset = Get-EventIndex $d { param($e) $e.Kind -eq 'cmd' -and $e.Id -eq $case.Id -and $e.Command -match 'git reset --hard' }
    $up    = Get-EventIndex $d { param($e) $e.Kind -eq 'cmd' -and $e.Id -eq $case.Id -and $e.Command -match 'docker compose .* up ' }
    Test-That "deploy-extensions $($case.Name): script resets the checkout and starts compose (test precondition)" { $reset -ge 0 -and $up -gt $reset }
    Test-That "deploy-extensions $($case.Name): $($case.Suffix) is set to server mode after the reset and before compose up" {
        $between = @($d[($reset + 1)..($up - 1)] | Where-Object { $_.Kind -eq 'overlay' -and $_.Id -eq $case.Id })
        $between.Count -gt 0 -and (Test-ModeIsTrue $between $case.Suffix)
    }
    Test-That "deploy-extensions $($case.Name): never writes the other pgAdmin env file" { (Get-TargetEvents @($d | Where-Object { $_.Id -eq $case.Id }) $case.Other).Count -eq 0 }
}

# --- 3. Edits to the committed files, run through the real Set-RemoteEnvOverlay in bash ----------------
if (-not $bash) {
    Write-Host 'FAIL  bash not found on PATH; the file-edit tests need bash' -ForegroundColor Red
    $Script:Failed++
}
else {
    Test-That 'harness: the real overlay replaces a key and appends a new one on a file without trailing newline, idempotently' {
        $events = @(
            [pscustomobject]@{ File = $null; Content = 'B=3' },
            [pscustomobject]@{ File = $null; Content = "NEWKEY='x y'" })
        $r = Invoke-RealOverlays $events ([Text.Encoding]::UTF8.GetBytes("A=1`nB=2")) 2
        ($r -join '|') -ceq "A=1|B=3|NEWKEY='x y'"
    }
    foreach ($case in @(@{ Name = 'core'; Rel = 'core/env/core-pgadmin.env'; Suffix = $coreSuffix; Events = $a }, @{ Name = 'extensions'; Rel = 'extensions/env/extensions-pgadmin.env'; Suffix = $extSuffix; Events = $b })) {
        Test-That "$($case.Name): applying the overlay twice to the committed file only flips the server-mode line, in place" {
            $targetEvents = Get-TargetEvents $case.Events $case.Suffix
            if ($targetEvents.Count -eq 0) { throw 'no overlay was applied for this file' }
            $after = Invoke-RealOverlays $targetEvents (Get-CommittedBytes $case.Rel) 2
            $expected = @([IO.File]::ReadAllText((Join-Path $repoRoot $case.Rel)).Replace("`r`n", "`n").TrimEnd("`n") -split "`n" | ForEach-Object { if ($_ -like 'PGADMIN_CONFIG_SERVER_MODE=*') { $serverModeLine } else { $_ } })
            ($after -join "`n") -ceq ($expected -join "`n")
        }
    }
}

# --- 4. Guard: local-development defaults must stay as committed ---------------------------------------
foreach ($rel in 'core/env/core-pgadmin.env', 'extensions/env/extensions-pgadmin.env') {
    Test-That "$rel keeps the local default PGADMIN_CONFIG_SERVER_MODE='False' (the server override belongs in the AWS overlay)" {
        [IO.File]::ReadAllText((Join-Path $repoRoot $rel)) -match "(?m)^PGADMIN_CONFIG_SERVER_MODE='False'\s*$"
    }
}

Write-Host ''
Write-Host "$Script:Failed test(s) failed."
exit $Script:Failed
