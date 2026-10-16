# SPDX-License-Identifier: Apache-2.0
<#
.SYNOPSIS
    Shared helpers for Tazama AWS deploy scripts.
    Dot-source this file from every deploy/teardown script:
        . "$PSScriptRoot\helpers.ps1"

.DESCRIPTION
    Provides:
      - Get-TofuOutputs     - reads tofu output -json for instance IDs / IPs
      - Invoke-RemoteCommand - SSH to an EC2 instance via EICE ProxyCommand
      - Copy-ToRemote        - SCP a file to an EC2 instance via EICE
      - Set-RemoteEnvOverlay - apply KEY=VALUE overlay to a remote .env file
      - Set-ServerSecretsEnv - render a component group's secrets.env from SSM
      - Set-DemoUiOverlay    - apply the tazama-demo public URL
      - Set-JupyterHubOidcOverlay - apply the JupyterHub public URL for the Keycloak realm import
      - Set-NifiOidcOverlay  - apply the NiFi public URL for the Keycloak realm import
      - Set-NifiAuthOverlay  - switch biar-nifi to keycloak mode (Server C)
      - Set-BiarServiceEnvOverlay - apply the public Keycloak / JupyterHub URLs to biar-jupyterhub.env (Server C)
      - Set-ServerEnvOverlays - re-apply a server's full per-server AWS env overlays
      - Wait-Bootstrap       - poll until the bootstrap script has completed
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Disable the AWS CLI v2 pager. On Windows/PowerShell the CLI can launch its
# pager even when stdout is captured into a variable (e.g. $x = aws ...), which
# silently blocks the script - worse here because callers redirect stderr with
# 2>$null, hiding any prompt. An empty AWS_PAGER makes every aws call below
# non-interactive regardless of the operator's profile/config.
$env:AWS_PAGER = ''

# -- Constants ----------------------------------------------------------------
# Override any of these via environment variables before dot-sourcing:
#   $env:TAZAMA_AWS_REGION  - AWS region (default: ap-south-1)
#   $env:TAZAMA_AWS_PROFILE - AWS CLI profile name (default: tazama)
#   $env:TAZAMA_SSH_KEY     - Path to your SSH private key (default: ~/.ssh/id_ed25519)
$Script:AwsRegion  = if ($env:TAZAMA_AWS_REGION)  { $env:TAZAMA_AWS_REGION }  else { 'ap-south-1' }
$Script:AwsProfile = if ($env:TAZAMA_AWS_PROFILE) { $env:TAZAMA_AWS_PROFILE } else { 'tazama' }
$Script:KeyFile    = if ($env:TAZAMA_SSH_KEY)      { $env:TAZAMA_SSH_KEY }     else { "$env:USERPROFILE\.ssh\id_ed25519" }
$Script:RemoteRepo   = '/home/ec2-user/tazama-stack'
$Script:RemoteUser   = 'ec2-user'
$Script:RepoBranch   = 'dev'
$Script:TemplatesDir = Join-Path $PSScriptRoot '..\templates'
# Resolve aws.exe to its full path so OpenSSH can execute it in a ProxyCommand.
# When OpenSSH spawns ProxyCommand it may not inherit PowerShell's PATH.
$Script:AwsExe = (Get-Command aws -ErrorAction SilentlyContinue).Source
if (-not $Script:AwsExe) { $Script:AwsExe = 'aws' }
# -- Get-TofuOutputs ----------------------------------------------------------
# Runs `tofu output -json` from the infra/aws directory and returns a hashtable:
#   .ServerA_InstanceId  .ServerB_InstanceId  .ServerC_InstanceId
#   .ServerA_PrivateIp   .ServerB_PrivateIp   .ServerC_PrivateIp
#   .EiceEndpointId
function Get-TofuOutputs {
    Push-Location (Join-Path $PSScriptRoot '..')
    try {
        $json = (tofu output -json) | ConvertFrom-Json
        return @{
            ServerA_InstanceId = $json.server_a_instance_id.value
            ServerB_InstanceId = $json.server_b_instance_id.value
            ServerC_InstanceId = $json.server_c_instance_id.value
            ServerA_PrivateIp  = $json.server_a_private_ip.value
            ServerB_PrivateIp  = $json.server_b_private_ip.value
            ServerC_PrivateIp  = $json.server_c_private_ip.value
            EiceEndpointId     = $json.eice_endpoint_id.value
            AlbDnsName         = if ($json.PSObject.Properties['alb_dns_name']) { $json.alb_dns_name.value } else { '' }
            KeycloakHostname   = if ($json.PSObject.Properties['keycloak_hostname']) { $json.keycloak_hostname.value } else { '' }
            DemoPublicUrl      = if ($json.PSObject.Properties['demo_public_url']) { $json.demo_public_url.value } else { '' }
            JupyterPublicUrl   = if ($json.PSObject.Properties['jupyter_public_url']) { $json.jupyter_public_url.value } else { '' }
            NifiPublicUrl      = if ($json.PSObject.Properties['nifi_public_url']) { $json.nifi_public_url.value } else { '' }
        }
    }
    finally {
        Pop-Location
    }
}

# -- New-SshConfig (internal) -------------------------------------------------
# Writes a temporary SSH config file for one instance and returns its path.
# The config uses the EICE ProxyCommand so no port 22 needs to be open.
# Caller is responsible for deleting the file when done.
function New-SshConfig {
    param([string]$InstanceId)

    # Resolve-Path gives us an absolute path; replace backslashes for OpenSSH.
    $keyPath = (Resolve-Path $Script:KeyFile).Path -replace '\\', '/'

    $content = @"
Host $InstanceId
  HostName $InstanceId
  User $Script:RemoteUser
  IdentityFile $keyPath
  StrictHostKeyChecking no
  UserKnownHostsFile NUL
  ConnectTimeout 20
  ServerAliveInterval 10
  ServerAliveCountMax 2
  ProxyCommand $Script:AwsExe ec2-instance-connect open-tunnel --instance-id %h --remote-port %p --region $Script:AwsRegion --profile $Script:AwsProfile
"@
    $tmp = [System.IO.Path]::GetTempFileName()
    Set-Content $tmp $content -Encoding ASCII
    return $tmp
}

# -- Invoke-RemoteCommand -----------------------------------------------------
# Runs $Command on the remote EC2 instance identified by $InstanceId via EICE.
# Throws on non-zero SSH exit code.
function Invoke-RemoteCommand {
    param(
        [string]$InstanceId,
        [string]$Command
    )

    # Strip CR characters so Windows here-strings don't produce \r\n line endings
    # that bash rejects with "command not found".
    $Command = $Command -replace "`r", ''

    $cfg = New-SshConfig $InstanceId
    try {
        ssh -q -F $cfg $InstanceId $Command
        if ($LASTEXITCODE -ne 0) {
            throw "Remote command failed (exit $LASTEXITCODE): $Command"
        }
    }
    finally {
        Remove-Item $cfg -Force -ErrorAction SilentlyContinue
    }
}

# -- Copy-ToRemote -------------------------------------------------------------
# SCP $LocalPath to $RemotePath on the remote instance via EICE.
# $RemotePath may contain ~ (e.g. ~/tazama-stack/...).
function Copy-ToRemote {
    param(
        [string]$InstanceId,
        [string]$LocalPath,
        [string]$RemotePath
    )

    $cfg = New-SshConfig $InstanceId
    try {
        scp -q -F $cfg $LocalPath "${InstanceId}:${RemotePath}"
        if ($LASTEXITCODE -ne 0) {
            throw "SCP failed (exit $LASTEXITCODE): $LocalPath -> $RemotePath"
        }
    }
    finally {
        Remove-Item $cfg -Force -ErrorAction SilentlyContinue
    }
}

# -- Set-RemoteEnvOverlay -----------------------------------------------------
# Reads a KEY=VALUE overlay and applies each entry to the remote .env file at
# $RemoteEnvFile using sed:
#   - If the key exists: the value is replaced in-place.
#   - If the key is absent: the key=value line is appended.
#
# Supply EITHER -OverlayFile (path to a local .tpl file) OR -OverlayContent
# (a multi-line string of KEY=VALUE pairs).  Lines beginning with # are ignored.
function Set-RemoteEnvOverlay {
    param(
        [string]$InstanceId,
        [string]$OverlayFile,
        [string]$OverlayContent,
        [string]$RemoteEnvFile
    )

    $hasFile    = -not [string]::IsNullOrWhiteSpace($OverlayFile)
    $hasContent = -not [string]::IsNullOrWhiteSpace($OverlayContent)
    if ($hasFile -eq $hasContent) {
        throw "Set-RemoteEnvOverlay requires exactly one of -OverlayFile or -OverlayContent."
    }

    $source = if ($OverlayFile) { Get-Content $OverlayFile } `
              else               { $OverlayContent -split "`n" }

    $lines = $source | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '=' }

    if (-not $lines) { return }

    # Build all sed/append commands as a single bash script and run them in one
    # SSH connection. Opening one EICE tunnel per key causes rate-limit hangs
    # when the overlay has many entries.
    #
    # Security: values may contain single quotes (passwords), pipe characters
    # (URLs), or other shell metacharacters. Mitigations applied:
    #   1. POSIX-escape values: replace every ' with '\'' before inlining.
    #   2. Use a control character (\x01) as the sed delimiter so | in values
    #      cannot break the sed expression.
    #   3. Use an explicit if/then/else instead of "&& ... ||" so a sed failure
    #      does not trigger the append branch and create duplicate KEY= lines.
    #   4. Escape \ and & in the sed replacement copy only (sed treats & as the
    #      matched text and \ as an escape); the append branch writes the raw value.
    $bashLines = foreach ($line in $lines) {
        $key   = ($line -split '=', 2)[0].Trim()
        $value = ($line -split '=', 2)[1].Trim()
        # Escape single quotes for POSIX shell: ' -> '\''.
        $vEsc  = $value -replace "'", "'\''" 
        # sed escaping must precede quote escaping, which itself introduces a \.
        $vSed  = ($value -replace '\\', '\\' -replace '&', '\&') -replace "'", "'\''"
        # \x01 is used as the sed delimiter; it cannot appear in env values.
        "if grep -q '^${key}=' ${RemoteEnvFile}; then " +
        "sed -i 's`u{1}^${key}=.*`u{1}${key}=${vSed}`u{1}' ${RemoteEnvFile}; " +
        "else printf '%s\n' '${key}=${vEsc}' >> ${RemoteEnvFile}; fi"
    }
    # Several committed env files have no trailing newline; without this guard
    # the first appended key would be glued onto the file's last line.
    $newlineGuard = "if [ -s ${RemoteEnvFile} ] && [ -n `"`$(tail -c1 ${RemoteEnvFile})`" ]; then echo >> ${RemoteEnvFile}; fi"
    $batchCmd = (@($newlineGuard) + $bashLines) -join '; '
    Invoke-RemoteCommand $InstanceId $batchCmd
}

# -- Set-DemoUiOverlay --------------------------------------------------------
# When a custom domain is active, point the tazama-demo UI at its public HTTPS
# URL. Written to core/.env; the demo service (docker-compose.base.auth.yaml)
# consumes it via ${DEMO_PUBLIC_URL} interpolation. Without this the committed
# localhost default applies (correct for local dev only). The NextAuth secret
# comes from core/secrets.env (see Set-ServerSecretsEnv).
#
# No-op when $DemoPublicUrl is empty (custom domain not enabled). Shared by
# deploy-core.ps1, deploy-service.ps1 and restart-service.ps1 so the demo env
# is re-applied consistently after any git reset --hard that restores defaults.
function Set-DemoUiOverlay {
    param(
        [string]$InstanceId,
        [string]$DemoPublicUrl,
        [string]$ServerLabel = 'Server A'
    )

    if (-not $DemoPublicUrl) { return }

    Write-Host "[$ServerLabel] Applying demo UI overlay (public URL)..."
    Set-RemoteEnvOverlay -InstanceId $InstanceId `
        -OverlayContent "DEMO_PUBLIC_URL=$DemoPublicUrl" `
        -RemoteEnvFile "$Script:RemoteRepo/core/.env"
    Write-Host "[$ServerLabel] Demo UI overlay applied." -ForegroundColor Green
}

# -- Set-JupyterHubOidcOverlay ------------------------------------------------
# When a custom domain is active, give Keycloak the JupyterHub public URL.
# Written to core/.env; the keycloak service (docker-compose.base.auth.yaml)
# passes it into the container, where the realm import resolves the jupyterhub
# client's ${JUPYTERHUB_PUBLIC_URL:...} redirect/web origin placeholders. The
# client secret comes from core/secrets.env (see Set-ServerSecretsEnv).
# Only takes effect on a fresh realm import (KEYCLOAK_IMPORT_STRATEGY=IGNORE_EXISTING).
# The hub side (biar-jupyterhub.env on Server C) is configured separately.
#
# No-op when $JupyterPublicUrl is empty (custom domain not enabled).
function Set-JupyterHubOidcOverlay {
    param(
        [string]$InstanceId,
        [string]$JupyterPublicUrl,
        [string]$ServerLabel = 'Server A'
    )

    if (-not $JupyterPublicUrl) { return }

    Write-Host "[$ServerLabel] Applying JupyterHub OIDC overlay (public URL)..."
    Set-RemoteEnvOverlay -InstanceId $InstanceId `
        -OverlayContent "JUPYTERHUB_PUBLIC_URL=$JupyterPublicUrl" `
        -RemoteEnvFile "$Script:RemoteRepo/core/.env"
    Write-Host "[$ServerLabel] JupyterHub OIDC overlay applied." -ForegroundColor Green
}

# -- Set-NifiOidcOverlay ------------------------------------------------------
# When a custom domain is active, give Keycloak the NiFi public URL. Written to
# core/.env; the keycloak service (docker-compose.base.auth.yaml) passes it into
# the container, where the realm import resolves the nifi client's
# ${NIFI_PUBLIC_URL:...} redirect URI placeholder. The client secret comes from
# core/secrets.env (see Set-ServerSecretsEnv).
# Only takes effect on a fresh realm import (KEYCLOAK_IMPORT_STRATEGY=IGNORE_EXISTING).
#
# NIFI_PUBLIC_URL carries an explicit :443 - behind the ALB, NiFi builds its
# OIDC redirect_uri from X-Forwarded-Port and sends https://nifi.<domain>:443/...,
# which must match the registered redirect URI exactly.
# The NiFi side (biar/.env on Server C) is configured by Set-NifiAuthOverlay.
#
# No-op when $NifiPublicUrl is empty (custom domain not enabled).
function Set-NifiOidcOverlay {
    param(
        [string]$InstanceId,
        [string]$NifiPublicUrl,
        [string]$ServerLabel = 'Server A'
    )

    if (-not $NifiPublicUrl) { return }

    Write-Host "[$ServerLabel] Applying NiFi OIDC overlay (public URL)..."
    Set-RemoteEnvOverlay -InstanceId $InstanceId `
        -OverlayContent "NIFI_PUBLIC_URL=${NifiPublicUrl}:443" `
        -RemoteEnvFile "$Script:RemoteRepo/core/.env"
    Write-Host "[$ServerLabel] NiFi OIDC overlay applied." -ForegroundColor Green
}

# -- Set-NifiAuthOverlay ------------------------------------------------------
# Switch biar-nifi on Server C to keycloak mode: HTTPS on 8443 behind the ALB
# host rule (nifi.<domain>), OIDC login against the realm's nifi client. Writes
# to biar/.env, which the biar-nifi compose service interpolates into its
# environment (NIFI_AUTH, KEYCLOAK_*, NIFI_WEB_PROXY_HOST). The four NiFi
# secrets come from biar/secrets.env (see Set-ServerSecretsEnv).
#
# NIFI_WEB_PROXY_HOST lists the public host (with and without :443) and
# <ServerC_PrivateIp>:8443, the Host header the ALB health check sends.
#
# Refuses (throws) when the custom domain is missing: keycloak mode cannot
# start without it, and falling back to none mode would leave NiFi without an
# ALB path anyway.
function Set-NifiAuthOverlay {
    param(
        [string]$InstanceId,
        [hashtable]$TofuOutputs,
        [string]$ServerLabel = 'Server C'
    )

    if (-not $TofuOutputs.NifiPublicUrl -or -not $TofuOutputs.KeycloakHostname) {
        throw "[$ServerLabel] NiFi keycloak mode needs the custom domain (tofu outputs nifi_public_url / keycloak_hostname are empty). Enable enable_custom_domain and re-apply tofu first."
    }

    $nifiHost = ([uri]$TofuOutputs.NifiPublicUrl).Host
    $overlay = @(
        'NIFI_AUTH=keycloak'
        "NIFI_KEYCLOAK_ISSUER_URL=https://$($TofuOutputs.KeycloakHostname)/realms/tazama"
        "NIFI_WEB_PROXY_HOST=$nifiHost,${nifiHost}:443,$($TofuOutputs.ServerC_PrivateIp):8443"
    )

    Write-Host "[$ServerLabel] Applying NiFi auth overlay (keycloak mode)..."
    Set-RemoteEnvOverlay -InstanceId $InstanceId `
        -OverlayContent ($overlay -join "`n") `
        -RemoteEnvFile "$Script:RemoteRepo/biar/.env"
    Write-Host "[$ServerLabel] NiFi auth overlay applied." -ForegroundColor Green
}

# -- Set-BiarServiceEnvOverlay ------------------------------------------------
# Apply the public Keycloak / JupyterHub URLs to biar/env/biar-jupyterhub.env
# on Server C, which a 'git reset --hard' restores to its localhost defaults:
#   KEYCLOAK_ISSUER_URL, JUPYTERHUB_PUBLIC_URL - from the tofu outputs
# The JupyterHub client secret and crypt key, and the CouchDB account of the
# unstructured pipeline, come from biar/secrets.env (see Set-ServerSecretsEnv).
#
# Skipped with a warning when no custom domain is active.
function Set-BiarServiceEnvOverlay {
    param(
        [string]$InstanceId,
        [hashtable]$TofuOutputs,
        [string]$ServerLabel = 'Server C'
    )

    if (-not $TofuOutputs.JupyterPublicUrl -or -not $TofuOutputs.KeycloakHostname) {
        Write-Warning "[$ServerLabel] No custom domain (tofu outputs jupyter_public_url / keycloak_hostname are empty) - biar-jupyterhub.env keeps its local defaults."
        return
    }

    $jhOverlay = @(
        "KEYCLOAK_ISSUER_URL=https://$($TofuOutputs.KeycloakHostname)/realms/tazama"
        "JUPYTERHUB_PUBLIC_URL=$($TofuOutputs.JupyterPublicUrl)"
    ) -join "`n"

    Write-Host "[$ServerLabel] Applying biar service env overlay (JupyterHub URLs)..."
    Set-RemoteEnvOverlay -InstanceId $InstanceId `
        -OverlayContent $jhOverlay `
        -RemoteEnvFile "$Script:RemoteRepo/biar/env/biar-jupyterhub.env"
    Write-Host "[$ServerLabel] biar service env overlay applied." -ForegroundColor Green
}

# -- Set-ServerSecretsEnv -----------------------------------------------------
# Render <Group>/secrets.env on a server from SSM (#298). The compose and env
# files of each component group reference their secrets as ${TAZAMA_*}; every
# compose call in these scripts passes `--env-file .env --env-file secrets.env`.
# secrets.env is gitignored, so 'git reset --hard' leaves it in place.
#
# The key list comes from the committed <Group>/secrets.env.template of the
# local checkout. Every template key must have an entry in
# $Script:SecretsSsmMap, so a new key cannot go silently missing on AWS. All
# SSM reads and checks happen before the file is written:
#   - required key ([required] in the template, or listed in
#     $Script:SecretsAwsRequired) whose parameter is missing or empty: throw;
#   - optional key whose parameter is missing: written empty (listed in one
#     info line, so a misspelled SSM name is visible).
# Values are written single-quoted (KEY='value'). Compose reads single-quoted
# dotenv values literally, so '$' needs no escaping. Value rules:
#   - no single quote, CR or LF (all keys);
#   - URL-embedded keys ($Script:SecretsUrlKeys): no whitespace and none of
#     @ : / ? # % [ ] \ " (they would break the URL userinfo);
#   - TAZAMA_SFTP_PASSWORD: at most 15 bytes (connection-studio
#     decrypts longer values incorrectly);
#   - TAZAMA_NIFI_*: none of $ | & \ (NiFi's sed-based property substitution);
#     the sensitive-props key needs at least 12 characters;
#   - TAZAMA_ENRICHMENT_ENCRYPTION_KEY: exactly 32 bytes (AES-256 key).
# TAZAMA_TCS_SFTP_PASSWORD_ENCRYPTED and TAZAMA_SFTP_PASSWORD_HASH are derived
# locally from the SFTP password and the enrichment key (see
# Get-TcsSftpCiphertext and Get-SftpPasswordHash).
# The content is piped over ssh stdin (no secret on any command line) and
# written with mode 600. No value is ever printed.
$Script:SecretsSsmMap = [ordered]@{
    TAZAMA_CORE_PG_PASSWORD              = '/tazama/creds/postgres/password'
    TAZAMA_EXT_PG_PASSWORD               = '/tazama/creds/postgres/password'
    TAZAMA_VALKEY_PASSWORD               = '/tazama/creds/valkey/password'
    TAZAMA_KEYCLOAK_ADMIN_PASSWORD       = '/tazama/creds/keycloak/admin_password'
    TAZAMA_AUTH_CLIENT_SECRET            = '/tazama/creds/auth/client-secret'
    TAZAMA_RELAY_AUTH_PASSWORD           = '/tazama/creds/relay/auth-password'
    TAZAMA_JUPYTERHUB_OIDC_CLIENT_SECRET = '/tazama/creds/jupyterhub/oidc-client-secret'
    TAZAMA_JUPYTERHUB_CRYPT_KEY          = '/tazama/creds/jupyterhub/crypt_key'
    TAZAMA_NIFI_OIDC_CLIENT_SECRET       = '/tazama/creds/nifi/oidc-client-secret'
    TAZAMA_NIFI_SENSITIVE_PROPS_KEY      = '/tazama/creds/nifi/sensitive-props-key'
    TAZAMA_NIFI_KEYSTORE_PASSWORD        = '/tazama/creds/nifi/keystore-password'
    TAZAMA_NIFI_TRUSTSTORE_PASSWORD      = '/tazama/creds/nifi/truststore-password'
    TAZAMA_DEMO_NEXTAUTH_SECRET          = '/tazama/nextauth_secret'
    TAZAMA_HASURA_ADMIN_SECRET           = '/tazama/creds/hasura/admin_secret'
    TAZAMA_PGADMIN_PASSWORD              = '/tazama/creds/pgadmin/password'
    TAZAMA_APM_SECRET_TOKEN              = '/tazama/creds/apm/secret-token'
    TAZAMA_SFTP_PASSWORD                 = '/tazama/creds/sftp/password'
    TAZAMA_TCS_SFTP_PASSWORD_ENCRYPTED   = $null   # derived, see Get-TcsSftpCiphertext
    TAZAMA_SFTP_PASSWORD_HASH            = $null   # derived, see Get-SftpPasswordHash
    TAZAMA_ENRICHMENT_ENCRYPTION_KEY     = '/tazama/creds/enrichment/encryption-key'
    TAZAMA_FLOWABLE_PASSWORD             = '/tazama/creds/flowable/password'
    TAZAMA_OPENSEARCH_PASSWORD           = '/tazama/creds/opensearch/admin_password'
    TAZAMA_COUCHDB_USERNAME              = '/tazama/creds/couchdb/username'
    TAZAMA_COUCHDB_PASSWORD              = '/tazama/creds/couchdb/password'
    TAZAMA_COUCHDB_COOKIE_SECRET         = '/tazama/creds/couchdb/cookie-secret'
    TAZAMA_DOCKERHUB_USERNAME            = '/tazama/creds/dockerhub/username'
    TAZAMA_DOCKERHUB_TOKEN               = '/tazama/creds/dockerhub/token'
    TAZAMA_SMTP_USER                     = '/tazama/creds/smtp/user'
    TAZAMA_SMTP_PASS                     = '/tazama/creds/smtp/password'
    TAZAMA_S3_ACCESS_KEY                 = '/tazama/creds/ozone/s3_access_key'
    TAZAMA_S3_SECRET_KEY                 = '/tazama/creds/ozone/s3_secret'
}
# Optional in the template (local NIFI_AUTH=none needs none of them), but AWS
# always runs NiFi in keycloak mode (Set-NifiAuthOverlay).
$Script:SecretsAwsRequired = @(
    'TAZAMA_NIFI_OIDC_CLIENT_SECRET'
    'TAZAMA_NIFI_SENSITIVE_PROPS_KEY'
    'TAZAMA_NIFI_KEYSTORE_PASSWORD'
    'TAZAMA_NIFI_TRUSTSTORE_PASSWORD'
)
$Script:SecretsUrlKeys = @(
    'TAZAMA_CORE_PG_PASSWORD'
    'TAZAMA_EXT_PG_PASSWORD'
    'TAZAMA_COUCHDB_USERNAME'
    'TAZAMA_COUCHDB_PASSWORD'
)

# -- Get-TcsSftpCiphertext (internal) -----------------------------------------
# connection-studio's encrypted SFTP password: AES-256-CBC, key = the UTF-8
# bytes of the 32-character enrichment key, output = ivHex:cipherHex. The IV
# is deterministic (first 16 bytes of SHA-256 over key + password), so the
# value only changes when an input changes and connection-studio is not
# recreated on every deploy.
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

# -- Get-SftpPasswordHash (internal) ------------------------------------------
# SHA-512 crypt hash of the SFTP password for the atmoz/sftp user definition
# (user:<hash>:e:uid), so the container log shows no plain password (#301).
# The 16-character salt is deterministic (SHA-256 over a fixed prefix, the
# enrichment key and the password), so the value only changes when an input
# changes and the sftp container is not recreated on every deploy. The key in
# the salt input keeps the salt from being a public function of the password.
. (Join-Path $PSScriptRoot '..\..\..\utils\sha512-crypt.ps1')
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

function Set-ServerSecretsEnv {
    param(
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][ValidateSet('core', 'extensions', 'biar')][string]$Group,
        [string]$ServerLabel = 'server'
    )

    # Template keys and their [required]/[optional] tag: the last tag in a
    # comment applies to the KEY= lines that follow.
    $templatePath = Join-Path $PSScriptRoot "..\..\..\$Group\secrets.env.template"
    $keys = [ordered]@{}
    $tag = 'required'
    foreach ($line in Get-Content $templatePath) {
        if ($line -match '^\s*#') {
            $tags = [regex]::Matches($line, '\[(required|optional)\]')
            if ($tags.Count) { $tag = $tags[$tags.Count - 1].Groups[1].Value }
        } elseif ($line -match '^\s*(TAZAMA_\w+)=') {
            $keys[$Matches[1]] = ($tag -eq 'required') -or ($Script:SecretsAwsRequired -contains $Matches[1])
        }
    }
    $unmapped = @($keys.Keys | Where-Object { -not $Script:SecretsSsmMap.Contains($_) })
    if ($unmapped) {
        throw "[$ServerLabel] $Group/secrets.env.template has keys without an SSM mapping in helpers.ps1 (`$Script:SecretsSsmMap): $($unmapped -join ', ')"
    }

    # Batched SSM read (get-parameters takes at most 10 names per call).
    $names = @($keys.Keys | ForEach-Object { $Script:SecretsSsmMap[$_] } | Where-Object { $_ } | Sort-Object -Unique)
    $ssm = @{}
    for ($i = 0; $i -lt $names.Count; $i += 10) {
        $batch = $names[$i..([Math]::Min($i + 9, $names.Count - 1))]
        $json = aws ssm get-parameters --names $batch --with-decryption `
            --region $Script:AwsRegion --profile $Script:AwsProfile --output json
        if ($LASTEXITCODE -ne 0) { throw "[$ServerLabel] aws ssm get-parameters failed (exit $LASTEXITCODE)." }
        foreach ($p in (($json -join "`n") | ConvertFrom-Json).Parameters) { $ssm[$p.Name] = $p.Value }
    }

    $values = [ordered]@{}
    $absentOptional = @()
    foreach ($key in $keys.Keys) {
        $name = $Script:SecretsSsmMap[$key]
        if (-not $name) { continue }   # derived below
        $v = if ($ssm.ContainsKey($name)) { $ssm[$name] } else { '' }
        if (-not $ssm.ContainsKey($name) -and -not $keys[$key]) { $absentOptional += "$key ($name)" }
        if (-not $v -and $keys[$key]) {
            throw "[$ServerLabel] $key ($Group/secrets.env): SSM parameter $name is missing or empty. Seed it first: aws ssm put-parameter --name $name --type SecureString --value <value> (see aws-deployment-instructions.md)."
        }
        $where = "[$ServerLabel] $key (SSM $name)"
        if ($v -match "['\r\n]") { throw "$where contains a single quote or a line break - not supported." }
        if ($Script:SecretsUrlKeys -contains $key -and $v -match '[\s@:/?#%\[\]\\"]') {
            throw "$where contains whitespace or one of @ : / ? # % [ ] \ "" - not supported in a connection URL."
        }
        if ($key -eq 'TAZAMA_SFTP_PASSWORD' -and [System.Text.Encoding]::UTF8.GetByteCount($v) -ge 16) { throw "$where must be at most 15 bytes - connection-studio decrypts longer values incorrectly." }
        if ($key -like 'TAZAMA_NIFI_*' -and $v -match '[$|&\\]') { throw "$where contains one of `$ | & \ - not supported by NiFi. Use a hex value (openssl rand -hex 32)." }
        if ($key -eq 'TAZAMA_NIFI_SENSITIVE_PROPS_KEY' -and $v -and $v.Length -lt 12) { throw "$where must be at least 12 characters." }
        if ($key -eq 'TAZAMA_ENRICHMENT_ENCRYPTION_KEY' -and [System.Text.Encoding]::UTF8.GetByteCount($v) -ne 32) { throw "$where must be exactly 32 bytes (AES-256 key)." }
        $values[$key] = $v
    }
    if ($absentOptional) {
        Write-Host "[$ServerLabel] Optional secrets not in SSM (rendered empty): $($absentOptional -join ', ')"
    }
    if ($keys.Contains('TAZAMA_TCS_SFTP_PASSWORD_ENCRYPTED')) {
        $values['TAZAMA_TCS_SFTP_PASSWORD_ENCRYPTED'] = Get-TcsSftpCiphertext `
            -Password $values['TAZAMA_SFTP_PASSWORD'] -Key $values['TAZAMA_ENRICHMENT_ENCRYPTION_KEY']
    }
    if ($keys.Contains('TAZAMA_SFTP_PASSWORD_HASH')) {
        $values['TAZAMA_SFTP_PASSWORD_HASH'] = Get-SftpPasswordHash `
            -Password $values['TAZAMA_SFTP_PASSWORD'] -Key $values['TAZAMA_ENRICHMENT_ENCRYPTION_KEY']
    }

    $lines = @(
        '# Rendered from SSM /tazama/* by infra/aws/scripts/helpers.ps1 (Set-ServerSecretsEnv).'
        '# Do not edit: every deploy overwrites this file. Change the SSM parameter instead.'
    )
    foreach ($key in $keys.Keys) { $lines += "$key='$($values[$key])'" }
    $content = ($lines -join "`n") + "`n"

    Write-Host "[$ServerLabel] Writing $Group/secrets.env ($($keys.Count) keys from SSM)..."
    $dir = "$Script:RemoteRepo/$Group"
    $remoteCmd = "umask 077 && tr -d '\r' > $dir/secrets.env.tmp && mv -f $dir/secrets.env.tmp $dir/secrets.env"
    $cfg = New-SshConfig $InstanceId
    try {
        $content | ssh -q -F $cfg $InstanceId $remoteCmd
        if ($LASTEXITCODE -ne 0) { throw "[$ServerLabel] Writing $Group/secrets.env failed (exit $LASTEXITCODE)." }
    }
    finally {
        Remove-Item $cfg -Force -ErrorAction SilentlyContinue
    }
    Write-Host "[$ServerLabel] $Group/secrets.env written." -ForegroundColor Green
}

# -- Set-ServerEnvOverlays ----------------------------------------------------
# Re-apply the per-server AWS env overlays that must not be committed, and
# render the server's secrets.env files from SSM (see Set-ServerSecretsEnv -
# throws when a required SSM parameter is missing). A 'git reset --hard' on
# the target server restores the repo's committed (local-dev) defaults; this
# function restores the AWS-specific values:
#   Server A : core/secrets.env, and extensions/secrets.env + extensions/.env
#              (host names, public API URLs, CORS) unless
#              -SkipExtensionsOverlay; KEYCLOAK_HOSTNAME in core/.env; strips
#              KC_HOSTNAME_PORT from keycloak.env; the tazama-demo,
#              JupyterHub and NiFi public URLs (see Set-DemoUiOverlay,
#              Set-JupyterHubOidcOverlay, Set-NifiOidcOverlay).
#   Server B : extensions/secrets.env; extensions/.env overlay.
#   Server C : biar/secrets.env; biar/.env overlay (host names, S3A_ENDPOINT);
#              NiFi keycloak mode (see Set-NifiAuthOverlay - throws when the
#              custom domain is missing); public Keycloak / JupyterHub URLs in
#              biar-jupyterhub.env (see Set-BiarServiceEnvOverlay).
#
# Shared by deploy-core.ps1, deploy-biar.ps1, deploy-service.ps1 and
# restart-service.ps1 so the overlay set stays identical across initial
# deploys and post-reset restores.
# -SkipExtensionsOverlay is used by deploy-core.ps1, whose scope is the core
# stack only - the extensions/.env overlay on Server A is owned by
# deploy-extensions.ps1.
function Set-ServerEnvOverlays {
    param(
        [Parameter(Mandatory)][ValidateSet('A', 'B', 'C')][string]$Server,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][hashtable]$TofuOutputs,
        [switch]$SkipExtensionsOverlay
    )

    $label = "Server $Server"

    switch ($Server) {
        'A' {
            Set-ServerSecretsEnv -InstanceId $InstanceId -Group 'core' -ServerLabel $label

            if (-not $SkipExtensionsOverlay) {
                # DEMS / DEAPI run from extensions/ on Server A
                Set-ServerSecretsEnv -InstanceId $InstanceId -Group 'extensions' -ServerLabel $label

                # extensions/.env: SERVER_A/B/C_HOST, public API URLs, CORS origins
                Write-Host "[$label] Re-applying extensions .env overlay..."
                Set-RemoteEnvOverlay -InstanceId $InstanceId `
                    -OverlayFile (Join-Path $Script:TemplatesDir 'env-extensions.tpl') `
                    -RemoteEnvFile "$Script:RemoteRepo/extensions/.env"
            }

            # core/.env: KEYCLOAK_HOSTNAME (only present when an ALB is active)
            if ($TofuOutputs.KeycloakHostname) {
                Write-Host "[$label] Applying KEYCLOAK_HOSTNAME to core/.env..."
                Set-RemoteEnvOverlay -InstanceId $InstanceId `
                    -OverlayContent "KEYCLOAK_HOSTNAME=$($TofuOutputs.KeycloakHostname)" `
                    -RemoteEnvFile "$Script:RemoteRepo/core/.env"
            }

            # KC_HOSTNAME_PORT must be absent on AWS - KC_PROXY=edge derives the
            # port from the ALB's X-Forwarded-Port: 443. The committed keycloak.env
            # carries KC_HOSTNAME_PORT=8080 for local use; strip it here.
            # TODO(#221): replace with Set-RemoteEnvOverlay deletion support.
            Write-Host "[$label] Stripping KC_HOSTNAME_PORT from keycloak.env..."
            Invoke-RemoteCommand -InstanceId $InstanceId `
                -Command "sed -i '/^KC_HOSTNAME_PORT=/d' $Script:RemoteRepo/core/env/keycloak.env"

            # core/.env: tazama-demo public URL (custom domain only)
            Set-DemoUiOverlay -InstanceId $InstanceId -DemoPublicUrl $TofuOutputs.DemoPublicUrl -ServerLabel $label

            # core/.env: JupyterHub public URL for the realm import (custom domain only)
            Set-JupyterHubOidcOverlay -InstanceId $InstanceId -JupyterPublicUrl $TofuOutputs.JupyterPublicUrl -ServerLabel $label

            # core/.env: NiFi public URL for the realm import (custom domain only)
            Set-NifiOidcOverlay -InstanceId $InstanceId -NifiPublicUrl $TofuOutputs.NifiPublicUrl -ServerLabel $label
        }
        'B' {
            Set-ServerSecretsEnv -InstanceId $InstanceId -Group 'extensions' -ServerLabel $label

            # extensions/.env: SERVER_A/B/C_HOST, public API URLs, CORS origins
            Write-Host "[$label] Re-applying extensions .env overlay..."
            Set-RemoteEnvOverlay -InstanceId $InstanceId `
                -OverlayFile (Join-Path $Script:TemplatesDir 'env-extensions.tpl') `
                -RemoteEnvFile "$Script:RemoteRepo/extensions/.env"
        }
        'C' {
            Set-ServerSecretsEnv -InstanceId $InstanceId -Group 'biar' -ServerLabel $label

            # biar/.env: SERVER_A/B/C_HOST, S3A_ENDPOINT
            Write-Host "[$label] Re-applying biar .env overlay..."
            Set-RemoteEnvOverlay -InstanceId $InstanceId `
                -OverlayFile (Join-Path $Script:TemplatesDir 'env-biar.tpl') `
                -RemoteEnvFile "$Script:RemoteRepo/biar/.env"

            # biar/.env: NiFi keycloak mode (throws without the custom domain)
            Set-NifiAuthOverlay -InstanceId $InstanceId -TofuOutputs $TofuOutputs -ServerLabel $label

            # biar/env/biar-jupyterhub.env: public Keycloak / JupyterHub URLs
            Set-BiarServiceEnvOverlay -InstanceId $InstanceId -TofuOutputs $TofuOutputs -ServerLabel $label
        }
    }
}

# -- Wait-Bootstrap ------------------------------------------------------------
# Polls every 30 seconds until /home/ec2-user/.bootstrap-complete exists on
# the remote instance, or until $TimeoutMinutes have elapsed.
function Wait-Bootstrap {
    param(
        [string]$InstanceId,
        [string]$ServerName,
        [int]   $TimeoutMinutes = 15
    )

    Write-Host "[$ServerName] Waiting for bootstrap to complete (timeout: ${TimeoutMinutes}m)..."
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

    while ((Get-Date) -lt $deadline) {
        $cfg = New-SshConfig $InstanceId
        try {
            ssh -q -F $cfg $InstanceId 'test -f /home/ec2-user/.bootstrap-complete'
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[$ServerName] Bootstrap complete." -ForegroundColor Green
                return
            }
        }
        catch { }
        finally {
            Remove-Item $cfg -Force -ErrorAction SilentlyContinue
        }
        Write-Host "[$ServerName]   still bootstrapping - retrying in 30s"
        Start-Sleep -Seconds 30
    }

    throw "[$ServerName] Bootstrap did not complete within $TimeoutMinutes minutes. Check /var/log/tazama-bootstrap.log on the instance."
}
