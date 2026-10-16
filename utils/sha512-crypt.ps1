# SPDX-License-Identifier: Apache-2.0
#
# SHA-512 crypt ($6$, as produced by glibc crypt(3) and `openssl passwd -6`),
# used for TAZAMA_SFTP_PASSWORD_HASH. Dot-sourced by utils/audit-secrets.ps1
# (to verify the hash) and infra/aws/scripts/helpers.ps1 (to derive it).
# Runs on Windows PowerShell 5.1 and PowerShell 7, also under Set-StrictMode.

function Get-Sha512Crypt {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Password,
        [Parameter(Mandatory = $true)][string]$Salt,
        [int]$Rounds = 5000
    )

    if ($Salt.Length -gt 16) { $Salt = $Salt.Substring(0, 16) }
    $p = [Text.Encoding]::UTF8.GetBytes($Password)
    $s = [Text.Encoding]::UTF8.GetBytes($Salt)
    $sha = [Security.Cryptography.SHA512]::Create()

    # Digest of the concatenation of the given byte arrays.
    $digest = {
        param([object[]]$parts)
        $ms = New-Object IO.MemoryStream
        foreach ($part in $parts) { $ms.Write($part, 0, $part.Length) }
        return , $sha.ComputeHash($ms.ToArray())
    }
    # The first $n bytes of $source repeated as often as needed.
    $repeat = {
        param([byte[]]$source, [int]$n)
        $out = New-Object byte[] $n
        for ($i = 0; $i -lt $n; $i++) { $out[$i] = $source[$i % $source.Length] }
        return , $out
    }

    try {
        $b = & $digest @($p, $s, $p)

        $parts = New-Object Collections.Generic.List[object]
        $parts.Add($p); $parts.Add($s)
        $parts.Add((& $repeat $b $p.Length))
        for ($n = $p.Length; $n -gt 0; $n = $n -shr 1) {
            if ($n -band 1) { $parts.Add($b) } else { $parts.Add($p) }
        }
        $a = & $digest $parts.ToArray()

        $dpParts = New-Object Collections.Generic.List[object]
        for ($i = 0; $i -lt $p.Length; $i++) { $dpParts.Add($p) }
        $pSeq = & $repeat (& $digest $dpParts.ToArray()) $p.Length

        $dsParts = New-Object Collections.Generic.List[object]
        for ($i = 0; $i -lt 16 + $a[0]; $i++) { $dsParts.Add($s) }
        $sSeq = & $repeat (& $digest $dsParts.ToArray()) $s.Length

        for ($r = 0; $r -lt $Rounds; $r++) {
            $parts = New-Object Collections.Generic.List[object]
            if ($r -band 1) { $parts.Add($pSeq) } else { $parts.Add($a) }
            if ($r % 3) { $parts.Add($sSeq) }
            if ($r % 7) { $parts.Add($pSeq) }
            if ($r -band 1) { $parts.Add($a) } else { $parts.Add($pSeq) }
            $a = & $digest $parts.ToArray()
        }
    }
    finally { $sha.Dispose() }

    # crypt's base64 over the digest in its fixed byte order.
    $itoa = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
    $sb = New-Object Text.StringBuilder
    for ($k = 0; $k -lt 21; $k++) {
        $i0 = ($k * 22) % 63
        $w = ([int]$a[$i0] -shl 16) -bor ([int]$a[($i0 + 21) % 63] -shl 8) -bor [int]$a[($i0 + 42) % 63]
        for ($c = 0; $c -lt 4; $c++) { [void]$sb.Append($itoa[$w -band 63]); $w = $w -shr 6 }
    }
    $w = [int]$a[63]
    for ($c = 0; $c -lt 2; $c++) { [void]$sb.Append($itoa[$w -band 63]); $w = $w -shr 6 }

    $prefix = if ($Rounds -ne 5000) { "`$6`$rounds=$Rounds`$" } else { '$6$' }
    return "$prefix$Salt`$$($sb.ToString())"
}
