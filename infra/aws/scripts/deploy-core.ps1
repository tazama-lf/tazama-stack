# SPDX-License-Identifier: Apache-2.0
<#
.SYNOPSIS
    Deploy Server A - tazama-core stack (hub build).

.DESCRIPTION
    1. Reads instance IDs from tofu outputs.
    2. Waits for the bootstrap script to complete on Server A.
    3. Renders core/secrets.env from SSM and applies the Server A env overlays.
    4. Starts the tazama-core Docker Compose stack (hub images).
    5. Disables the committed test-realm users that grant NiFi / JupyterHub
       access (nifi-admin@tazama.org, jupyter-user@tazama.org) via kcadm.

    Run from infra/aws/scripts/ or anywhere - paths are resolved relative
    to this script's location.

.PARAMETER NoPull
    Skip pulling latest Docker images (--pull always). Useful when retrying
    after a failed start where images are already present on the host.

.EXAMPLE
    .\deploy-core.ps1
    .\deploy-core.ps1 -NoPull
#>

[CmdletBinding()]
param(
    [switch]$NoPull
)
. "$PSScriptRoot\helpers.ps1"

Write-Host ''
Write-Host '=== Deploy: Server A (tazama-core) ===' -ForegroundColor Cyan

$out = Get-TofuOutputs
$idA = $out.ServerA_InstanceId

Write-Host "[Server A] Instance ID: $idA"

# -- 1. Wait for first-boot bootstrap -----------------------------------------
Wait-Bootstrap -InstanceId $idA -ServerName 'Server A'

# -- 2. Pull latest repo changes on Server A ----------------------------------
Write-Host '[Server A] Pulling latest repo changes...'
Invoke-RemoteCommand -InstanceId $idA -Command "cd $Script:RemoteRepo && git fetch origin $Script:RepoBranch && git checkout $Script:RepoBranch && git reset --hard origin/$Script:RepoBranch"
Write-Host '[Server A] Repo up to date.' -ForegroundColor Green

# -- 3. Secrets and env overlays -----------------------------------------------
# core/secrets.env is rendered from SSM /tazama/* (throws when a required
# parameter is missing). Then Server A's AWS env overlays: KEYCLOAK_HOSTNAME
# (when an ALB is active), strip KC_HOSTNAME_PORT from keycloak.env, and the
# demo / JupyterHub / NiFi public URLs (when a custom domain is active).
# -SkipExtensionsOverlay because extensions/secrets.env and the extensions/.env
# overlay on Server A are owned by deploy-extensions.ps1.
Set-ServerEnvOverlays -Server 'A' -InstanceId $idA -TofuOutputs $out -SkipExtensionsOverlay

# -- 4. Copy Keycloak realm config to Server A --------------------------------
# The realm JSON is gitignored-friendly but must be present on the server
# before the stack starts so the volume mount is satisfied and Keycloak
# imports the realm on first boot (--import-realm).
Write-Host '[Server A] Copying Keycloak realm config...'
$localRealm = Join-Path $PSScriptRoot '..\..\..\core\auth\keycloak\realms\00-tazama-test-realm.json'
Invoke-RemoteCommand -InstanceId $idA -Command "mkdir -p $Script:RemoteRepo/core/auth/keycloak/realms"
Copy-ToRemote -InstanceId $idA -LocalPath $localRealm -RemotePath "$Script:RemoteRepo/core/auth/keycloak/realms/00-tazama-test-realm.json"
Write-Host '[Server A] Keycloak realm config copied.' -ForegroundColor Green

# -- 3. Start the core stack ---------------------------------------------------
# Full compose chain: DockerHub-pulled images, all rule processors, pgAdmin, Hasura.
# docker-compose.base.override.yaml must always be position 2 - it publishes
# the three exterior ports that Server B and Server C depend on:
#   NATS :14222 . PostgreSQL :15432 . Valkey :16379
#
# NOTE: Hasura depends_on postgres (service_healthy). On a cold first boot,
# Postgres runs migration scripts and can take >30s to become healthy.
# We retry the up command up to 3 times to ride out this race condition.
# The Postgres healthcheck itself has start_period:120s / retries:20 to give
# the DB enough time; but compose still exits 1 if it times out during the
# initial `up`, so the retry here is the safety net.
Write-Host '[Server A] Starting tazama-core stack...'

$composeArgs = @(
    '--env-file .env'
    '--env-file secrets.env'
    '-p tazama-core'
    '-f ./docker-compose.base.infrastructure.yaml'
    '-f ./docker-compose.base.override.yaml'
    '-f ./docker-compose.full.cfg.yaml'
    '-f ./docker-compose.hub.core.yaml'
    '-f ./docker-compose.full.rules.yaml'
    '-f ./docker-compose.base.auth.yaml'
    '-f ./docker-compose.hub.relay.yaml'
    '-f ./docker-compose.hub.logs.base.yaml'
    '-f ./docker-compose.utils.pgadmin.yaml'
    '-f ./docker-compose.utils.hasura.yaml'
) -join ' '

$maxAttempts = 3
$pullFlag = if ($NoPull) { '' } else { '--pull always' }
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
        Invoke-RemoteCommand -InstanceId $idA -Command "cd $Script:RemoteRepo/core && docker compose $composeArgs up -d $pullFlag".Trim()
        break
    }
    catch {
        if ($attempt -lt $maxAttempts) {
            Write-Warning "[Server A] Stack start failed (attempt $attempt/$maxAttempts) — Postgres may still be initialising. Retrying in 30s (images already present, skipping pull)..."
            $pullFlag = ''   # subsequent retries never need to re-pull
            Start-Sleep -Seconds 30
        }
        else {
            throw
        }
    }
}

Write-Host ''
Write-Host '[Server A] tazama-core is up.' -ForegroundColor Green

# -- 5. Disable committed test users in the Keycloak realm --------------------
# The realm JSON copied in step 4 is the repo's TEST realm. Some of its users
# have committed passwords and grant access that must not be publicly
# reachable on AWS (nifi-admin: NiFi admin incl. ExecuteProcess on Server C;
# jupyter-user: notebook access). Disable them after import. Idempotent; a
# user that does not exist (realm imported before it was added) is skipped.
# Runs kcadm inside the keycloak container with the container's own
# KEYCLOAK_ADMIN / KEYCLOAK_ADMIN_PASSWORD, so no password crosses SSH. Fails
# the deploy (non-zero exit) if Keycloak never accepts the admin login or any
# kcadm call fails, so the exposure cannot pass silently.
Write-Host '[Server A] Disabling committed test users in the Keycloak realm...'
$disableTestUsers = @'
kc=/opt/keycloak/bin/kcadm.sh; ok=0
for i in $(seq 1 36); do
  $kc config credentials --server http://localhost:8080 --realm master --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null 2>&1 && { ok=1; break; }
  sleep 5
done
[ "$ok" = 1 ] || { echo "Keycloak admin login failed after 3 minutes"; exit 1; }
for u in nifi-admin@tazama.org jupyter-user@tazama.org; do
  id=$($kc get users -r tazama -q exact=true -q username="$u" --fields id --format csv --noquotes) || exit 1
  if [ -z "$id" ]; then echo "$u: not present"; continue; fi
  $kc update "users/$id" -r tazama -s enabled=false || exit 1
  echo "$u: disabled"
done
'@ -replace "`r", ''
$disableB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($disableTestUsers))
Invoke-RemoteCommand -InstanceId $idA -Command "echo $disableB64 | base64 -d | docker exec -i keycloak bash -s"
Write-Host '[Server A] Test users disabled.' -ForegroundColor Green

Write-Host ''
Write-Host 'Next step: .\deploy-extensions.ps1'
