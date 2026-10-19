# SPDX-License-Identifier: Apache-2.0
#
# Audits <group>/secrets.env against <group>/secrets.env.template without
# printing any value. Reports keys that are missing, required but empty, or
# unknown, and checks that TAZAMA_TCS_SFTP_PASSWORD_ENCRYPTED decrypts to
# TAZAMA_SFTP_PASSWORD and that TAZAMA_SFTP_PASSWORD_HASH matches it.
# [generated] keys may be empty or missing: the extensions launcher derives
# them before every deployment (utils/sftp-derived-secrets.ps1).
# Exit code 0 = no findings, 1 = findings.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File utils/audit-secrets.ps1 -GroupDir core
# Runs on Windows PowerShell 5.1 and PowerShell 7.

param(
    [Parameter(Mandatory = $true)]
    [string]$GroupDir
)

$templatePath = Join-Path $GroupDir 'secrets.env.template'
$secretsPath = Join-Path $GroupDir 'secrets.env'

if (-not (Test-Path $templatePath)) {
    Write-Host "Template not found: $templatePath"
    exit 1
}
if (-not (Test-Path $secretsPath)) {
    Write-Host "secrets.env not found in $GroupDir."
    Write-Host "Copy secrets.env.template to secrets.env and fill it in (README.md, section 6)."
    exit 1
}

# Template: every KEY= line; the last [required]/[optional]/[generated] tag above it decides.
$templateKeys = [ordered]@{}
$generatedKeys = @{}
$required = $true
$generated = $false
foreach ($line in Get-Content $templatePath) {
    if ($line -match '^\s*#.*\[optional\]') { $required = $false; $generated = $false; continue }
    if ($line -match '^\s*#.*\[required\]') { $required = $true; $generated = $false; continue }
    if ($line -match '^\s*#.*\[generated\]') { $required = $false; $generated = $true; continue }
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=') {
        $templateKeys[$Matches[1]] = $required
        if ($generated) { $generatedKeys[$Matches[1]] = $true }
    }
}

# secrets.env: KEY=VALUE lines; surrounding quotes are stripped.
$values = @{}
$singleQuoted = @{}
foreach ($line in Get-Content $secretsPath) {
    if ($line -match '^\s*(#|$)') { continue }
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') {
        $key = $Matches[1]
        $value = $Matches[2].Trim()
        $singleQuoted[$key] = $value.Length -ge 2 -and $value[0] -eq "'" -and $value[-1] -eq "'"
        if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[-1] -eq '"') -or ($value[0] -eq "'" -and $value[-1] -eq "'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $values[$key] = $value
    }
}

$missing = @($templateKeys.Keys | Where-Object { -not $values.ContainsKey($_) -and -not $generatedKeys.ContainsKey($_) })
$empty = @($templateKeys.Keys | Where-Object { $templateKeys[$_] -and $values.ContainsKey($_) -and $values[$_] -eq '' })
$unknown = @($values.Keys | Where-Object { -not $templateKeys.Contains($_) } | Sort-Object)
$findings = 0

Write-Host "Auditing $secretsPath (values are never shown)"
Write-Host ''
foreach ($entry in @(
        @{ Title = 'Missing keys (in the template, not in secrets.env)'; Keys = $missing },
        @{ Title = 'Required keys with an empty value'; Keys = $empty },
        @{ Title = 'Unknown keys (not in the template)'; Keys = $unknown })) {
    if ($entry.Keys.Count -gt 0) {
        $findings += $entry.Keys.Count
        Write-Host "$($entry.Title):"
        $entry.Keys | ForEach-Object { Write-Host "  $_" }
        Write-Host ''
    }
}

function ConvertFrom-Hex([string]$hex) {
    if ($hex.Length % 2 -ne 0 -or $hex -notmatch '^[0-9a-fA-F]*$') { throw 'not hex' }
    $bytes = New-Object byte[] ($hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
    return , $bytes
}

$cipherKey = 'TAZAMA_TCS_SFTP_PASSWORD_ENCRYPTED'
if ($templateKeys.Contains($cipherKey)) {
    $payload = $values[$cipherKey]
    $plainExpected = $values['TAZAMA_SFTP_PASSWORD']
    $encryptionKey = $values['TAZAMA_ENRICHMENT_ENCRYPTION_KEY']
    if ($plainExpected -and [Text.Encoding]::UTF8.GetByteCount($plainExpected) -ge 16) {
        Write-Host 'SFTP password check FAILED: TAZAMA_SFTP_PASSWORD must be at most 15 bytes (connection-studio decrypts longer values incorrectly).'
        $findings++
    }
    if ([string]::IsNullOrEmpty($plainExpected) -or [string]::IsNullOrEmpty($encryptionKey)) {
        Write-Host "SFTP ciphertext check skipped: TAZAMA_SFTP_PASSWORD and TAZAMA_ENRICHMENT_ENCRYPTION_KEY must both be set."
        $findings++
    }
    elseif ([string]::IsNullOrEmpty($payload)) {
        Write-Host "SFTP ciphertext check skipped: $cipherKey is not generated yet. The extensions launcher derives it before the next deployment."
    }
    else {
        $result = $null
        try {
            $keyBytes = [Text.Encoding]::UTF8.GetBytes($encryptionKey)
            if ($keyBytes.Length -ne 32) { throw 'TAZAMA_ENRICHMENT_ENCRYPTION_KEY is not exactly 32 bytes' }
            $parts = $payload.Split(':')
            if ($parts.Count -ne 2) { throw "$cipherKey is not in <iv-hex>:<ciphertext-hex> format" }
            $aes = [Security.Cryptography.Aes]::Create()
            $aes.Mode = [Security.Cryptography.CipherMode]::CBC
            $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
            $aes.Key = $keyBytes
            $aes.IV = ConvertFrom-Hex $parts[0]
            $cipherBytes = ConvertFrom-Hex $parts[1]
            $plainBytes = $aes.CreateDecryptor().TransformFinalBlock($cipherBytes, 0, $cipherBytes.Length)
            $result = [Text.Encoding]::UTF8.GetString($plainBytes)
        }
        catch {
            Write-Host "SFTP ciphertext check FAILED: cannot decrypt $cipherKey ($($_.Exception.Message))."
            $findings++
        }
        if ($null -ne $result) {
            if ($result -ceq $plainExpected) {
                Write-Host "SFTP ciphertext check OK: $cipherKey decrypts to TAZAMA_SFTP_PASSWORD."
            }
            else {
                Write-Host "SFTP ciphertext check FAILED: $cipherKey does not decrypt to TAZAMA_SFTP_PASSWORD. The extensions launcher derives it again before the next deployment."
                $findings++
            }
        }
    }
    Write-Host ''
}

$hashKey = 'TAZAMA_SFTP_PASSWORD_HASH'
if ($templateKeys.Contains($hashKey)) {
    $hash = $values[$hashKey]
    $plainExpected = $values['TAZAMA_SFTP_PASSWORD']
    if ([string]::IsNullOrEmpty($plainExpected)) {
        Write-Host "SFTP hash check skipped: TAZAMA_SFTP_PASSWORD must be set."
        $findings++
    }
    elseif ([string]::IsNullOrEmpty($hash)) {
        Write-Host "SFTP hash check skipped: $hashKey is not generated yet. The extensions launcher derives it before the next deployment."
    }
    elseif (-not $singleQuoted[$hashKey]) {
        Write-Host "SFTP hash check FAILED: write $hashKey in single quotes ($hashKey='...'), or Compose expands its `$ signs. The extensions launcher rewrites it before the next deployment."
        $findings++
    }
    elseif ($hash -cnotmatch '^\$6\$(rounds=([0-9]+)\$)?([^$:]{1,16})\$[./0-9A-Za-z]{86}$') {
        Write-Host "SFTP hash check FAILED: $hashKey is not a SHA-512 crypt hash (`$6`$<salt>`$<hash>). The extensions launcher derives it again before the next deployment."
        $findings++
    }
    else {
        $rounds = if ($Matches[2]) { [int]$Matches[2] } else { 5000 }
        $salt = $Matches[3]
        . (Join-Path $PSScriptRoot 'sha512-crypt.ps1')
        if ((Get-Sha512Crypt -Password $plainExpected -Salt $salt -Rounds $rounds) -ceq $hash) {
            Write-Host "SFTP hash check OK: $hashKey matches TAZAMA_SFTP_PASSWORD."
        }
        else {
            Write-Host "SFTP hash check FAILED: $hashKey does not match TAZAMA_SFTP_PASSWORD. The extensions launcher derives it again before the next deployment."
            $findings++
        }
    }
    Write-Host ''
}

if ($findings -eq 0) {
    Write-Host 'No findings.'
    exit 0
}
Write-Host "$findings finding(s)."
exit 1
