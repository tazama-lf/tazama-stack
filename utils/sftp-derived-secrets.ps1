# SPDX-License-Identifier: Apache-2.0
#
# The two values derived from TAZAMA_SFTP_PASSWORD (#302):
#   TAZAMA_SFTP_PASSWORD_HASH          - SHA-512 crypt hash for the atmoz/sftp
#                                        user definition (user:<hash>:e:1001)
#   TAZAMA_TCS_SFTP_PASSWORD_ENCRYPTED - connection-studio's encrypted SFTP
#                                        password (AES-256-CBC, ivHex:cipherHex)
# Both are computed in this process; the password never reaches a command line
# or a container. Salt and IV are deterministic (SHA-256 over the inputs), so
# the values only change when the password or the enrichment key changes, and
# the containers are not recreated on every deploy.
#
# Dot-sourced by infra/aws/scripts/helpers.ps1 (functions only). Run with
# -GroupDir, it brings <group>/secrets.env up to date (Sync-SftpDerivedSecrets);
# the extensions launcher does that before every deploy. utils/sftp-derived-secrets.sh
# is the bash equivalent and produces identical values.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File utils/sftp-derived-secrets.ps1 -GroupDir extensions
# Runs on Windows PowerShell 5.1 and PowerShell 7, also under Set-StrictMode.

param([string]$GroupDir)

. (Join-Path $PSScriptRoot 'sha512-crypt.ps1')

# -- Get-TcsSftpCiphertext ----------------------------------------------------
# connection-studio's encrypted SFTP password: AES-256-CBC, key = the UTF-8
# bytes of the 32-character enrichment key, output = ivHex:cipherHex. The IV
# is the first 16 bytes of SHA-256 over key + password.
function Get-TcsSftpCiphertext {
    param([string]$Password, [string]$Key)

    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($Key)
    $plain    = [System.Text.Encoding]::UTF8.GetBytes($Password)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $iv = [byte[]]($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Key + $Password))[0..15])
    } finally { $sha.Dispose() }
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key     = $keyBytes
        $aes.IV      = $iv
        $enc = $aes.CreateEncryptor()
        try { $cipher = $enc.TransformFinalBlock($plain, 0, $plain.Length) } finally { $enc.Dispose() }
    } finally { $aes.Dispose() }
    $toHex = { param($b) -join ($b | ForEach-Object { $_.ToString('x2') }) }
    return "$(& $toHex $iv):$(& $toHex $cipher)"
}

# -- Get-SftpPasswordHash -----------------------------------------------------
# SHA-512 crypt hash of the SFTP password (#301). The 16-character salt is
# taken from SHA-256 over a fixed prefix, the enrichment key and the password;
# the key in the salt input keeps the salt from being a public function of the
# password.
function Get-SftpPasswordHash {
    param([string]$Password, [string]$Key)

    $itoa = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("sftp-hash-salt:$Key$Password"))
    } finally { $sha.Dispose() }
    $salt = -join (0..15 | ForEach-Object { $itoa[$digest[$_] -band 63] })
    return Get-Sha512Crypt -Password $Password -Salt $salt
}

# -- Test-SftpPasswordHash ----------------------------------------------------
# True when $Hash is a SHA-512 crypt hash of $Password, with any salt or
# rounds (hand-made hashes are kept).
function Test-SftpPasswordHash {
    param([string]$Hash, [string]$Password)

    if ($Hash -cnotmatch '^\$6\$(rounds=([0-9]+)\$)?([^$:]{1,16})\$[./0-9A-Za-z]{86}$') { return $false }
    $rounds = if ($Matches[2]) { [int]$Matches[2] } else { 5000 }
    return (Get-Sha512Crypt -Password $Password -Salt $Matches[3] -Rounds $rounds) -ceq $Hash
}

# -- Test-TcsSftpCiphertext ---------------------------------------------------
# True when $Payload (ivHex:cipherHex) decrypts to $Password with $Key, with
# any IV (hand-made values are kept).
function Test-TcsSftpCiphertext {
    param([string]$Payload, [string]$Password, [string]$Key)

    $parts = $Payload.Split(':')
    if ($parts.Count -ne 2 -or $parts[0].Length -ne 32 -or $parts[1].Length -eq 0 -or
        $parts[1].Length % 32 -ne 0 -or ($parts[0] + $parts[1]) -notmatch '^[0-9a-fA-F]+$') { return $false }
    $fromHex = {
        param([string]$hex)
        $bytes = New-Object byte[] ($hex.Length / 2)
        for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
        return , $bytes
    }
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key     = [System.Text.Encoding]::UTF8.GetBytes($Key)
        $aes.IV      = & $fromHex $parts[0]
        $cipher = & $fromHex $parts[1]
        $dec = $aes.CreateDecryptor()
        try { $plain = $dec.TransformFinalBlock($cipher, 0, $cipher.Length) }
        catch { return $false }   # wrong key or IV: invalid padding
        finally { $dec.Dispose() }
    } finally { $aes.Dispose() }
    return [System.Text.Encoding]::UTF8.GetString($plain) -ceq $Password
}

# -- Sync-SftpDerivedSecrets --------------------------------------------------
# Brings both derived values in <GroupDir>/secrets.env up to date with
# TAZAMA_SFTP_PASSWORD. A value that already matches the password is kept. An
# empty, missing or stale one is derived again and its line rewritten (the
# hash single-quoted); a missing line is added below TAZAMA_SFTP_PASSWORD. All
# other lines, the line endings and the encoding stay as they are; the file is
# replaced atomically. No value is printed. Returns $false (after explaining
# why) when the inputs are unusable.
function Sync-SftpDerivedSecrets {
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
    $values = @{}; $quoted = @{}; $index = @{}
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*(#|$)') { continue }
        if ($lines[$i] -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') {
            $k = $Matches[1]
            $v = $Matches[2].Trim()
            $quoted[$k] = $v.Length -ge 2 -and $v[0] -eq "'" -and $v[-1] -eq "'"
            if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) {
                $v = $v.Substring(1, $v.Length - 2)
            }
            $values[$k] = $v; $index[$k] = $i
        }
    }

    $password = if ($values.ContainsKey('TAZAMA_SFTP_PASSWORD')) { $values['TAZAMA_SFTP_PASSWORD'] } else { '' }
    $key = if ($values.ContainsKey('TAZAMA_ENRICHMENT_ENCRYPTION_KEY')) { $values['TAZAMA_ENRICHMENT_ENCRYPTION_KEY'] } else { '' }
    $problems = @()
    if (-not $password) { $problems += 'TAZAMA_SFTP_PASSWORD is missing or empty.' }
    elseif ([System.Text.Encoding]::UTF8.GetByteCount($password) -gt 15) {
        $problems += 'TAZAMA_SFTP_PASSWORD must be at most 15 bytes (connection-studio decrypts longer values incorrectly).'
    }
    if ([System.Text.Encoding]::UTF8.GetByteCount($key) -ne 32) {
        $problems += 'TAZAMA_ENRICHMENT_ENCRYPTION_KEY must be exactly 32 bytes (AES-256 key).'
    }
    if ($problems) {
        Write-Host "Cannot derive the SFTP values in ${path}:"
        $problems | ForEach-Object { Write-Host "  $_" }
        return $false
    }

    $updates = [ordered]@{}
    $hashKey = 'TAZAMA_SFTP_PASSWORD_HASH'
    if (-not ($values.ContainsKey($hashKey) -and $quoted[$hashKey] -and (Test-SftpPasswordHash -Hash $values[$hashKey] -Password $password))) {
        $updates[$hashKey] = "'" + (Get-SftpPasswordHash -Password $password -Key $key) + "'"
    }
    $cipherKey = 'TAZAMA_TCS_SFTP_PASSWORD_ENCRYPTED'
    if (-not ($values.ContainsKey($cipherKey) -and (Test-TcsSftpCiphertext -Payload $values[$cipherKey] -Password $password -Key $key))) {
        $updates[$cipherKey] = Get-TcsSftpCiphertext -Password $password -Key $key
    }
    if ($updates.Count -eq 0) {
        Write-Host 'SFTP values in secrets.env match TAZAMA_SFTP_PASSWORD.'
        return $true
    }

    $insertAt = $index['TAZAMA_SFTP_PASSWORD'] + 1
    foreach ($k in $updates.Keys) {
        if ($index.ContainsKey($k)) {
            $lines[$index[$k]] = "$k=$($updates[$k])"
        }
        else {
            $lines.Insert($insertAt, "$k=$($updates[$k])")
            foreach ($other in @($index.Keys)) { if ($index[$other] -ge $insertAt) { $index[$other]++ } }
            $insertAt++
        }
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
    foreach ($k in $updates.Keys) { Write-Host "Updated $k in secrets.env (derived from TAZAMA_SFTP_PASSWORD)." }
    return $true
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $GroupDir) {
        Write-Host 'Usage: sftp-derived-secrets.ps1 -GroupDir <group folder>'
        exit 2
    }
    $ErrorActionPreference = 'Stop'
    if (Sync-SftpDerivedSecrets -GroupDir $GroupDir) { exit 0 }
    exit 1
}
