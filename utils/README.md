# Utility Scripts

Standalone operational and administrative utilities for a deployed Tazama stack. Each script is self-contained: the Python scripts use only the standard library, and the Node.js script uses only built-in modules. No package installation is required.

Unless stated otherwise, scripts target the Keycloak instance at `https://keycloak.beta.tazama.org` (realm `tazama`) by default and accept overrides via command-line options. The Keycloak admin password is read from the `KC_ADMIN_PW` environment variable or an `--admin-password` option. Never commit credentials to this repository.

## Index

| Script | Purpose |
| --- | --- |
| [add-tenant.py](add-tenant.py) | Onboard a new tenant organization: create its Keycloak groups and users (Python) |
| [add-tenant.js](add-tenant.js) | Same as add-tenant.py, implemented in Node.js |
| [patch-tenant-id.py](patch-tenant-id.py) | Set or repair the `TENANT_ID` user attribute for all users of a given domain |

## add-tenant.py / add-tenant.js

Adds a complete access pack for a new member organization of the Sandbox to a live Keycloak instance via the Admin REST API. The two implementations are functionally identical; use whichever runtime is convenient.

For a tenant with domain `example.org` and tenant ID `EXAMPLE`, the script:

1. Ensures the organization subgroup (named after the uppercased domain, e.g. `EXAMPLE.ORG`) exists under every service group path that Tazama access control uses:
   - `/tazama-cms/CMS_ADMIN`, `/tazama-cms/CMS_COMPLIANCE_OFFICER`, `/tazama-cms/CMS_INVESTIGATOR`, `/tazama-cms/CMS_SUPERVISOR`
   - `/tazama-tcs/approver`, `/tazama-tcs/editor`, `/tazama-tcs/exporter`, `/tazama-tcs/publisher`
   - `/tazama-trs/approver`, `/tazama-trs/editor`, `/tazama-trs/publisher`
   - `/tazama-jupyter/JUPYTER_USER`
   - `/tazama-conditions`, `/tazama-config`, `/tazama-reports`, `/tazama-tms` (organization subgroup directly under the service group)
2. Sets the `TENANT_ID` attribute on every organization (leaf) subgroup to the value passed with `--tenant-id`. If a subgroup already exists without the attribute, it is healed in place, so re-running the script against an existing tenant repairs earlier gaps.
3. Creates 13 users (`cms-administrator@<domain>`, `cms-compliance-officer@`, `cms-investigator@`, `cms-supervisor@`, `tcs-approver@`, `tcs-editor@`, `tcs-exporter@`, `tcs-publisher@`, `trs-approver@`, `trs-editor@`, `trs-publisher@`, `tazama-api-client@`, `jupyter-user@`), each with the `TENANT_ID` user attribute set to the `--tenant-id` value and the shared password from `--password`. Existing users get their password reset and their `TENANT_ID` attribute corrected.
4. Assigns each user to its group paths and prints an onboarding report.

The top-level service groups (including `/tazama-jupyter`) must already exist in the realm; the script stops with an error otherwise. The `jupyter-user@` account inherits the `JUPYTER_USER` realm role from the `/tazama-jupyter/JUPYTER_USER` group, which is what JupyterHub's Keycloak login checks.

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

## patch-tenant-id.py

Sets the `TENANT_ID` user attribute on all existing users whose username ends in `@<domain>`. Use this to repair users created before add-tenant.py set the attribute, or users created with a wrong value.

```
python patch-tenant-id.py --domain example.org --tenant-id EXAMPLE [--admin-password <pw>]
```

If `--tenant-id` is omitted the script falls back to deriving the value from the first domain label (uppercased) and prints a warning. Always pass the canonical tenant ID explicitly unless you have verified the derived value is correct.

## Adding new utilities

When adding a script to this folder:

1. Keep it self-contained (standard library or built-in modules only) so it can be run from any machine with the runtime installed.
2. Read secrets from environment variables or command-line options; never hard-code credentials or commit them here.
3. Provide a `--dry-run` option for anything that mutates a live system, where practical.
4. Add a row to the index table above and a short section describing the script's purpose, behaviour, and usage.
