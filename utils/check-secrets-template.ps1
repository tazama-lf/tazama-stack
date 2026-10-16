# SPDX-License-Identifier: Apache-2.0
#
# Maintainer check (README.md, section 8): for core, extensions and biar,
# compares the ${TAZAMA_*} references in the compose files and env files with
# the keys in secrets.env.template and with the "Original default values"
# table in the group README, in both directions. Also checks that each
# reference uses the fail-fast form matching the template tag:
# [required] -> ${KEY:?...}, [optional] -> ${KEY?...}.
# Keys defined in the group's .env (plain configuration, e.g. TAZAMA_VERSION)
# are ignored. Source-only keys (no file references them; other keys are
# derived from them and the audit checks those) are exempt from the "never
# referenced" check. Exit code 0 = consistent, 1 = mismatches.
#
# Usage: pwsh -NoProfile -File utils/check-secrets-template.ps1

$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = 0
$sourceOnlyKeys = @('TAZAMA_SFTP_PASSWORD')

function Write-Finding([string]$title, [string[]]$keys) {
    if ($keys.Count -eq 0) { return }
    $script:failures += $keys.Count
    Write-Host "  $title"
    $keys | Sort-Object -Unique | ForEach-Object { Write-Host "    $_" }
}

foreach ($group in 'core', 'extensions', 'biar') {
    $groupDir = Join-Path $repoRoot $group
    Write-Host "[$group]"

    # Template keys and their [required]/[optional] tag
    $template = @{}
    $required = $true
    foreach ($line in Get-Content (Join-Path $groupDir 'secrets.env.template')) {
        if ($line -match '^\s*#.*\[optional\]') { $required = $false; continue }
        if ($line -match '^\s*#.*\[required\]') { $required = $true; continue }
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=') { $template[$Matches[1]] = $required }
    }

    # Plain configuration keys from .env
    $configKeys = @{}
    $dotEnv = Join-Path $groupDir '.env'
    if (Test-Path $dotEnv) {
        foreach ($line in Get-Content $dotEnv) {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=') { $configKeys[$Matches[1]] = $true }
        }
    }

    # References in compose files and env files
    $files = @(Get-ChildItem $groupDir -Filter 'docker-compose*.yaml' -File)
    $envDir = Join-Path $groupDir 'env'
    if (Test-Path $envDir) { $files += @(Get-ChildItem $envDir -Filter '*.env' -File) }
    if (Test-Path $dotEnv) { $files += Get-Item -Force $dotEnv }

    $refs = @{}
    $badForm = @()
    foreach ($file in $files) {
        # Comment lines are skipped
        $content = (Get-Content $file.FullName | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        foreach ($m in [regex]::Matches($content, '(?<!\$)\$\{(TAZAMA_[A-Z0-9_]+)([^}]*)\}')) {
            $key = $m.Groups[1].Value
            if ($configKeys.ContainsKey($key)) { continue }
            $refs[$key] = $true
            $modifier = $m.Groups[2].Value
            $isRequired = $modifier.StartsWith(':?')
            $isOptional = -not $isRequired -and $modifier.StartsWith('?')
            if (-not ($isRequired -or $isOptional)) {
                $badForm += "$key in $($file.Name): not in fail-fast form"
            }
            elseif ($template.ContainsKey($key) -and $template[$key] -ne $isRequired) {
                $tag = if ($template[$key]) { 'required' } else { 'optional' }
                $badForm += "$key in $($file.Name): template says [$tag], reference differs"
            }
        }
    }

    # README "Original default values" table: rows starting with | `TAZAMA_...`
    $readmeKeys = @{}
    $inTable = $false
    foreach ($line in Get-Content (Join-Path $groupDir 'README.md')) {
        if ($line -match '^#+\s') { $inTable = $line -match 'Original default values'; continue }
        if ($inTable -and $line -match '^\|\s*`(TAZAMA_[A-Z0-9_]+)`') { $readmeKeys[$Matches[1]] = $true }
    }

    Write-Finding 'Referenced but not in secrets.env.template:' @($refs.Keys | Where-Object { -not $template.ContainsKey($_) })
    Write-Finding 'In secrets.env.template but never referenced:' @($template.Keys | Where-Object { -not $refs.ContainsKey($_) -and $sourceOnlyKeys -notcontains $_ })
    Write-Finding 'Reference form:' $badForm
    Write-Finding 'In secrets.env.template but not in the README defaults table:' @($template.Keys | Where-Object { -not $readmeKeys.ContainsKey($_) })
    Write-Finding 'In the README defaults table but not in secrets.env.template:' @($readmeKeys.Keys | Where-Object { -not $template.ContainsKey($_) })
}

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'Secrets templates are consistent.'
    exit 0
}
Write-Host "$failures mismatch(es)."
exit 1
