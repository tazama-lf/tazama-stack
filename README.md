<!-- SPDX-License-Identifier: Apache-2.0 -->

<a id="top"></a>

<h1></h1>
<h1 style="color: red;">WARNING - THIS TAZAMA REPOSITORY IS TO BE USED FOR DEMONSTRATION, EXPLORATION AND TESTING PURPOSES ONLY.</h1>

- [1. INTRODUCTION](#1-introduction)
- [2. REPOSITORY STRUCTURE](#2-repository-structure)
- [3. STACK OVERVIEW](#3-stack-overview)
  - [3.1. Core (`core/`)](#31-core-core)
  - [3.2. Extensions (`extensions/`)](#32-extensions-extensions)
  - [3.3. BIAR (`biar/`)](#33-biar-biar)
- [4. DEPLOYMENT OPTIONS](#4-deployment-options)
  - [4.1. Local single-machine deployment](#41-local-single-machine-deployment)
  - [4.2. AWS multi-server deployment](#42-aws-multi-server-deployment)
- [5. PRE-REQUISITES](#5-pre-requisites)
- [6. SECRETS](#6-secrets)
  - [6.1. One secrets.env per stack](#61-one-secretsenv-per-stack)
  - [6.2. Values shared between stacks](#62-values-shared-between-stacks)
  - [6.3. Value rules](#63-value-rules)
  - [6.4. Running docker compose by hand](#64-running-docker-compose-by-hand)
  - [6.5. Changing a secret after the first deployment](#65-changing-a-secret-after-the-first-deployment)
  - [6.6. Checking your setup](#66-checking-your-setup)
  - [6.7. AWS deployment](#67-aws-deployment)
- [7. QUICK START (LOCAL)](#7-quick-start-local)
- [8. MAINTAINING THE SECRETS TEMPLATES](#8-maintaining-the-secrets-templates)

<h1></h1>
<h1 style="color: red;">WARNING - THIS TAZAMA REPOSITORY IS TO BE USED FOR DEMONSTRATION, EXPLORATION AND TESTING PURPOSES ONLY.</h1>

For production deployment instructions:
 - [On-Premise Detailed Installation Guide](https://github.com/tazama-lf/On-Prem-helm)
 - [AWS Detailed Installation Guide](https://github.com/tazama-lf/EKS-helm)
 - [Google Cloud Detailed Installation Guide](https://github.com/tazama-lf/GKE-helm)
 - [Azure Detailed Installation Guide](https://github.com/tazama-lf/AKS-helm)

# 1. INTRODUCTION

This repository contains the full Tazama stack as a set of composable Docker Compose configurations. It is intended for local development, exploration, testing, and sandbox deployments. It is **not** a production deployment.

The stack is divided into three independent sub-folders, each with its own README, launcher scripts, and Docker Compose files:

| Folder | Stack | Deployed to |
|---|---|---|
| [`core/`](core/README.md) | Core transaction processing pipeline | Server A |
| [`extensions/`](extensions/README.md) | Studios and Case Management System | Server B (APIs on Server A) |
| [`biar/`](biar/README.md) | Business Intelligence, Analytics, and Reporting | Server C |

Each stack can be deployed independently on the same machine for local development, or on separate servers for a closer-to-production sandbox on AWS.

<div style="text-align: right"><a href="#top">Top</a></div>

# 2. REPOSITORY STRUCTURE

```
tazama-stack/
|-- core/               Core stack -- TMS, processors, rules, Keycloak, PostgreSQL, NATS, Valkey
|-- extensions/         Extensions stack -- TCS, TRS, CMS, OpenSearch, SFTP, CouchDB, Flowable
|-- biar/               BIAR stack -- NiFi, Ozone, Solr, Tika
|   (each stack folder: .env = configuration, secrets.env.template = credentials template;
|    your secrets.env is gitignored -- see section 6)
|-- utils/              Tenant onboarding and secrets audit/check scripts
|-- infra/
|   |-- aws/            AWS OpenTofu infrastructure and deploy scripts
|       |-- aws-deployment-instructions.md    Full AWS deployment guide
|       |-- scripts/    PowerShell deploy scripts (deploy.ps1, deploy-core.ps1, etc.)
|       |-- terraform/  OpenTofu (Terraform) configurations for VPC, EC2, ALB, Route 53
```

<div style="text-align: right"><a href="#top">Top</a></div>

# 3. STACK OVERVIEW

## 3.1. Core (`core/`)

The core stack is the heart of Tazama. It runs the transaction monitoring pipeline and all supporting infrastructure.

**Services:**
- PostgreSQL -- primary database (port 15432)
- NATS -- pub/sub messaging (ports 14222, 16222, 18222)
- Valkey -- in-memory cache (port 16379)
- Transaction Monitoring Service (TMS) API -- port 5000
- Admin Service API -- port 5100
- Event Director, Typology Processor, Event Adjudicator, rule processors
- Keycloak (Authentication) -- port 8080
- Authentication Service API -- port 3020
- NATS Utilities (REST proxy) -- port 4000
- pgAdmin (optional) -- port 15050
- Hasura GraphQL (optional) -- port 6100
- Lumberjack logging (optional)
- Demo UI (optional) -- port 3001

**Launcher:** `core/tazama-core.bat` (Windows) / `core/tazama-core.sh` (Unix)

See [core/README.md](core/README.md) for full installation instructions.

## 3.2. Extensions (`extensions/`)

The extensions stack provides the browser-based configuration studios and case management system. It also contributes two API services (DEMS and DEAPI) that are deployed onto the core server and join the `tazama-core` Docker Compose project.

**Server A APIs (joined to core):**
- Data Enrichment API (DEAPI) -- port 3001
- Data Enrichment Monitoring Service (DEMS) -- port 3002

**Server B infrastructure and services:**
- PostgreSQL (extensions) -- port 15433
- SFTP -- port 12222
- CouchDB -- port 5984
- Flowable -- port 8081
- OpenSearch -- port 9200
- Transaction Configuration Studio (TCS) -- API port 3010, UI port 5173
- Transaction Rule Studio (TRS) -- API port 3005, UI port 5174
- Case Management System (CMS) -- API port 3090, UI port 5175
- Voila notebook server -- port 18866
- pgAdmin (optional) -- port 5051

**Launcher:** `extensions/tazama-extensions.bat` (Windows) / `extensions/tazama-extensions.sh` (Unix)

**Pre-requisite:** The core stack must be running before DEMS/DEAPI are deployed.

See [extensions/README.md](extensions/README.md) for full installation instructions.

## 3.3. BIAR (`biar/`)

The BIAR stack provides a data ingestion and reporting pipeline that reads from the PostgreSQL instances on both the core server and the extensions server.

**Services:**
- Apache NiFi (data flow) -- port 8088
- Apache Ozone (object storage) -- S3G port 9878, OM port 9874, Recon port 9888, SCM port 9876
- Apache Solr (search/indexing) -- port 8983
- Apache Tika (document analysis) -- port 9998

**Launcher:** `biar/tazama-biar.bat` (Windows) / `biar/tazama-biar.sh` (Unix)

**Pre-requisite:** The core stack must be running and reachable at `SERVER_A_HOST:14222` before the BIAR stack is started.

See [biar/README.md](biar/README.md) for full installation instructions.

<div style="text-align: right"><a href="#top">Top</a></div>

# 4. DEPLOYMENT OPTIONS

## 4.1. Local single-machine deployment

All three stacks can run on a single machine for local development. The launcher scripts default `SERVER_A_HOST` and `SERVER_B_HOST` to `localhost` or `host.docker.internal` as appropriate. Deploy in order:

1. **Core** -- Start `core/tazama-core.bat` and select a deployment type
2. **Extensions** (optional) -- Run `extensions/tazama-extensions.bat`:
   - First deploy DEMS + DEAPI (pre-flight, options 1 or 2)
   - Then deploy the extensions stack (options 3 or 4)
3. **BIAR** (optional) -- Start `biar/tazama-biar.bat` (option 1)

Each stack is independent. You can run core alone, or core + extensions, or all three. BIAR works best when extensions is also running so that it has CMS data to ingest.

## 4.2. AWS multi-server deployment

For a sandbox environment on AWS that mirrors a closer-to-production topology, the three stacks are deployed to separate EC2 instances across a private VPC:

| Server | Role | Stack |
|---|---|---|
| Server A | Core + DEMS/DEAPI | `core/` + extensions APIs |
| Server B | Extensions | `extensions/` |
| Server C | BIAR | `biar/` |

Infrastructure is provisioned with OpenTofu (Terraform-compatible) from the `infra/aws/` folder. Deployment to the instances is handled by PowerShell scripts that tunnel over AWS EC2 Instance Connect (EICE) -- no SSH keys or open port 22 required.

Full instructions: [infra/aws/aws-deployment-instructions.md](infra/aws/aws-deployment-instructions.md)

<div style="text-align: right"><a href="#top">Top</a></div>

# 5. PRE-REQUISITES

For a local deployment you will need:

- Git
- Code editor (VS Code recommended)
- Docker Desktop for Windows with WSL (or Linux/macOS equivalent)
- GitHub personal access token with `read:packages` permissions (required for core and extensions; not required for biar)

> [!NOTE]
> Set your GitHub personal access token as a Windows environment variable named `GH_TOKEN`, then authenticate Docker:
> ```powershell
> echo $env:GH_TOKEN | docker login ghcr.io -u <your-github-username> --password-stdin
> ```

For the AWS deployment you will additionally need:

- AWS CLI configured with a profile that has the necessary IAM permissions (see the AWS deployment guide)
- OpenTofu (`tofu`) -- <https://opentofu.org/docs/intro/install/>
- PowerShell 7+ (for the deploy scripts)

<div style="text-align: right"><a href="#top">Top</a></div>

# 6. SECRETS

No credential is committed to this repository. Every password, client secret and key a service needs comes from a `secrets.env` file that you create in each stack folder. The committed `.env` files hold configuration only (ports, hosts, versions, feature flags).

## 6.1. One secrets.env per stack

| Stack folder | Template | You create | Needed for |
|---|---|---|---|
| `core/` | `core/secrets.env.template` | `core/secrets.env` | every core deployment |
| `extensions/` | `extensions/secrets.env.template` | `extensions/secrets.env` | DEMS/DEAPI and the extensions stack |
| `biar/` | `biar/secrets.env.template` | `biar/secrets.env` | the BIAR stack |

Copy the template to `secrets.env` in the same folder and fill in every `[required]` key. `[optional]` keys may stay empty. Each key in the template has a comment that says which services use it and any rule its value must follow.

For a local development machine, each stack README has a section **Original default values** with the public test values the stack used before #298. They are published and therefore not secret: use them on your own machine only, never on a shared or internet-facing server.

`secrets.env` is gitignored (`**/secrets.env`). To confirm, run `git check-ignore -v core/secrets.env`; it must print the matching `.gitignore` rule.

## 6.2. Values shared between stacks

Some credentials are used by more than one stack. The key has the same name in each `secrets.env` and **must hold the same value** in all of them (the templates mark these keys `MUST MATCH`):

| Key | core | extensions | biar | What it is |
|---|:---:|:---:|:---:|---|
| `TAZAMA_CORE_PG_PASSWORD` | x | x | x | `postgres` password of core-postgres |
| `TAZAMA_EXT_PG_PASSWORD` | | x | x | `postgres` password of extensions-postgres |
| `TAZAMA_VALKEY_PASSWORD` | x | x | | Valkey cache password |
| `TAZAMA_COUCHDB_USERNAME` | | x | x | CouchDB admin account |
| `TAZAMA_COUCHDB_PASSWORD` | | x | x | CouchDB admin password |
| `TAZAMA_JUPYTERHUB_OIDC_CLIENT_SECRET` | x | | x | Keycloak `jupyterhub` client secret |
| `TAZAMA_NIFI_OIDC_CLIENT_SECRET` | x | | x | Keycloak `nifi` client secret (NiFi keycloak mode) |

`TAZAMA_PGADMIN_PASSWORD` and `TAZAMA_APM_SECRET_TOKEN` appear in more than one template but are independent per stack.

## 6.3. Value rules

- No spaces, quotes or `$` in any value. Docker Compose reads `secrets.env` as a dotenv file and would strip quotes or expand `$`.
- The Postgres and CouchDB keys are placed inside connection URLs as they are. Use only letters, digits and `-` `_` `.` `~` for them.
- Some keys have their own rules (length, allowed characters, derived values); see the comment above the key in the template.
- To generate a random value: `openssl rand -hex 24` (bash) or `[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLower()` (PowerShell 7).

## 6.4. Running docker compose by hand

The launchers load the secrets for you. When you run `docker compose` yourself with `-f` files, run it from the stack folder and pass both files:

```powershell
docker compose --env-file .env --env-file secrets.env -p tazama-core -f docker-compose.base.infrastructure.yaml ... up -d
```

An explicit `--env-file` turns off the automatic loading of `.env`, so `.env` must be listed too, before `secrets.env`.

To avoid typing the flags, you can set them for the current shell session only, while you work in one stack folder:

```powershell
$env:COMPOSE_ENV_FILES = '.env,secrets.env'      # PowerShell
export COMPOSE_ENV_FILES=.env,secrets.env         # bash
```

Do not set `COMPOSE_ENV_FILES` permanently or system-wide: Compose resolves the paths against the current folder and stops with an error in every other folder that has no `secrets.env`.

Commands that use only the project name (`docker compose -p tazama-core down`, `ps`, `logs`) do not read compose files and need no env files.

If a key is missing or empty, Compose stops before it starts anything:

```
required variable TAZAMA_HASURA_ADMIN_SECRET is missing a value: set it in core/secrets.env
```

If `secrets.env` itself is missing, the launchers stop with a message that points to this section; Compose reports `couldn't find env file`.

## 6.5. Changing a secret after the first deployment

Most services read their secret at every container start: change the value in `secrets.env` and redeploy the stack (or the services that use the key).

Some services store the value when their volume or database is first initialised and ignore later changes:

| Secret | Stored by | To change it |
|---|---|---|
| `TAZAMA_CORE_PG_PASSWORD`, `TAZAMA_EXT_PG_PASSWORD` | Postgres volume | `ALTER USER postgres PASSWORD '...'` in the container, then update `secrets.env` and redeploy |
| `TAZAMA_KEYCLOAK_ADMIN_PASSWORD` | Keycloak database | change the `admin` password in the Keycloak admin console first |
| `TAZAMA_PGADMIN_PASSWORD` | pgAdmin volume | change it in pgAdmin first |
| `TAZAMA_FLOWABLE_PASSWORD` | Flowable database | change the `rest-admin` password in Flowable first |
| `TAZAMA_AUTH_CLIENT_SECRET`, `TAZAMA_RELAY_AUTH_PASSWORD`, `TAZAMA_JUPYTERHUB_OIDC_CLIENT_SECRET`, `TAZAMA_NIFI_OIDC_CLIENT_SECRET` | Keycloak realm (imported on the first start only) | change the client secret or user password in Keycloak too |

On a local machine you can instead remove the stack's volumes (`docker compose ... down -v`). This deletes all data in them.

## 6.6. Checking your setup

Each launcher has an **Audit secrets** option. It compares your `secrets.env` with the template without printing any value, and reports missing, empty or unknown keys. For the extensions stack it also checks that `TAZAMA_TCS_SFTP_PASSWORD_ENCRYPTED` decrypts to `TAZAMA_SFTP_PASSWORD`, and that `TAZAMA_SFTP_PASSWORD` is at most 15 bytes (connection-studio currently decrypts longer values incorrectly). The scripts can also be run directly from the repository root: `powershell -NoProfile -ExecutionPolicy Bypass -File utils/audit-secrets.ps1 -GroupDir core` or `bash utils/audit-secrets.sh core`.

## 6.7. AWS deployment

On the AWS servers you do not create `secrets.env` by hand. The deploy scripts render it from AWS SSM Parameter Store (`/tazama/...`) on every deployment, with values single-quoted so any character is safe. See [infra/aws/aws-deployment-instructions.md](infra/aws/aws-deployment-instructions.md), section A.7, for the parameter list and how to change a value.

<div style="text-align: right"><a href="#top">Top</a></div>

# 7. QUICK START (LOCAL)

```powershell
# Clone the repository
git clone https://github.com/tazama-lf/tazama-stack -b main
cd tazama-stack

# Create the secrets file of each stack you deploy, then fill it in (section 6).
# For a local machine, the values are in each stack README, section "Original default values".
Copy-Item core\secrets.env.template core\secrets.env
Copy-Item extensions\secrets.env.template extensions\secrets.env
Copy-Item biar\secrets.env.template biar\secrets.env

# Start Docker Desktop, then deploy the core stack
cd core
.\tazama-core.bat        # choose option 2 (Public DockerHub) for the fastest start

# Optionally deploy the extensions stack (core must be running first)
cd ..\extensions
.\tazama-extensions.bat  # choose option 2 (DEMS+DEAPI, DockerHub), then option 4 (extensions, DockerHub)

# Optionally deploy the BIAR stack (core must be running first)
cd ..\biar
.\tazama-biar.bat        # choose option 1
```

After deploying the core stack, verify it is healthy:
```powershell
curl http://localhost:5000
# Expected: {"status":"UP"}
```

See each stack's README for detailed configuration options, service port listings, and troubleshooting guidance.

<div style="text-align: right"><a href="#top">Top</a></div>

# 8. MAINTAINING THE SECRETS TEMPLATES

When you add, rename or remove a credential in a compose file or env file:

1. Reference it as `${TAZAMA_<NAME>:?set it in <stack>/secrets.env}` (required) or `${TAZAMA_<NAME>?set it in <stack>/secrets.env}` (optional; may be empty). Never give it a default value.
2. Add the key to `<stack>/secrets.env.template` with a `[required]` or `[optional]` tag, the services that use it, its value rules, and `MUST MATCH` if another stack uses the same value.
3. Add a row to the **Original default values** table in the stack README.
4. For AWS, add the SSM mapping to `$Script:SecretsSsmMap` in `infra/aws/scripts/helpers.ps1` and the parameter to section A.7 of the AWS guide. The deploy scripts stop on a template key without a mapping.
5. Run the consistency check and fix every finding:

```powershell
pwsh -NoProfile -File utils/check-secrets-template.ps1
```

```bash
bash utils/check-secrets-template.sh
```

The check compares, in both directions, the `${TAZAMA_*}` references in the compose and env files, the template keys and the README table, and checks that each reference uses the form that matches its template tag.

<div style="text-align: right"><a href="#top">Top</a></div>
