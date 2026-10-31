# SPDX-License-Identifier: Apache-2.0
#
# The value derived from the rule-studio-devtestops GitHub token:
#   TAZAMA_DEVTESTOPS_GITHUB_TOKEN_ENCRYPTED - TAZAMA_DEVTESTOPS_GITHUB_PAT
#       encrypted with TAZAMA_DEVTESTOPS_ENCRYPTION_KEY and
#       TAZAMA_DEVTESTOPS_ENCRYPTION_IV (AES-256-CBC, lowercase hex, no IV
#       prefix), as rule-studio-devtestops decrypts it (GITHUB_TOKEN).
# Computed in this process; the token never reaches a command line or a
# container. Key and IV are fixed, so the value only changes when an input
# changes, and the container is not recreated on every deploy.
#
# Dot-sourced by infra/aws/scripts/helpers.ps1 (functions only). Run with
# -GroupDir, it brings <group>/secrets.env up to date
# (Sync-DevTestOpsDerivedSecrets); the extensions launcher does that before
# every deploy. utils/devtestops-derived-secrets.sh is the bash equivalent and
# produces identical values.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File utils/devtestops-derived-secrets.ps1 -GroupDir extensions
# Runs on Windows PowerShell 5.1 and PowerShell 7, also under Set-StrictMode.

param([string]$GroupDir)

# -- Get-DevTestOpsTokenCiphertext --------------------------------------------
# AES-256-CBC/PKCS7; key = the UTF-8 bytes of the 32-character key, IV = the
# UTF-8 bytes of the 16-character IV; output = lowercase hex.
function Get-DevTestOpsTokenCiphertext {
    param([string]$Pat, [string]$Key, [string]$Iv)

    $plain = [System.Text.Encoding]::UTF8.GetBytes($Pat)
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key     = [System.Text.Encoding]::UTF8.GetBytes($Key)
        $aes.IV      = [System.Text.Encoding]::UTF8.GetBytes($Iv)
        $enc = $aes.CreateEncryptor()
        try { $cipher = $enc.TransformFinalBlock($plain, 0, $plain.Length) } finally { $enc.Dispose() }
    } finally { $aes.Dispose() }
    return -join ($cipher | ForEach-Object { $_.ToString('x2') })
}

# -- Sync-DevTestOpsDerivedSecrets --------------------------------------------
# Brings TAZAMA_DEVTESTOPS_GITHUB_TOKEN_ENCRYPTED in <GroupDir>/secrets.env up
# to date:
#   - PAT, key or IV empty: the token is emptied (the service does not start;
#     the deployment continues);
#   - all three set: key and IV lengths are checked, the token is derived and
#     its line rewritten when it differs (a missing line is added below the
#     inputs).
# All other lines, the line endings and the encoding stay as they are; the
# file is replaced atomically. No value is printed. Returns $false (after
# explaining why) when the inputs are unusable.
function Sync-DevTestOpsDerivedSecrets {
    param([Parameter(Mandatory = $true)][string]$GroupDir)

    $dir = (Resolve-Path -LiteralPath $GroupDir).ProviderPath
    $path = Join-Path $dir 'secrets.env'
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "secrets.env not found in $dir."
        return $false
    }

    $bytes = [System.IO.File]::ReadAllBytes($path)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $skip = if ($bom) { 3 } else { 0 }
    $encoding = New-Object System.Text.UTF8Encoding($bom)
    $text = $encoding.GetString($bytes, $skip, $bytes.Length - $skip)
    $eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $finalEol = $text.EndsWith("`n")
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.AddRange([string[]]($text -split "`r?`n"))
    if ($finalEol) { $lines.RemoveAt($lines.Count - 1) }

    # KEY=VALUE lines, parsed like utils/audit-secrets.ps1; the last one wins.
    $values = @{}; $index = @{}
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*(#|$)') { continue }
        if ($lines[$i] -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') {
            $k = $Matches[1]
            $v = $Matches[2].Trim()
            if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) {
                $v = $v.Substring(1, $v.Length - 2)
            }
            $values[$k] = $v; $index[$k] = $i
        }
    }
    $get = { param($k) if ($values.ContainsKey($k)) { $values[$k] } else { '' } }

    $tokenKey = 'TAZAMA_DEVTESTOPS_GITHUB_TOKEN_ENCRYPTED'
    $sourceKeys = 'TAZAMA_DEVTESTOPS_GITHUB_PAT', 'TAZAMA_DEVTESTOPS_ENCRYPTION_KEY', 'TAZAMA_DEVTESTOPS_ENCRYPTION_IV'
    $pat = & $get $sourceKeys[0]
    $key = & $get $sourceKeys[1]
    $iv  = & $get $sourceKeys[2]
    $current = & $get $tokenKey

    if (-not ($pat -and $key -and $iv)) {
        Write-Host 'rule-studio-devtestops will not start: TAZAMA_DEVTESTOPS_GITHUB_PAT, _ENCRYPTION_KEY and _ENCRYPTION_IV are not all set.'
        if (-not $current) { return $true }
        $target = ''
    }
    else {
        $problems = @()
        if ([System.Text.Encoding]::UTF8.GetByteCount($key) -ne 32) {
            $problems += 'TAZAMA_DEVTESTOPS_ENCRYPTION_KEY must be exactly 32 bytes (AES-256 key).'
        }
        if ([System.Text.Encoding]::UTF8.GetByteCount($iv) -ne 16) {
            $problems += 'TAZAMA_DEVTESTOPS_ENCRYPTION_IV must be exactly 16 bytes (AES IV).'
        }
        if ($problems) {
            Write-Host "Cannot derive the DevTestOps token in ${path}:"
            $problems | ForEach-Object { Write-Host "  $_" }
            return $false
        }
        $target = Get-DevTestOpsTokenCiphertext -Pat $pat -Key $key -Iv $iv
        if ($current -ieq $target) {
            Write-Host 'DevTestOps token in secrets.env matches TAZAMA_DEVTESTOPS_GITHUB_PAT.'
            return $true
        }
    }

    if ($index.ContainsKey($tokenKey)) {
        $lines[$index[$tokenKey]] = "$tokenKey=$target"
    }
    else {
        $after = @($sourceKeys | Where-Object { $index.ContainsKey($_) } | ForEach-Object { $index[$_] } | Measure-Object -Maximum).Maximum
        $lines.Insert([int]$after + 1, "$tokenKey=$target")
    }
    $newText = $lines -join $eol
    if ($finalEol) { $newText += $eol }

    $tmp = Join-Path $dir ".secrets.env.$PID.tmp"
    try {
        [System.IO.File]::WriteAllText($tmp, $newText, $encoding)
        [System.IO.File]::Replace($tmp, $path, [NullString]::Value)
    }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
    if ($target) { Write-Host "Updated $tokenKey in secrets.env (derived from TAZAMA_DEVTESTOPS_GITHUB_PAT)." }
    else { Write-Host "Emptied $tokenKey in secrets.env." }
    return $true
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $GroupDir) {
        Write-Host 'Usage: devtestops-derived-secrets.ps1 -GroupDir <group folder>'
        exit 2
    }
    $ErrorActionPreference = 'Stop'
    if (Sync-DevTestOpsDerivedSecrets -GroupDir $GroupDir) { exit 0 }
    exit 1
}
