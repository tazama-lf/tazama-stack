# SPDX-License-Identifier: Apache-2.0
<#
.SYNOPSIS
    Deploy Server C - tazama-biar stack.

.DESCRIPTION
    1. Waits for the bootstrap script to complete on Server C.
    2. Renders biar/secrets.env from SSM (S3, databases, CouchDB, JupyterHub,
       NiFi secrets).
    3. Applies the Server C env overlays (Set-ServerEnvOverlays):
       - biar/.env: SERVER_A_HOST, SERVER_B_HOST, SERVER_C_HOST -> private DNS.
       - biar/.env: NiFi keycloak mode (issuer, proxy hosts).
       - biar-jupyterhub.env: public Keycloak/hub URLs.
       Requires the custom domain; stops before any container starts if it
       is missing or a required SSM parameter is missing.
    4. Creates the Tazama warehouse host path if it does not exist.
    5. Starts the biar stack using a staged Ozone startup:
         a. SCM first (Storage Container Manager must initialise before OM)
         b. OM after a short wait
         c. Full stack (infrastructure + hub images + init helpers)

    Server A and Server B must be up before this script is run. NiFi on
    Server C connects via JDBC to PostgreSQL on Server A (:15432 - raw_history,
    event_history, configuration, evaluation) and PostgreSQL on Server B (:15433 -
    tazama_cms). Connections are established when NiFi flows run, not at container
    startup, but both database servers should be reachable before flows are activated.

    Run from infra/aws/scripts/ or anywhere - paths are resolved relative
    to this script's location.

.PARAMETER NoPull
    Skip pulling latest Docker images (--pull always). Useful when retrying
    after a failed start where images are already present on the host.

.EXAMPLE
    .\deploy-biar.ps1
    .\deploy-biar.ps1 -NoPull
#>

[CmdletBinding()]
param(
    [switch]$NoPull
)

. "$PSScriptRoot\helpers.ps1"

Write-Host ''
Write-Host '=== Deploy: Server C (tazama-biar) ===' -ForegroundColor Cyan

$out = Get-TofuOutputs
$idC = $out.ServerC_InstanceId

Write-Host "[Server C] Instance ID: $idC"

# -- 1. Wait for bootstrap -----------------------------------------------------
Wait-Bootstrap -InstanceId $idC -ServerName 'Server C'

# -- 1a. Ensure correct repo branch and pull latest ---------------------------
Write-Host '[Server C] Ensuring correct repo branch and pulling latest...'
Invoke-RemoteCommand -InstanceId $idC -Command "cd $Script:RemoteRepo && git fetch origin $Script:RepoBranch && git checkout $Script:RepoBranch && git reset --hard origin/$Script:RepoBranch"
Write-Host '[Server C] Repo up to date.' -ForegroundColor Green

# -- 3. Secrets and env overlays -----------------------------------------------
# The same Server C set as deploy-service.ps1 / restart-service.ps1:
# biar/secrets.env from SSM, env-biar.tpl (private DNS names), NiFi keycloak
# mode and the JupyterHub public URLs. Throws - before anything is
# (re)started - when the custom domain or a required SSM parameter is missing.
Set-ServerEnvOverlays -Server 'C' -InstanceId $idC -TofuOutputs $out

# -- 4. Create warehouse host path --------------------------------------------
# automation-orchestrator and datalakehouse-api bind-mount this path.
# Docker will fail to start the containers if the directory does not exist.
Write-Host '[Server C] Creating Tazama warehouse directory...'
Invoke-RemoteCommand -InstanceId $idC -Command 'sudo mkdir -p /opt/Warehouse && sudo chown ec2-user:ec2-user /opt/Warehouse'
Write-Host '[Server C] Warehouse directory ready.' -ForegroundColor Green

# -- 5. Start biar stack (staged Ozone startup) --------------------------------
# Ozone requires SCM to fully initialise before OM and datanodes register.
# Starting everything at once causes datanodes to fail their initial handshake.
Write-Host '[Server C] Starting tazama-biar stack (staged Ozone startup)...'

$infraFile = './docker-compose.biar.infrastructure.yaml'
$hubFile   = './docker-compose.hub.biar.yaml'
$utilsFile = './docker-compose.utils.init.yaml'
$pullFlag  = if ($NoPull) { '' } else { '--pull always' }
$compose   = 'docker compose --env-file .env --env-file secrets.env -p tazama-biar'

# Step 5a: SCM only
Write-Host '[Server C] Starting Ozone SCM...'
Invoke-RemoteCommand -InstanceId $idC -Command "cd $Script:RemoteRepo/biar && $compose -f $infraFile up -d ozone-scm"

# Step 5b: Wait for SCM to initialise, then start OM
Write-Host '[Server C] Waiting 20s for SCM to initialise...'
Start-Sleep -Seconds 20
Write-Host '[Server C] Starting Ozone OM...'
Invoke-RemoteCommand -InstanceId $idC -Command "cd $Script:RemoteRepo/biar && $compose -f $infraFile up -d ozone-om"

# Step 5c: Wait for OM, then bring up the full stack
Write-Host '[Server C] Waiting 15s for OM to initialise...'
Start-Sleep -Seconds 15

# Prune unused images before pulling to ensure there is enough disk headroom.
# --pull always downloads the new image before removing the old one, so without
# this step a full disk will abort the pull mid-stream.
if (-not $NoPull) {
    Write-Host '[Server C] Pruning unused Docker images to free disk space...'
    Invoke-RemoteCommand -InstanceId $idC -Command 'docker image prune -af'
    Write-Host '[Server C] Image prune complete.' -ForegroundColor Green
}

Write-Host '[Server C] Starting full biar stack...'
Invoke-RemoteCommand -InstanceId $idC -Command "cd $Script:RemoteRepo/biar && $compose -f $infraFile -f $hubFile -f $utilsFile up -d $pullFlag".Trim()

Write-Host ''
Write-Host '[Server C] tazama-biar is up.' -ForegroundColor Green
Write-Host ''
Write-Host 'Verify services:'
Write-Host "  NiFi UI              $($out.NifiPublicUrl)/nifi (Keycloak login, NIFI_ADMIN group)"
Write-Host "  Solr UI              http://$($out.ServerC_PrivateIp):8983/solr"
Write-Host "  Ozone Recon UI       http://$($out.ServerC_PrivateIp):9888"
Write-Host "  Automation Orch API  http://$($out.ServerC_PrivateIp):7619/docs"
Write-Host "  Datalakehouse API    http://$($out.ServerC_PrivateIp):8282/docs"
