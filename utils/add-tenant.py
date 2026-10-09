"""
add-tenant.py - Add a new tenant's users and group to a live Keycloak instance
via the Admin REST API. No restart required.

Usage:
    python add-tenant.py --domain <domain> --tenant-id <TENANT_ID> --password <password>
                         [--keycloak-url <url>] [--admin-user <user>] [--admin-password <pw>]
                         [--realm <realm>] [--dry-run]
                         [--seed-cms-reference-ids] [--psql-command <cmd>]
    python add-tenant.py --tenant-id <TENANT_ID> --cms-seed-only [--psql-command <cmd>] [--dry-run]

Examples:
    python add-tenant.py --domain newtenant.com --tenant-id NEWTENANT --password "S3cur3P@ss!"
    python add-tenant.py --domain newtenant.com --tenant-id NEWTENANT --password "S3cur3P@ss!" --dry-run
    python add-tenant.py --tenant-id NEWTENANT --cms-seed-only \
        --psql-command "docker exec -i extensions-postgres psql -U postgres -d tazama_cms"

Defaults:
    --keycloak-url   https://keycloak.beta.tazama.org
    --admin-user     admin
    --admin-password password   (override for production)
    --realm          tazama
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

# --------------------------------------------------------------------------- #
# User templates - matches the pattern used across all existing tenants
# (email-prefix, firstName, lastName, [subgroup paths relative to group root])
# --------------------------------------------------------------------------- #
USER_TEMPLATES = [
    ("cms-administrator", "CMS", "Administrator", ["/tazama-cms/CMS_ADMIN/{gd}"]),
    (
        "cms-compliance-officer",
        "CMS",
        "Compliance Officer",
        ["/tazama-cms/CMS_COMPLIANCE_OFFICER/{gd}"],
    ),
    ("cms-investigator", "CMS", "Investigator", ["/tazama-cms/CMS_INVESTIGATOR/{gd}"]),
    ("cms-supervisor", "CMS", "Supervisor", ["/tazama-cms/CMS_SUPERVISOR/{gd}"]),
    ("tcs-approver", "TCS", "Approver", ["/tazama-tcs/approver/{gd}"]),
    ("tcs-editor", "TCS", "Editor", ["/tazama-tcs/editor/{gd}"]),
    ("tcs-exporter", "TCS", "Exporter", ["/tazama-tcs/exporter/{gd}"]),
    ("tcs-publisher", "TCS", "Publisher", ["/tazama-tcs/publisher/{gd}"]),
    ("trs-approver", "TRS", "Approver", ["/tazama-trs/approver/{gd}"]),
    ("trs-editor", "TRS", "Editor", ["/tazama-trs/editor/{gd}"]),
    ("trs-publisher", "TRS", "Publisher", ["/tazama-trs/publisher/{gd}"]),
    (
        "tazama-api-client",
        "Tazama",
        "API Client",
        [
            "/tazama-conditions/{gd}",
            "/tazama-config/{gd}",
            "/tazama-reports/{gd}",
            "/tazama-tms/{gd}",
        ],
    ),
    ("jupyter-user", "Jupyter", "User", ["/tazama-jupyter/JUPYTER_USER/{gd}"]),
]

# --------------------------------------------------------------------------- #
# CMS reference_ids seed (tazama_cms database, extensions deployment)
# (txTp, referenceIdName)
# --------------------------------------------------------------------------- #
CMS_REFERENCE_IDS = [
    ("pacs.008.001.10", "EndToEndId"),
    ("pacs.002.001.12", "OrgnlEndToEndId"),
]

# Tenant IDs are interpolated into SQL; restrict to a safe character set
TENANT_ID_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+$")

# --------------------------------------------------------------------------- #
# HTTP helpers (stdlib only - no requests dependency)
# --------------------------------------------------------------------------- #


def http(method, url, token=None, data=None, content_type="application/json"):
    body = None
    if data is not None:
        if content_type == "application/x-www-form-urlencoded":
            body = urllib.parse.urlencode(data).encode()
        else:
            body = json.dumps(data).encode()

    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Content-Type", content_type)
    if token:
        req.add_header("Authorization", f"Bearer {token}")

    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            payload = json.loads(raw)
        except Exception:
            payload = raw.decode(errors="replace")
        return e.code, payload


def get_token(base_url, admin_user, admin_password):
    url = f"{base_url}/realms/master/protocol/openid-connect/token"
    status, body = http(
        "POST",
        url,
        data={
            "grant_type": "password",
            "client_id": "admin-cli",
            "username": admin_user,
            "password": admin_password,
        },
        content_type="application/x-www-form-urlencoded",
    )
    if status != 200:
        print(f"ERROR: Could not obtain admin token (HTTP {status}): {body}")
        sys.exit(1)
    return body["access_token"]


# --------------------------------------------------------------------------- #
# Keycloak operations
# --------------------------------------------------------------------------- #


def find_group_by_path(base_url, realm, token, path):
    """Return group id for exact path, or None."""
    # Search by name (last segment) then match full path
    name = path.lstrip("/").split("/")[-1]
    url = f"{base_url}/admin/realms/{realm}/groups?search={urllib.parse.quote(name)}&exact=true"
    status, body = http("GET", url, token=token)
    if status != 200:
        return None
    for g in body:
        if _find_in_tree(g, path):
            return _find_in_tree(g, path)
    return None


def _find_in_tree(group, path):
    """Recursively search group tree for matching path."""
    gpath = group.get("path", "")
    if gpath == path:
        return group["id"]
    for sub in group.get("subGroups", []):
        result = _find_in_tree(sub, path)
        if result:
            return result
    return None


def get_group_tree(base_url, realm, token, group_id):
    """Fetch full group tree including subgroups."""
    url = f"{base_url}/admin/realms/{realm}/groups/{group_id}"
    status, body = http("GET", url, token=token)
    if status != 200:
        return None
    return body


def create_group(
    base_url, realm, token, name, parent_id=None, attributes=None, dry_run=False
):
    if parent_id:
        url = f"{base_url}/admin/realms/{realm}/groups/{parent_id}/children"
    else:
        url = f"{base_url}/admin/realms/{realm}/groups"

    print(
        f"  {'[DRY-RUN] ' if dry_run else ''}Create group '{name}'"
        + (f" under parent {parent_id}" if parent_id else " (top-level)")
        + (f" with attributes {attributes}" if attributes else "")
    )

    if dry_run:
        return f"dry-run-group-{name}"

    payload = {"name": name}
    if attributes:
        payload["attributes"] = attributes
    status, body = http("POST", url, token=token, data=payload)
    if status == 201:
        # Fetch the created group id from Location header - not returned in body
        # Re-query by name
        search_url = f"{base_url}/admin/realms/{realm}/groups?search={urllib.parse.quote(name)}&exact=true"
        _, groups = http("GET", search_url, token=token)
        for g in groups:
            if g["name"] == name and not g.get("parentId") == parent_id:
                # top-level match or subgroup - find it
                pass
        # Simpler: search all groups for the one we just created
        return _find_created_group(base_url, realm, token, name, parent_id)
    elif status == 409:
        print(f"    (group '{name}' already exists, skipping)")
        return _find_created_group(base_url, realm, token, name, parent_id)
    else:
        print(f"  ERROR creating group '{name}': HTTP {status} - {body}")
        sys.exit(1)


def _find_created_group(base_url, realm, token, name, parent_id):
    """Find a group by name under optional parent."""
    if parent_id:
        # Use /children endpoint - subGroups field is always empty in Keycloak 23
        url = f"{base_url}/admin/realms/{realm}/groups/{parent_id}/children"
        _, children = http("GET", url, token=token)
        if isinstance(children, list):
            for sub in children:
                if sub["name"] == name:
                    return sub["id"]
    else:
        url = f"{base_url}/admin/realms/{realm}/groups?search={urllib.parse.quote(name)}&exact=true"
        _, groups = http("GET", url, token=token)
        if isinstance(groups, list):
            for g in groups:
                if g["name"] == name:
                    return g["id"]
    return None


def ensure_group_attributes(
    base_url, realm, token, group_id, attributes, dry_run=False
):
    """Merge missing attribute keys into an existing group (heals groups created
    before this script set TENANT_ID)."""
    url = f"{base_url}/admin/realms/{realm}/groups/{group_id}"
    status, full = http("GET", url, token=token)
    if status != 200:
        print(
            f"    WARNING: Could not read group {group_id} to verify attributes (HTTP {status})"
        )
        return
    current = full.get("attributes") or {}
    missing = {k: v for k, v in attributes.items() if not current.get(k)}
    if not missing:
        return
    print(
        f"    {'[DRY-RUN] ' if dry_run else ''}Heal group '{full.get('name')}': add attributes {missing}"
    )
    if dry_run:
        return
    current.update(missing)
    status, body = http(
        "PUT", url, token=token, data={"name": full["name"], "attributes": current}
    )
    if status not in (200, 204):
        print(f"    WARNING: Could not update group attributes (HTTP {status}): {body}")


def ensure_subgroup(
    base_url, realm, token, parent_id, name, attributes=None, dry_run=False
):
    """Return subgroup id, creating it if it does not exist."""
    # Use /children endpoint - subGroups field is always empty in Keycloak 23
    url = f"{base_url}/admin/realms/{realm}/groups/{parent_id}/children"
    _, children = http("GET", url, token=token)
    if isinstance(children, list):
        for sub in children:
            if sub["name"] == name:
                if attributes:
                    ensure_group_attributes(
                        base_url, realm, token, sub["id"], attributes, dry_run=dry_run
                    )
                return sub["id"]
    return create_group(
        base_url,
        realm,
        token,
        name,
        parent_id=parent_id,
        attributes=attributes,
        dry_run=dry_run,
    )


def find_service_group(base_url, realm, token, service_path_prefix):
    """Find the id of a top-level service group like /tazama-cms."""
    url = f"{base_url}/admin/realms/{realm}/groups"
    _, groups = http("GET", url, token=token)
    name = service_path_prefix.lstrip("/")
    for g in groups:
        if g["name"] == name:
            return g["id"]
    return None


def assign_user_to_group(base_url, realm, token, user_id, group_id, dry_run=False):
    print(f"    {'[DRY-RUN] ' if dry_run else ''}Assign user to group {group_id}")
    if dry_run:
        return
    url = f"{base_url}/admin/realms/{realm}/users/{user_id}/groups/{group_id}"
    status, _ = http("PUT", url, token=token)
    if status not in (200, 204):
        print(f"    WARNING: Could not assign group {group_id} (HTTP {status})")


def create_user(
    base_url,
    realm,
    token,
    username,
    first_name,
    last_name,
    password,
    tenant_id,
    dry_run=False,
):
    email = username  # username is email format
    print(f"  {'[DRY-RUN] ' if dry_run else ''}Create user {username}")
    if dry_run:
        return f"dry-run-user-{username}"

    payload = {
        "username": username,
        "email": email,
        "firstName": first_name,
        "lastName": last_name,
        "enabled": True,
        "emailVerified": True,
        "credentials": [{"type": "password", "value": password, "temporary": False}],
        "attributes": {"TENANT_ID": [tenant_id]},
    }
    url = f"{base_url}/admin/realms/{realm}/users"
    status, body = http("POST", url, token=token, data=payload)
    if status == 201:
        # Fetch user id
        search_url = f"{base_url}/admin/realms/{realm}/users?username={urllib.parse.quote(username)}&exact=true"
        _, users = http("GET", search_url, token=token)
        if users:
            return users[0]["id"]
    elif status == 409:
        print(f"    (user '{username}' already exists - updating password + TENANT_ID)")
        search_url = f"{base_url}/admin/realms/{realm}/users?username={urllib.parse.quote(username)}&exact=true"
        _, users = http("GET", search_url, token=token)
        if users:
            uid = users[0]["id"]
            # Heal TENANT_ID attribute (older runs derived it from the domain)
            attrs = users[0].get("attributes") or {}
            if attrs.get("TENANT_ID") != [tenant_id]:
                attrs["TENANT_ID"] = [tenant_id]
                http(
                    "PUT",
                    f"{base_url}/admin/realms/{realm}/users/{uid}",
                    token=token,
                    data={"attributes": attrs},
                )
            # Reset password
            pw_url = f"{base_url}/admin/realms/{realm}/users/{uid}/reset-password"
            http(
                "PUT",
                pw_url,
                token=token,
                data={"type": "password", "value": password, "temporary": False},
            )
            return uid
    else:
        print(f"  ERROR creating user '{username}': HTTP {status} - {body}")
        return None


def seed_cms_reference_ids(psql_command, tenant_id, dry_run=False):
    """Insert the basic reference_ids rows for a tenant via psql (stdin).
    Existing rows for the tenant are left untouched."""
    values = ",\n".join(
        f"  ('{tx_tp}', '{ref_name}', '{tenant_id}')"
        for tx_tp, ref_name in CMS_REFERENCE_IDS
    )
    sql = (
        "\\set ON_ERROR_STOP on\n"
        'INSERT INTO "reference_ids" ("txTp", "referenceIdName", "tenant_id") VALUES\n'
        f"{values}\n"
        'ON CONFLICT ("txTp", "tenant_id") DO NOTHING;\n'
        'SELECT "id", "txTp", "referenceIdName", "createdAt", "tenant_id"\n'
        f"  FROM \"reference_ids\" WHERE \"tenant_id\" = '{tenant_id}' ORDER BY \"txTp\";\n"
    )
    cmd = shlex.split(psql_command)

    # Print the program name only - arguments may carry credentials (connection URI)
    print(f"  {'[DRY-RUN] ' if dry_run else ''}Run: {cmd[0]} (arguments not shown)")
    print("  SQL:")
    for line in sql.splitlines():
        print(f"    {line}")
    if dry_run:
        return True

    try:
        result = subprocess.run(cmd, input=sql, text=True)
    except FileNotFoundError:
        print(f"  ERROR: Command not found: {cmd[0]}")
        return False
    if result.returncode != 0:
        print(f"  ERROR: psql command exited with code {result.returncode}")
        return False
    return True


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #


def main():
    parser = argparse.ArgumentParser(
        description="Add a new tenant to Keycloak via Admin API"
    )
    parser.add_argument(
        "--domain",
        help="Tenant email domain, e.g. newtenant.com (required unless --cms-seed-only)",
    )
    parser.add_argument(
        "--tenant-id", required=True, help="Tenant ID (upper-case), e.g. NEWTENANT"
    )
    parser.add_argument(
        "--password",
        help="Password for all tenant users (required unless --cms-seed-only)",
    )
    parser.add_argument(
        "--keycloak-url",
        default="https://keycloak.beta.tazama.org",
        help="Keycloak base URL",
    )
    parser.add_argument("--admin-user", default="admin")
    parser.add_argument(
        "--admin-password",
        default=os.environ.get("KC_ADMIN_PW", "password"),
        help="Keycloak admin password (or set KC_ADMIN_PW env var)",
    )
    parser.add_argument("--realm", default="tazama")
    parser.add_argument(
        "--dry-run", action="store_true", help="Print actions without making API calls"
    )
    parser.add_argument(
        "--seed-cms-reference-ids",
        action="store_true",
        help="After the Keycloak steps, seed the tenant's basic reference_ids rows in tazama_cms",
    )
    parser.add_argument(
        "--cms-seed-only",
        action="store_true",
        help="Only seed the tenant's reference_ids rows in tazama_cms; skip all Keycloak steps",
    )
    parser.add_argument(
        "--psql-command",
        default="psql",
        help="Command that runs psql against the tazama_cms database, reading SQL from stdin "
        '(default: psql). e.g. "docker exec -i extensions-postgres psql -U postgres -d tazama_cms"',
    )
    args = parser.parse_args()

    seed_cms = args.seed_cms_reference_ids or args.cms_seed_only
    if not args.cms_seed_only:
        missing = [
            flag
            for flag, value in (("--domain", args.domain), ("--password", args.password))
            if not value
        ]
        if missing:
            parser.error(f"the following arguments are required: {', '.join(missing)}")
    if seed_cms and not TENANT_ID_PATTERN.fullmatch(args.tenant_id):
        parser.error(
            f"--tenant-id '{args.tenant_id}' contains characters not allowed for the CMS seed "
            "(allowed: letters, digits, '_', '.', '-')"
        )

    if args.cms_seed_only:
        print(f"\n=== Seed CMS reference_ids: {args.tenant_id} ===")
        if args.dry_run:
            print("*** DRY-RUN MODE - no changes will be made ***\n")
        if not seed_cms_reference_ids(args.psql_command, args.tenant_id, args.dry_run):
            sys.exit(1)
        print("      Done.")
        return

    domain = args.domain.lower()
    group_domain = domain.upper()  # e.g. NEWTENANT.COM - used in group paths
    realm = args.realm
    base_url = args.keycloak_url.rstrip("/")
    dry_run = args.dry_run

    print(f"\n=== Add tenant: {args.tenant_id} | domain: {domain} | realm: {realm} ===")
    if dry_run:
        print("*** DRY-RUN MODE - no changes will be made ***\n")

    # 1. Authenticate
    print("\n[1/4] Authenticating as admin...")
    if dry_run:
        token = "dry-run-token"
    else:
        token = get_token(base_url, args.admin_user, args.admin_password)
    print("      OK")

    # 2. Build the group structure required for this tenant
    # Each service group (e.g. /tazama-cms) has subgroups per role, and each role
    # subgroup has a child named after the tenant's group_domain.
    # e.g. /tazama-cms/CMS_ADMIN/NEWTENANT.COM
    print(f"\n[2/4] Ensuring group subgroups for {group_domain}...")

    # Collect all unique service/role paths needed
    needed_paths = set()
    for _, _, _, group_paths in USER_TEMPLATES:
        for gp in group_paths:
            needed_paths.add(gp.replace("{gd}", group_domain))

    # For each path like /tazama-cms/CMS_ADMIN/NEWTENANT.COM:
    #   - find /tazama-cms (must exist)
    #   - find/create /tazama-cms/CMS_ADMIN (must exist for existing tenants, but create if missing)
    #   - create /tazama-cms/CMS_ADMIN/NEWTENANT.COM
    group_id_cache = {}  # path -> id

    for path in sorted(needed_paths):
        # Refresh token per path - the master admin token can expire (60s default)
        if not dry_run:
            token = get_token(base_url, args.admin_user, args.admin_password)
        parts = path.lstrip("/").split(
            "/"
        )  # ['tazama-cms', 'CMS_ADMIN', 'NEWTENANT.COM']
        current_path = ""
        parent_id = None
        for i, part in enumerate(parts):
            current_path = current_path + "/" + part
            if current_path in group_id_cache:
                parent_id = group_id_cache[current_path]
                continue
            if i == 0:
                # Top-level service group - must already exist
                gid = (
                    find_service_group(base_url, realm, token, current_path)
                    if not dry_run
                    else f"dry-svc-{part}"
                )
                if not gid:
                    print(
                        f"  ERROR: Service group '{current_path}' not found in realm. Cannot proceed."
                    )
                    sys.exit(1)
                group_id_cache[current_path] = gid
                parent_id = gid
            else:
                # Create if not exists; the tenant leaf group carries the
                # TENANT_ID attribute (read by auth-service group resolution)
                is_leaf = i == len(parts) - 1
                gid = ensure_subgroup(
                    base_url,
                    realm,
                    token,
                    parent_id,
                    part,
                    attributes={"TENANT_ID": [args.tenant_id]} if is_leaf else None,
                    dry_run=dry_run,
                )
                group_id_cache[current_path] = gid
                parent_id = gid

    print("      Done.")

    # 3. Create users
    print(f"\n[3/4] Creating {len(USER_TEMPLATES)} users...")
    for prefix, first, last, group_paths in USER_TEMPLATES:
        # Refresh token before each user to avoid expiry on longer runs
        if not dry_run:
            token = get_token(base_url, args.admin_user, args.admin_password)
        username = f"{prefix}@{domain}"
        user_id = create_user(
            base_url,
            realm,
            token,
            username,
            first,
            last,
            args.password,
            args.tenant_id,
            dry_run=dry_run,
        )

        # 4. Assign to groups
        for gp in group_paths:
            full_path = gp.replace("{gd}", group_domain)
            group_id = group_id_cache.get(full_path)
            if group_id:
                assign_user_to_group(
                    base_url, realm, token, user_id, group_id, dry_run=dry_run
                )
            else:
                print(
                    f"    WARNING: Group path '{full_path}' not in cache, skipping assignment"
                )

    print(
        f"\n[4/4] Done. Tenant {args.tenant_id} ({domain}) provisioned with {len(USER_TEMPLATES)} users."
    )
    print(
        f"      Users can log in at https://cms.beta.tazama.org etc. with their @{domain} email addresses.\n"
    )

    if not dry_run:
        print_tenant_report(
            base_url,
            realm,
            args.admin_user,
            args.admin_password,
            args.tenant_id,
            domain,
            args.password,
        )

    if seed_cms:
        print(f"\n[CMS] Seeding reference_ids for tenant {args.tenant_id}...")
        if not seed_cms_reference_ids(args.psql_command, args.tenant_id, dry_run):
            sys.exit(1)
        print("      Done.")


def print_tenant_report(
    base_url, realm, admin_user, admin_password, tenant_id, domain, password
):
    # Get a fresh token for the report lookups
    token = get_token(base_url, admin_user, admin_password)
    """Print a shareable onboarding report and a Keycloak group assignment breakdown."""

    # --- Shareable tenant report ---
    divider = "=" * 50
    print(divider)
    print("TENANT ONBOARDING REPORT")
    print(divider)
    print(f"TenantId: {tenant_id}")
    print()
    print("https://cms.beta.tazama.org")
    for prefix in [
        "cms-administrator",
        "cms-compliance-officer",
        "cms-investigator",
        "cms-supervisor",
    ]:
        print(f"  {prefix}@{domain}")
    print()
    print("https://tcs.beta.tazama.org")
    for prefix in ["tcs-approver", "tcs-editor", "tcs-exporter", "tcs-publisher"]:
        print(f"  {prefix}@{domain}")
    print()
    print("https://trs.beta.tazama.org")
    for prefix in ["trs-approver", "trs-editor", "trs-publisher"]:
        print(f"  {prefix}@{domain}")
    print()
    print("https://jupyter.beta.tazama.org")
    print(f"  jupyter-user@{domain}")
    print()
    print("https://tms.beta.tazama.org")
    print("https://admin.beta.tazama.org")
    print()
    print(f"  tazama-api-client@{domain}")
    print()
    print(f"password: {password}")
    print()

    # --- Keycloak group breakdown ---
    print(divider)
    print("KEYCLOAK GROUP ASSIGNMENTS")
    print(divider)

    for prefix, _, _, _ in USER_TEMPLATES:
        username = f"{prefix}@{domain}"
        search_url = f"{base_url}/admin/realms/{realm}/users?username={urllib.parse.quote(username)}&exact=true"
        _, users = http("GET", search_url, token=token)
        if not isinstance(users, list) or not users:
            print(f"  {username}: (not found)")
            continue
        uid = users[0]["id"]
        groups_url = f"{base_url}/admin/realms/{realm}/users/{uid}/groups"
        _, groups = http("GET", groups_url, token=token)
        paths = [g["path"] for g in groups] if isinstance(groups, list) else []
        print(f"  {username}")
        for p in paths:
            print(f"    -> {p}")

    print(divider)


if __name__ == "__main__":
    main()
