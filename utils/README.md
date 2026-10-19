# Utility Scripts

Standalone operational and administrative utilities for a deployed Tazama stack. Each script is self-contained: the Python scripts use only the standard library, and the Node.js script uses only built-in modules. No package installation is required.

Unless stated otherwise, scripts target the Keycloak instance at `https://keycloak.beta.tazama.org` (realm `tazama`) by default and accept overrides via command-line options. The Keycloak admin password is read from the `KC_ADMIN_PW` environment variable or an `--admin-password` option. Never commit credentials to this repository.

## Index

| Script | Purpose |
| --- | --- |
| [add-tenant.py](add-tenant.py) | Onboard a new tenant organization: create its Keycloak groups and users (Python) |
| [add-tenant.js](add-tenant.js) | Same as add-tenant.py, implemented in Node.js |
| [smoke-test.py](smoke-test.py) | Validate a local authenticated full-service Core + Extensions deployment: containers, front-end logins and tenant groups |

## add-tenant.py / add-tenant.js

Adds a complete access pack for a new member organization of the Sandbox to a live Keycloak instance via the Admin REST API. The two implementations are functionally identical; use whichever runtime is convenient.

For a tenant with domain `example.org` and tenant ID `EXAMPLE`, the script:

1. Ensures the organization subgroup (named after the uppercased domain, e.g. `EXAMPLE.ORG`) exists under every service group path that Tazama access control uses:
   - `/tazama-cms/CMS_ADMIN`, `/tazama-cms/CMS_COMPLIANCE_OFFICER`, `/tazama-cms/CMS_INVESTIGATOR`, `/tazama-cms/CMS_SUPERVISOR`
   - `/tazama-tcs/approver`, `/tazama-tcs/editor`, `/tazama-tcs/exporter`, `/tazama-tcs/publisher`
   - `/tazama-trs/approver`, `/tazama-trs/editor`, `/tazama-trs/publisher`
   - `/tazama-jupyter/JUPYTER_USER`
   - `/tazama-batch` (optional), `/tazama-conditions`, `/tazama-config`, `/tazama-reports`, `/tazama-tms` (organization subgroup directly under the service group)
2. Sets the `TENANT_ID` attribute on every organization (leaf) subgroup to the value passed with `--tenant-id`. If a subgroup already exists without the attribute, it is healed in place, so re-running the script against an existing tenant repairs earlier gaps.
3. Creates 13 users (`cms-administrator@<domain>`, `cms-compliance-officer@`, `cms-investigator@`, `cms-supervisor@`, `tcs-approver@`, `tcs-editor@`, `tcs-exporter@`, `tcs-publisher@`, `trs-approver@`, `trs-editor@`, `trs-publisher@`, `tazama-api-client@`, `jupyter-user@`) with the shared password from `--password`. Existing users get their password reset. Users carry no `TENANT_ID` attribute of their own: the `tenant_id` token claim comes from the organization group they belong to.
4. Assigns each user to its group paths and prints an onboarding report.

The top-level service groups (including `/tazama-jupyter`) must already exist in the realm; the script stops with an error otherwise. The exception is `/tazama-batch`: when it is missing, its paths are skipped with a notice.

Users created by earlier versions of this script may still have a `TENANT_ID` user attribute. A user attribute takes precedence over the group value, so remove it in the Keycloak admin console if it is wrong. The `jupyter-user@` account inherits the `JUPYTER_USER` realm role from the `/tazama-jupyter/JUPYTER_USER` group, which is what JupyterHub's Keycloak login checks.

The tenant ID is deliberately an explicit argument and is never derived from the domain: the mapping is not mechanical (for example, the organization `processlab.tech` has tenant ID `CLEARDATA`).

Usage:

```
python add-tenant.py --domain example.org --tenant-id EXAMPLE --password <user-password> [--keycloak-url <url>] [--admin-user admin] [--admin-password <pw>] [--realm tazama] [--dry-run] [--seed-cms-reference-ids] [--psql-command <cmd>]

python add-tenant.py --tenant-id EXAMPLE --cms-seed-only [--psql-command <cmd>] [--dry-run]

node add-tenant.js --domain example.org --tenant-id EXAMPLE --password <user-password> [same options]
```

Use `--dry-run` to preview every group and user operation without making changes.

### Optional: seed CMS `reference_ids`

The Case Management System resolves each alert's reference ID per tenant from the `reference_ids` table in the `tazama_cms` database (extensions deployment). A tenant without rows there cannot have its alerts persisted. The script can seed the basic rows:

| txTp | referenceIdName |
| --- | --- |
| `pacs.008.001.10` | `EndToEndId` |
| `pacs.002.001.12` | `OrgnlEndToEndId` |

- `--seed-cms-reference-ids` runs the seed after the Keycloak steps.
- `--cms-seed-only` runs only the seed and skips Keycloak entirely; only `--tenant-id` is required. Use this for tenants that are already onboarded.
- `--psql-command <cmd>` (default `psql`) is the command that runs psql against `tazama_cms`. The SQL is passed on standard input. Connection details come from the command itself or the standard `PG*` environment variables.

Existing rows for the tenant are left untouched (`ON CONFLICT DO NOTHING`), so the seed is safe to re-run. The script prints the tenant's resulting rows. The tenant ID may only contain letters, digits, `_`, `.` and `-` when seeding.

Example, run on the extensions host:

```
python add-tenant.py --tenant-id EXAMPLE --cms-seed-only --psql-command "docker exec -i extensions-postgres psql -U postgres -d tazama_cms"
```

## smoke-test.py

Validates a local deployment after it starts. Unlike the other scripts, it targets the local Docker host and the default test realm, not the beta Keycloak. It supports one deployment shape only: Core deployed with `tazama-core.bat` option 3 (Full-service, DockerHub) with the auth add-on, plus Extensions deployed with `tazama-extensions.bat` option 4 (DockerHub). The DEMS/DEAPI add-on (Extensions option 2) is checked too if present. Any other shape, such as dev builds, multitenant or the public rules, makes the script stop with exit code 2.

The script checks:

1. **Deployment shape.** It reads the compose files recorded on the `tazama-core` and `tazama-extensions` containers and requires the full-service, auth and DockerHub files.
2. **Services and images.** It resolves the services in those same compose files and fails on any service without a container. It also fails on any image that was not pulled from a registry.
3. **Containers.** It waits up to `--wait` seconds for every container to be running, and healthy if it has a healthcheck. One-shot jobs, such as `hasura-init` and `case-management-system-migrate`, must have exited with code 0. Containers must then run for `--settle` seconds without restarting, which catches crash loops that only look "running" between restarts. A container that restarted before settling is a warning. So is a container whose healthcheck cannot execute in its image.
4. **Front-end loops (CMS, TCS, TRS).** For each front-end:
   - The page must be served.
   - The backend URL configured in the front-end container must answer the CORS preflight for the front-end's origin.
   - Every default user of that front-end logs in through that backend.
   - Each token must carry the user's role, `tenant_id` `DEFAULT` from the Keycloak token itself, and the three-tier group path, e.g. `/tazama-cms/CMS_SUPERVISOR/TAZAMA.ORG`, in `tenant_details`.
   - For CMS, `/v1/auth/me` is called. The investigator, supervisor and compliance officer also call `/v1/user/list-by-role`, which must return the tenant's investigator and supervisor.
5. **Core API loop.** It logs in directly against auth-service as `tazama-user`, `tazama-api-client`, `tenant-001-user` and `tenant-002-user`, checking each user's tenant and group path.

The only changes the script makes are the logins. Tokens, passwords and the resolved compose configuration are never printed. Keycloak locks accounts after repeated failed logins, so fix a wrong `--password` before re-running.

Usage:

```
python smoke-test.py [--host localhost] [--password <pw>] [--wait 300] [--settle 30] [--http-timeout 15] [--skip-logins]
```

The password defaults to `$TAZAMA_SMOKE_PASSWORD`, or `password` (the test realm default). The exit code is 0 when every check passed, 1 when any check failed and 2 for an unsupported deployment or when Docker is unavailable.

## Adding new utilities

When adding a script to this folder:

1. Keep it self-contained (standard library or built-in modules only) so it can be run from any machine with the runtime installed.
2. Read secrets from environment variables or command-line options; never hard-code credentials or commit them here.
3. Provide a `--dry-run` option for anything that mutates a live system, where practical.
4. Add a row to the index table above and a short section describing the script's purpose, behaviour, and usage.
