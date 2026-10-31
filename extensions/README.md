<!-- SPDX-License-Identifier: Apache-2.0 -->

<a id="top"></a>

<h1></h1>
<h1 style="color: red;">WARNING - THIS TAZAMA REPOSITORY IS TO BE USED FOR DEMONSTRATION, EXPLORATION AND TESTING PURPOSES ONLY.</h1>

- [1. INTRODUCTION](#1-introduction)
- [2. PRE-REQUISITES](#2-pre-requisites)
- [3. DEPLOYMENT ARCHITECTURE](#3-deployment-architecture)
- [4. INSTALLATION STEPS](#4-installation-steps)
  - [4.1. Server A pre-flight: DEMS and DEAPI](#41-server-a-pre-flight-dems-and-deapi)
  - [4.2. Server B extensions stack](#42-server-b-extensions-stack)
  - [4.3. Utilities and teardown](#43-utilities-and-teardown)
- [5. OVERVIEW OF SERVICES](#5-overview-of-services)
  - [5.1. Server A APIs (joined to tazama-core)](#51-server-a-apis-joined-to-tazama-core)
  - [5.2. Extensions infrastructure (Server B)](#52-extensions-infrastructure-server-b)
  - [5.3. Extensions services (Server B)](#53-extensions-services-server-b)
- [6. ACCESSING DEPLOYED COMPONENTS](#6-accessing-deployed-components)
- [7. TROUBLESHOOTING TIPS](#7-troubleshooting-tips)
- [8. APPENDIX](#8-appendix)
  - [8.1. Authentication public key](#81-authentication-public-key)
  - [8.2. Docker Compose YAML structure](#82-docker-compose-yaml-structure)
  - [8.3. Original default values](#83-original-default-values)
  - [8.4. Generating the SFTP values by hand](#84-generating-the-sftp-values-by-hand)
  - [8.5. Generating the DevTestOps token by hand](#85-generating-the-devtestops-token-by-hand)

<h1></h1>
<h1 style="color: red;">WARNING - THIS TAZAMA REPOSITORY IS TO BE USED FOR DEMONSTRATION, EXPLORATION AND TESTING PURPOSES ONLY.</h1>

For production deployment instructions:
 - [On-Premise Detailed Installation Guide](https://github.com/tazama-lf/On-Prem-helm)
 - [AWS Detailed Installation Guide](https://github.com/tazama-lf/EKS-helm)
 - [Google Cloud Detailed Installation Guide](https://github.com/tazama-lf/GKE-helm)
 - [Azure Detailed Installation Guide](https://github.com/tazama-lf/AKS-helm)

# 1. INTRODUCTION

The `extensions/` stack adds Tazama's extended tooling on top of the core deployment. It provides the browser-based studios and the case management system that operators use to configure rules, review transaction data, and investigate fraud cases. It also contributes two API services (DEMS and DEAPI) that are deployed onto the core server rather than the extensions server, because the core processors depend on them directly.

In a local single-machine deployment, everything runs on `localhost`. In the AWS multi-server deployment, the extensions infrastructure and services run on a dedicated Server B instance, while DEMS and DEAPI run on Server A alongside the core stack.

This guide covers the local deployment using the included launcher scripts. For the AWS deployment see [infra/aws/aws-deployment-instructions.md](../infra/aws/aws-deployment-instructions.md).

<div style="text-align: right"><a href="#top">Top</a></div>

# 2. PRE-REQUISITES

The pre-requisites for deploying the extensions stack are the same as for the core stack:

- Git
- Code editor (this guide assumes VS Code)
- Docker Desktop for Windows with WSL (or Linux/macOS equivalent)
- GitHub personal access token with `read:packages` permissions

> [!NOTE] **Notes on GitHub personal access token**
> - A GitHub personal access token must be created with `read:packages` permissions to pull images from the GitHub Container Registry (`ghcr.io`)
> - Add the token as a Windows environment variable called `GH_TOKEN`. If the token had been set as an environment variable, you can verify with: `echo %GH_TOKEN%` (cmd) or `echo $env:GH_TOKEN` (PowerShell)
> - Once the token is set, authenticate Docker with `ghcr.io`. Docker stores the credential securely and reuses it automatically for all subsequent image pulls. Repeat this step whenever your PAT expires or is rotated:
>
>   **PowerShell:**
>   ```powershell
>   echo $env:GH_TOKEN | docker login ghcr.io -u <your-github-username> --password-stdin
>   ```
>   **Command prompt:**
>   ```
>   echo %GH_TOKEN% | docker login ghcr.io -u <your-github-username> --password-stdin
>   ```

In addition, the **core stack must be running** before the extensions stack is started. The DEMS and DEAPI pre-flight step (Section 4.1) requires the `tazama-core` Docker Compose project to be active on the same machine.

<div style="text-align: right"><a href="#top">Top</a></div>

# 3. DEPLOYMENT ARCHITECTURE

The extensions stack is split into two parts that must be deployed in order:

| Part | Where | What | When |
|---|---|---|---|
| Server A pre-flight | Server A (core machine) | DEMS, DEAPI -- joined to the `tazama-core` compose project | Before starting Server B |
| Extensions stack | Server B (this machine) | PostgreSQL, SFTP, CouchDB, Flowable, OpenSearch, TCS, TRS, CMS | After DEMS and DEAPI are running |

**Why is the pre-flight on Server A?**
The Data Enrichment API (DEAPI) and the Data Enrichment Monitoring Service (DEMS) are consumed by rule processors and the TMS which all run on Server A. They must be reachable from within the `tazama-core` Docker network, so they join that Compose project rather than the extensions project.

**Single-machine local deployment:**
On a single machine, Server A and Server B are both `localhost`. Run the pre-flight step first (options 1 or 2 in the launcher), then the extensions stack (options 3 or 4).

<div style="text-align: right"><a href="#top">Top</a></div>

# 4. INSTALLATION STEPS

Before the first deployment, create `extensions/secrets.env` from the template and fill in every `[required]` key (on Server A as well: DEMS and DEAPI read it). Leave the two `[generated]` keys empty: the launcher derives them from `TAZAMA_SFTP_PASSWORD` (Section 4.2). The file is gitignored. See [root README section 6](../README.md#6-secrets) for the rules and the keys that must match `core/secrets.env` and `biar/secrets.env`; the public test values the stack used before are listed in [Section 8.3](#83-original-default-values).

```powershell
Copy-Item secrets.env.template secrets.env
```

The launcher stops with an error if `secrets.env` is missing.

Navigate to the `extensions/` folder and run the launcher:

**Windows**
```
tazama-extensions.bat
```
**PowerShell**
```powershell
.\tazama-extensions.bat
```
**Unix (Linux/macOS)**
```
./tazama-extensions.sh
```

The launcher presents the following menu:

```text
============================================================
 Tazama Extensions Launcher
============================================================

 Server A pre-flight  (run on Server A before Server B):
   1. Deploy DEMS + DEAPI  (GitHub builds)
   2. Deploy DEMS + DEAPI  (DockerHub images)

 Server B extensions stack:
   3. Deploy extensions    (GitHub builds)
   4. Deploy extensions    (DockerHub images)

   5. Utilities / teardown
   6. Audit secrets

Select option (1-6), or (q)uit:
```

Option 6 compares `secrets.env` with the template without deploying anything or printing any value: it reports missing, empty (required keys only) or unknown keys, and checks that `TAZAMA_TCS_SFTP_PASSWORD_ENCRYPTED` decrypts to `TAZAMA_SFTP_PASSWORD`, that `TAZAMA_SFTP_PASSWORD_HASH` matches it and is single-quoted, and that `TAZAMA_SFTP_PASSWORD` is at most 15 bytes (connection-studio currently decrypts longer values incorrectly). Empty `[generated]` keys are not a finding: options 3 and 4 fill them in. See [root README section 6.6](../README.md#66-checking-your-setup).

## 4.1. Server A pre-flight: DEMS and DEAPI

Options 1 and 2 deploy DEMS and DEAPI onto the running `tazama-core` Compose project on Server A. The launcher checks that `tazama-core` is running before proceeding.

| Option | Build source |
|---|---|
| 1 | GitHub source builds (branch controlled by `DEMS_BRANCH` and `DEAPI_BRANCH` in `.env`) |
| 2 | Pre-built DockerHub images (version controlled by `TAZAMA_VERSION` in `.env`) |

**Compose chain used (appended to tazama-core project):**

GitHub builds:
```
docker compose --env-file .env --env-file secrets.env -p tazama-core -f ./docker-compose.dev.extensions.apis.yaml up -d
```

DockerHub images:
```
docker compose --env-file .env --env-file secrets.env -p tazama-core -f ./docker-compose.hub.extensions.apis.yaml up -d
```

Both files deploy:
- `event-monitoring-service` -- Data Enrichment Monitoring Service (port `3002`)
- `data-enrichment-service` -- Data Enrichment API (port `3001`)

## 4.2. Server B extensions stack

Options 3 and 4 deploy the full extensions infrastructure and services. The launcher prompts:

```text
Include pgAdmin? [y/N]:
```

pgAdmin is an optional add-on. See Section 5.2 for details.

The launcher also automatically copies `../core/auth/test-public-key.pem` into `./auth/` if it is not already present. TCS and TRS require this key for JWT validation.

Before it runs Docker Compose, the launcher brings the two values derived from `TAZAMA_SFTP_PASSWORD` in `secrets.env` up to date (`utils/sftp-derived-secrets.ps1` or `.sh`):

- `TAZAMA_SFTP_PASSWORD_HASH`: the SHA-512 crypt hash the `sftp` container receives;
- `TAZAMA_TCS_SFTP_PASSWORD_ENCRYPTED`: the password encrypted with `TAZAMA_ENRICHMENT_ENCRYPTION_KEY` for connection-studio.

A value that already matches the password is kept, including one you made by hand. An empty or outdated value is derived again and its line in `secrets.env` is rewritten; the launcher prints which key it updated, never the value. The password is processed on this machine only: it does not appear on a command line or in a container. If `TAZAMA_SFTP_PASSWORD` is empty or longer than 15 bytes, or `TAZAMA_ENRICHMENT_ENCRYPTION_KEY` is not exactly 32 bytes, the launcher stops before deploying. On Linux and macOS this step needs `openssl`; where it has no `passwd -6` (LibreSSL on macOS), the hash is computed in the `atmoz/sftp` image, with the password passed on standard input.

It then brings `TAZAMA_DEVTESTOPS_GITHUB_TOKEN_ENCRYPTED` up to date (`utils/devtestops-derived-secrets.ps1` or `.sh`): `TAZAMA_DEVTESTOPS_GITHUB_PAT` encrypted with `TAZAMA_DEVTESTOPS_ENCRYPTION_KEY` and `TAZAMA_DEVTESTOPS_ENCRYPTION_IV` for `rule-studio-devtestops`. While any of the three is empty, the token stays empty, the launcher says so, and the deployment continues without a working `rule-studio-devtestops` (Section 5.3). If all three are set but the key is not exactly 32 bytes or the IV not exactly 16 bytes, the launcher stops before deploying.

> [!NOTE]
> A `secrets.env` created before `rule-studio-devtestops` was added lacks its four `TAZAMA_DEVTESTOPS_*` lines, and Docker Compose then stops with "set it in extensions/secrets.env (may be empty)". Copy the four lines from `secrets.env.template` (they may stay empty). The launcher's **Audit secrets** option lists missing keys.

| Option | Build source |
|---|---|
| 3 | GitHub source builds (branches controlled in `.env`) |
| 4 | Pre-built DockerHub images (version controlled by `TAZAMA_VERSION`) |

**Compose chain used (GitHub builds example):**

```
docker compose --env-file .env --env-file secrets.env -p tazama-extensions \
  -f ./docker-compose.extensions.infrastructure.yaml \
  -f ./docker-compose.dev.extensions.yaml \
  [-f ./docker-compose.utils.pgadmin.yaml]   # if pgAdmin is selected
  up -d
```

The `docker-compose.hub.extensions.yaml` file replaces `docker-compose.dev.extensions.yaml` for DockerHub image deployments.

## 4.3. Utilities and teardown

Option 5 in the launcher provides teardown and utility commands:

```text
Utilities:
  1. Tear down extensions stack  (Server B)
  2. Remove DEMS + DEAPI         (Server A)
  3. Tear down all
  4. Start pgAdmin               (Server B)
```

All teardown commands also remove volumes (`--volumes`). Data stored in PostgreSQL, SFTP, CouchDB, and OpenSearch will be permanently deleted.

<div style="text-align: right"><a href="#top">Top</a></div>

# 5. OVERVIEW OF SERVICES

## 5.1. Server A APIs (joined to tazama-core)

These services run on Server A and join the `tazama-core` Docker Compose project:

| Service | Container | Port | Description |
|---|---|---|---|
| DEAPI | `data-enrichment-service` | 3001 | Data Enrichment API -- enriches transaction data with external information |
| DEMS | `event-monitoring-service` | 3002 | Data Enrichment Monitoring Service -- monitors data enrichment activity |

## 5.2. Extensions infrastructure (Server B)

These infrastructure services are started as part of the `tazama-extensions` Compose project:

| Service | Container | Port | Description |
|---|---|---|---|
| PostgreSQL | `extensions-postgres` | 15433 | Dedicated PostgreSQL instance for CMS and extensions services |
| SFTP | `sftp` | 12222 | SFTP server for transaction file uploads (used by TCS) |
| CouchDB | `couchdb` | 5984 | Document database for CMS audit and case data |
| Flowable | `flowable` | 8081 | Workflow engine for CMS case lifecycle management |
| OpenSearch | `opensearch` | 9200 | Audit log store for TCS, TRS, and CMS (forensic audit trail) |
| OpenSearch init | `opensearch-init` | -- | One-shot container: applies audit index template (30s refresh, async translog, 0 replicas) on first start |
| DB Migration | `case-management-system-migrate` | -- | One-shot container: applies CMS schema to PostgreSQL on startup |
| pgAdmin | `extensions-pgadmin` | 5051 | Optional PostgreSQL web UI (included if pgAdmin is selected) |

> [!NOTE]
> The PostgreSQL instance in the extensions stack (port 15433) is separate from the core PostgreSQL instance (port 15432). The CMS and extensions services connect to the extensions PostgreSQL; the core processors connect to the core PostgreSQL.

## 5.3. Extensions services (Server B)

| Service | Container | Port | Description |
|---|---|---|---|
| TCS backend | `connection-studio-backend` | 3010 | Transaction Configuration Studio API |
| TCS frontend | `connection-studio-frontend` | 5173 | Transaction Configuration Studio web UI |
| TRS backend | `rule-studio-backend` | 3005 | Transaction Rule Studio API |
| TRS frontend | `rule-studio-frontend` | 5174 | Transaction Rule Studio web UI |
| TRS DevTestOps | `rule-studio-devtestops` | 3050 | Creates and manages rule repositories in a GitHub organisation and runs their tests, for the TRS frontend. Needs a GitHub PAT, key and IV in `secrets.env` and `GITHUB_ORG_NAME` in `env/rule-studio-devtestops.env` (Section 8.5); without them it restarts in a loop, and the other services are unaffected |
| CMS backend | `case-management-system-backend` | 3090 | Case Management System API |
| CMS frontend | `case-management-system-frontend` | 5175 | Case Management System web UI |
| Voila | `case-management-system-voila` | 18866 | Voila notebook server - serves CMS visualisation notebooks (account network, alert history, conditions timeline, counterparty network, transaction graphs) embedded in the CMS frontend |

<div style="text-align: right"><a href="#top">Top</a></div>

# 6. ACCESSING DEPLOYED COMPONENTS

After a successful deployment, the following web interfaces are accessible from `localhost` (or the Server B IP address in a multi-server deployment):

#### Server A APIs
- DEAPI: <http://localhost:3001>
- DEMS: <http://localhost:3002>

#### Transaction Configuration Studio (TCS)
- TCS API: <http://localhost:3010>
- TCS UI: <http://localhost:5173>

#### Transaction Rule Studio (TRS)
- TRS API: <http://localhost:3005>
- TRS UI: <http://localhost:5174>
- TRS DevTestOps API: <http://localhost:3050> (health: `/api/health`)

#### Case Management System (CMS)
- CMS API: <http://localhost:3090>
- CMS UI: <http://localhost:5175>
- Voila notebooks: <http://localhost:18866>

#### Infrastructure
- OpenSearch: <http://localhost:9200>
- CouchDB: <http://localhost:5984>
- Flowable: <http://localhost:8081>
- SFTP: `sftp://localhost:12222` (user: `user`, password: `TAZAMA_SFTP_PASSWORD` from `extensions/secrets.env`). The `sftp` container receives only its hash, `TAZAMA_SFTP_PASSWORD_HASH`.
- PostgreSQL (extensions): `localhost:15433`
- pgAdmin (optional): <http://localhost:5051>

<div style="text-align: right"><a href="#top">Top</a></div>

# 7. TROUBLESHOOTING TIPS

### TCS or TRS show authentication errors

TCS and TRS validate JWTs using the public key mounted from `./auth/test-public-key.pem`. If this file does not exist, the services will reject all authenticated requests. The launcher script copies the key from `../core/auth/test-public-key.pem` automatically, but if the copy failed (e.g. core was not yet cloned), copy it manually:

```
copy ..\core\auth\test-public-key.pem .\auth\test-public-key.pem
```

### CMS backend fails to start

The CMS backend depends on `case-management-system-migrate`, `flowable`, and `opensearch`. OpenSearch takes up to 60 seconds to become healthy on a cold start. If the CMS backend exits immediately, wait for OpenSearch to finish initialising and then re-run the compose command, or restart the container:

```
docker restart case-management-system-backend
```

If the backend exits immediately with a config-validation error naming `SESSION_COOKIE_SECURE`, `SESSION_COOKIE_SAMESITE`, or `CORS_ALLOWED_ORIGINS`, these three variables are required and must be set in `extensions/env/case-management-system.env`:

| Deployment | `SESSION_COOKIE_SECURE` | `SESSION_COOKIE_SAMESITE` | `CORS_ALLOWED_ORIGINS` |
| --- | --- | --- | --- |
| Local / plain HTTP | `false` | `lax` | `http://localhost:5175` (the frontend origin) |
| Production / HTTPS | `true` | `strict` | the public HTTPS frontend origin(s), comma-separated |

> On plain HTTP, `SESSION_COOKIE_SECURE=true` can silently break login: most browsers discard the session cookie so every request 401s (behaviour varies by browser and host — e.g. Chromium still permits `Secure` cookies on `localhost`). `CORS_ALLOWED_ORIGINS` must be the frontend origin, not the backend URL.

### DEMS/DEAPI pre-flight fails with "tazama-core is not running"

Ensure you have started the core stack on this machine first using `tazama-core.bat` (or `.sh`) from the `core/` folder. The pre-flight launcher checks for a running `tazama-core` Compose project before deploying.

### OpenSearch container exits at startup

OpenSearch requires `vm.max_map_count` to be at least 262144. On Linux/WSL:
```bash
sudo sysctl -w vm.max_map_count=262144
```

To persist across reboots, add `vm.max_map_count=262144` to `/etc/sysctl.conf`.

<div style="text-align: right"><a href="#top">Top</a></div>

# 8. APPENDIX

## 8.1. Authentication public key

TCS and TRS validate incoming JWT tokens using an RSA public key. The key pair is generated by the Tazama Authentication Service and lives in `core/auth/`. The extensions launcher automatically copies the public key to `extensions/auth/test-public-key.pem` when deploying the Server B extensions stack.

If you are deploying on separate machines (Server A and Server B), you must manually copy the file from Server A to Server B before starting the extensions stack:

```
scp <server-a>:/<path>/tazama-stack/core/auth/test-public-key.pem \
    ./<path>/tazama-stack/extensions/auth/test-public-key.pem
```

In the AWS deployment, the deploy scripts handle this step automatically -- see [infra/aws/aws-deployment-instructions.md](../infra/aws/aws-deployment-instructions.md) Section D.3.

<div style="text-align: right"><a href="#top">Top</a></div>

## 8.2. Docker Compose YAML structure

View this file for additional detail about the Docker Compose files in this stack and how they relate to each other: [Docker Compose YAML Structure Overview](./docker-yaml-structure.md)

<div style="text-align: right"><a href="#top">Top</a></div>

## 8.3. Original default values

Before `secrets.env` existed, these values were committed in the compose and env files. They are public, so use them for local development only and never on a reachable server. Keys marked MUST MATCH in the template need the same value in `core/secrets.env` or `biar/secrets.env` (see [root README section 6.2](../README.md#62-values-shared-between-stacks)).

| Key | Original default | Used by |
|---|---|---|
| `TAZAMA_EXT_PG_PASSWORD` | `unused` | extensions-postgres, CMS, Flowable |
| `TAZAMA_CORE_PG_PASSWORD` | `unused` | connection-studio, DEAPI, DEMS |
| `TAZAMA_VALKEY_PASSWORD` | `redis-password` (Valkey had no password before) | DEAPI, DEMS, CMS, rule-studio |
| `TAZAMA_PGADMIN_PASSWORD` | `password` | extensions pgAdmin |
| `TAZAMA_SFTP_PASSWORD` | `password` | source of the two keys below (no container reads it directly) |
| `TAZAMA_SFTP_PASSWORD_HASH` | `'$6$tazamadefault$Q5r5hP4JCyXsKOlkUduv2m/urCS/YaekDWkNhUMIvhLHpRzi6fIqXJF.7TPBrzbJRzgFdKgStAjQQ1KuVgCV6/'` (`password` as a SHA-512 crypt hash; new key, generated by the launcher - leave it empty, or use this value in single quotes) | sftp |
| `TAZAMA_TCS_SFTP_PASSWORD_ENCRYPTED` | `5af1a07c4d63493121dfc55c33c8c1f2:245d2f2b4b0d373de787c8dac373d9fe` (`password` encrypted with the key below; generated by the launcher - leave it empty, or use this value) | connection-studio |
| `TAZAMA_ENRICHMENT_ENCRYPTION_KEY` | `8fj29dkd82hs91kd93kd82hs91kd83ks` | connection-studio, DEAPI |
| `TAZAMA_FLOWABLE_PASSWORD` | `test` | Flowable, CMS |
| `TAZAMA_OPENSEARCH_PASSWORD` | `admin` | CMS, connection-studio, rule-studio |
| `TAZAMA_COUCHDB_USERNAME` | `simon` | CouchDB, CMS |
| `TAZAMA_COUCHDB_PASSWORD` | `1234` | CouchDB, CMS |
| `TAZAMA_COUCHDB_COOKIE_SECRET` | (none - generate: `openssl rand -hex 32`) | CouchDB |
| `TAZAMA_DOCKERHUB_USERNAME` | (placeholder - a real Docker Hub account is needed) | rule-studio backend |
| `TAZAMA_DOCKERHUB_TOKEN` | (placeholder - a personal access token of that account is needed) | rule-studio backend |
| `TAZAMA_DEVTESTOPS_GITHUB_PAT` | (none - new key; a real fine-grained PAT is needed, Section 8.5; empty = service does not start) | source of `TAZAMA_DEVTESTOPS_GITHUB_TOKEN_ENCRYPTED` (no container reads it directly) |
| `TAZAMA_DEVTESTOPS_ENCRYPTION_KEY` | (none - new key; generate: `openssl rand -hex 16`) | rule-studio-devtestops |
| `TAZAMA_DEVTESTOPS_ENCRYPTION_IV` | (none - new key; generate: `openssl rand -hex 8`) | rule-studio-devtestops |
| `TAZAMA_DEVTESTOPS_GITHUB_TOKEN_ENCRYPTED` | (none - new key, derived by the launcher; leave it empty) | rule-studio-devtestops |
| `TAZAMA_SMTP_USER` | (empty) | CMS, connection-studio |
| `TAZAMA_SMTP_PASS` | (empty) | CMS, connection-studio |
| `TAZAMA_APM_SECRET_TOKEN` | (empty) | DEAPI |

<div style="text-align: right"><a href="#top">Top</a></div>

## 8.4. Generating the SFTP values by hand

The launcher derives `TAZAMA_SFTP_PASSWORD_HASH` and `TAZAMA_TCS_SFTP_PASSWORD_ENCRYPTED` from `TAZAMA_SFTP_PASSWORD` before every deployment of the extensions stack (Section 4.2). You need this section only if you run `docker compose` yourself, or prefer to make the values yourself.

The quickest way is the launcher's own step, which updates `secrets.env` without deploying anything. Run it from the repository root:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File utils/sftp-derived-secrets.ps1 -GroupDir extensions   # Windows
bash utils/sftp-derived-secrets.sh extensions                                                           # Linux, macOS, Git Bash
```

To make the values entirely by hand, use one of the procedures below. They prompt for the password without showing it, so it does not end up on a command line, in your shell history or in a container. They read `TAZAMA_ENRICHMENT_ENCRYPTION_KEY` from `secrets.env`, so set that key first. Run them from the `extensions/` folder, with the same password as `TAZAMA_SFTP_PASSWORD` (at most 15 bytes). Each one prints two lines; replace the two keys in `secrets.env` with them, then run the launcher's **Audit secrets** option to check the result.

Values made by hand use a random salt and IV, so they differ from the ones the launcher derives. The launcher keeps them anyway, because it only replaces values that do not match the password.

**bash with OpenSSL 1.1.1 or later (Linux, WSL, Git Bash):**

```bash
read -rsp 'SFTP password: ' P; echo
KEY=$(sed -n 's/^TAZAMA_ENRICHMENT_ENCRYPTION_KEY=//p' secrets.env | tail -n 1 | tr -d "\r'\"")
SALT=$(openssl rand -hex 8)
HASH=$(printf '%s\n' "$P" | openssl passwd -6 -salt "$SALT" -stdin)
IV=$(openssl rand -hex 16)
CT=$(printf '%s' "$P" | openssl enc -aes-256-cbc -K "$(printf '%s' "$KEY" | od -An -v -tx1 | tr -d ' \n')" -iv "$IV" | od -An -v -tx1 | tr -d ' \n')
echo "TAZAMA_SFTP_PASSWORD_HASH='$HASH'"
echo "TAZAMA_TCS_SFTP_PASSWORD_ENCRYPTED=$IV:$CT"
unset P KEY SALT HASH IV CT
```

The password reaches `openssl` on standard input only. The encryption key is passed to `openssl enc` as an argument (`-K`), so other users of the same machine could see it in the process list for that moment.

**PowerShell 5.1 or 7 (Windows):**

```powershell
. ..\utils\sha512-crypt.ps1   # SHA-512 crypt function (Windows has none built in)
$s = Read-Host 'SFTP password' -AsSecureString
$b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
$p = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b); [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)
$key = (Get-Content secrets.env | Where-Object { $_ -match '^TAZAMA_ENRICHMENT_ENCRYPTION_KEY=' } | Select-Object -Last 1) -replace '^[^=]+=', '' -replace '^[''"]|[''"]$', ''
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
$rb = New-Object byte[] 16; $rng.GetBytes($rb)
$salt = -join ($rb | ForEach-Object { './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'[$_ -band 63] })
$aes = [Security.Cryptography.Aes]::Create(); $aes.Key = [Text.Encoding]::UTF8.GetBytes($key); $aes.GenerateIV()
$pb = [Text.Encoding]::UTF8.GetBytes($p)
$ct = $aes.CreateEncryptor().TransformFinalBlock($pb, 0, $pb.Length)
"TAZAMA_SFTP_PASSWORD_HASH='$(Get-Sha512Crypt -Password $p -Salt $salt)'"
"TAZAMA_TCS_SFTP_PASSWORD_ENCRYPTED=$(-join ($aes.IV | ForEach-Object { $_.ToString('x2') })):$(-join ($ct | ForEach-Object { $_.ToString('x2') }))"
Remove-Variable s, b, p, key, pb, ct
```

`Aes` uses CBC mode and PKCS7 padding by default, as connection-studio expects. Everything runs inside PowerShell; the history records the commands, not the password.

<div style="text-align: right"><a href="#top">Top</a></div>

## 8.5. Generating the DevTestOps token by hand

`rule-studio-devtestops` creates rule repositories from a template in a GitHub organisation and runs their tests. It needs:

- `GITHUB_ORG_NAME` in `env/rule-studio-devtestops.env`: the organisation the rule repositories are created in;
- `TAZAMA_DEVTESTOPS_GITHUB_PAT` in `secrets.env`: a fine-grained personal access token whose resource owner is that organisation, with access to all its repositories and the permissions Administration, Contents and Workflows (read and write), Actions and Metadata (read);
- `TAZAMA_DEVTESTOPS_ENCRYPTION_KEY` (exactly 32 bytes, `openssl rand -hex 16`) and `TAZAMA_DEVTESTOPS_ENCRYPTION_IV` (exactly 16 bytes, `openssl rand -hex 8`) in `secrets.env`.

The service does not take the PAT itself: it decrypts `TAZAMA_DEVTESTOPS_GITHUB_TOKEN_ENCRYPTED` (the PAT encrypted with AES-256-CBC, lowercase hex, no IV prefix) with the key and IV. The launcher derives that value before every deployment of the extensions stack (Section 4.2). You need this section only if you run `docker compose` yourself.

The quickest way is the launcher's own step, which updates `secrets.env` without deploying anything. Run it from the repository root:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File utils/devtestops-derived-secrets.ps1 -GroupDir extensions   # Windows
bash utils/devtestops-derived-secrets.sh extensions                                                           # Linux, macOS, Git Bash
```

To make the value by hand, use one of the procedures below. They prompt for the PAT without showing it, and read the key and IV from `secrets.env`, so set those first. Run them from the `extensions/` folder. Each prints one line; replace the key in `secrets.env` with it, then run the launcher's **Audit secrets** option to check the result. The IV is fixed, so the value is the same as the one the launcher derives.

**bash with OpenSSL (Linux, WSL, Git Bash, macOS):**

```bash
read -rsp 'GitHub PAT: ' P; echo
KEY=$(sed -n 's/^TAZAMA_DEVTESTOPS_ENCRYPTION_KEY=//p' secrets.env | tail -n 1 | tr -d "\r'\"")
IV=$(sed -n 's/^TAZAMA_DEVTESTOPS_ENCRYPTION_IV=//p' secrets.env | tail -n 1 | tr -d "\r'\"")
CT=$(printf '%s' "$P" | openssl enc -aes-256-cbc -K "$(printf '%s' "$KEY" | od -An -v -tx1 | tr -d ' \n')" -iv "$(printf '%s' "$IV" | od -An -v -tx1 | tr -d ' \n')" | od -An -v -tx1 | tr -d ' \n')
echo "TAZAMA_DEVTESTOPS_GITHUB_TOKEN_ENCRYPTED=$CT"
unset P KEY IV CT
```

The PAT reaches `openssl` on standard input only. The key and IV are passed to `openssl enc` as arguments (`-K`, `-iv`), so other users of the same machine could see them in the process list for that moment.

**PowerShell 5.1 or 7 (Windows):**

```powershell
$s = Read-Host 'GitHub PAT' -AsSecureString
$b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
$p = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b); [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)
$read = { param($k) (Get-Content secrets.env | Where-Object { $_ -match "^$k=" } | Select-Object -Last 1) -replace '^[^=]+=', '' -replace '^[''"]|[''"]$', '' }
$aes = [Security.Cryptography.Aes]::Create()
$aes.Key = [Text.Encoding]::UTF8.GetBytes((& $read 'TAZAMA_DEVTESTOPS_ENCRYPTION_KEY'))
$aes.IV = [Text.Encoding]::UTF8.GetBytes((& $read 'TAZAMA_DEVTESTOPS_ENCRYPTION_IV'))
$pb = [Text.Encoding]::UTF8.GetBytes($p)
$ct = $aes.CreateEncryptor().TransformFinalBlock($pb, 0, $pb.Length)
"TAZAMA_DEVTESTOPS_GITHUB_TOKEN_ENCRYPTED=$(-join ($ct | ForEach-Object { $_.ToString('x2') }))"
Remove-Variable s, b, p, pb, ct
```

Setting `Key` or `IV` fails if the key is not 32 bytes or the IV not 16 bytes.

<div style="text-align: right"><a href="#top">Top</a></div>
