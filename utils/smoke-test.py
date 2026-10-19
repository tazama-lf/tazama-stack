#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Smoke test for a local, authenticated, full-service deployment of Tazama Core
and Extensions using DockerHub images.

Checks, in order:
  1. Deployment shape: the tazama-core and tazama-extensions compose projects
     were deployed from the DockerHub full-service files with authentication,
     and no dev/multitenant/public files were used.
  2. Every service defined by those compose files has a container, and every
     image was pulled from a registry (not built locally).
  3. Every container is running (and healthy, if it has a healthcheck), or is
     a one-shot job that exited with code 0. Containers must then stay stable
     (no restarts) for a settle period.
  4. For each front-end (CMS, TCS, TRS): the page is served, the backend that
     the front-end is configured to call answers the CORS preflight for the
     front-end origin, and every default user can log in. Each token must
     carry the user's role, tenant ID and three-tier group path. For CMS the
     profile and list-by-role calls (tenant-scoped user lookup) are checked.
  5. Core API: direct auth-service logins for the API users, including the
     tenant-001/tenant-002 users, resolve to the expected tenant.

Read-only apart from the logins. Tokens, passwords and compose configuration
are never printed.

Exit codes: 0 all checks passed, 1 one or more checks failed,
2 unsupported deployment or Docker unavailable.
"""

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

ORG = "TAZAMA.ORG"
TENANT = "DEFAULT"
TMS_ROLE = "POST_V1_EVALUATE_ISO20022_PACS_008_001_10"

FORBIDDEN_FILE = re.compile(
    r"^docker-compose\.(dev\.|multitenant\.|hub\.cfg\.yaml$|hub\.rules\.yaml$)"
)
REQUIRED_FILES = {
    "tazama-core": [
        "docker-compose.base.infrastructure.yaml",
        "docker-compose.full.cfg.yaml",
        "docker-compose.hub.core.yaml",
        "docker-compose.full.rules.yaml",
        "docker-compose.base.auth.yaml",
    ],
    "tazama-extensions": [
        "docker-compose.extensions.infrastructure.yaml",
        "docker-compose.hub.extensions.yaml",
    ],
}

# (username, expected role in token, expected group path in tenant_details)
FRONTENDS = [
    {
        "name": "CMS",
        "container": "case-management-system-frontend",
        "port": 5175,
        "api_env": "VITE_API_BASE_URL",
        "login": "/v1/auth/login",
        "credentials": True,
        "users": [
            (
                "cms-administrator@tazama.org",
                "CMS_ADMIN",
                f"/tazama-cms/CMS_ADMIN/{ORG}",
            ),
            (
                "cms-compliance-officer@tazama.org",
                "CMS_COMPLIANCE_OFFICER",
                f"/tazama-cms/CMS_COMPLIANCE_OFFICER/{ORG}",
            ),
            (
                "cms-investigator@tazama.org",
                "CMS_INVESTIGATOR",
                f"/tazama-cms/CMS_INVESTIGATOR/{ORG}",
            ),
            (
                "cms-supervisor@tazama.org",
                "CMS_SUPERVISOR",
                f"/tazama-cms/CMS_SUPERVISOR/{ORG}",
            ),
        ],
    },
    {
        "name": "TCS",
        "container": "connection-studio-frontend",
        "port": 5173,
        "api_env": "VITE_API_BASE_URL",
        "login": "/auth/login",
        "credentials": False,
        "users": [
            (f"tcs-{r}@tazama.org", r, f"/tazama-tcs/{r}/{ORG}")
            for r in ("approver", "editor", "exporter", "publisher")
        ],
    },
    {
        "name": "TRS",
        "container": "rule-studio-frontend",
        "port": 5174,
        "api_env": "VITE_API_URL",
        "login": "/auth/login",
        "credentials": False,
        "users": [
            (f"trs-{r}@tazama.org", f"trs_{r}", f"/tazama-trs/{r}/{ORG}")
            for r in ("approver", "editor", "publisher")
        ],
    },
]

# CMS roles allowed to call /v1/user/list-by-role, and the lookups to make.
CMS_LIST_CALLERS = {"CMS_INVESTIGATOR", "CMS_SUPERVISOR", "CMS_COMPLIANCE_OFFICER"}
CMS_LIST_LOOKUPS = [
    ("CMS_INVESTIGATOR", "cms-investigator@tazama.org"),
    ("CMS_SUPERVISOR", "cms-supervisor@tazama.org"),
]

# (username, expected tenant, expected group path in tenant_details)
CORE_API_USERS = [
    ("tazama-user@tazama.org", TENANT, f"/tazama-tms/{ORG}"),
    ("tazama-api-client@tazama.org", TENANT, f"/tazama-batch/{ORG}"),
    ("tenant-001-user", "tenant-001", "/tazama-tms/tenant-001"),
    ("tenant-002-user", "tenant-002", "/tazama-tms/tenant-002"),
]


# ---------------------------------------------------------------- reporting --


class Report:
    def __init__(self):
        self.counts = {"PASS": 0, "WARN": 0, "FAIL": 0}

    @staticmethod
    def section(title):
        print(f"\n== {title} ==")

    def add(self, status, name, detail=""):
        self.counts[status] += 1
        print(f"  {status}  {name:<44} {detail}".rstrip())

    def ok(self, name, detail=""):
        self.add("PASS", name, detail)

    def warn(self, name, detail=""):
        self.add("WARN", name, detail)

    def fail(self, name, detail=""):
        self.add("FAIL", name, detail)


# ------------------------------------------------------------------- docker --


def run(cmd, cwd=None, timeout=120):
    try:
        p = subprocess.run(
            cmd,
            cwd=cwd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return 124, "", f"timed out after {timeout}s: {' '.join(cmd[:3])}"
    return p.returncode, p.stdout, p.stderr


def inspect_projects(projects):
    """docker inspect output for all containers in the given compose projects.
    Holds container environments (secrets) in memory only; never print it."""
    ids = []
    for project in projects:
        rc, out, _ = run(
            [
                "docker",
                "ps",
                "-aq",
                "--filter",
                f"label=com.docker.compose.project={project}",
            ]
        )
        ids += out.split()
    if not ids:
        return []
    rc, out, err = run(["docker", "inspect", *ids])
    if rc != 0:
        raise RuntimeError(f"docker inspect failed: {err.strip()}")
    return json.loads(out)


def labels(c):
    return c["Config"].get("Labels") or {}


def basename(path):
    return re.split(r"[\\/]", path)[-1]


def config_files(c):
    return [
        f
        for f in labels(c).get("com.docker.compose.project.config_files", "").split(",")
        if f
    ]


def name_of(c):
    return c["Name"].lstrip("/")


def state_of(c):
    s = c["State"]
    probes = (s.get("Health") or {}).get("Log") or []
    return {
        "status": s.get("Status"),
        "exit": s.get("ExitCode"),
        "health": (s.get("Health") or {}).get("Status"),
        # The probe itself cannot run (e.g. CMD-SHELL in an image without /bin/sh).
        "probe_broken": bool(probes)
        and probes[-1].get("ExitCode") == -1
        and "exec failed" in (probes[-1].get("Output") or ""),
        "restarts": c.get("RestartCount", 0),
        "started": s.get("StartedAt"),
        "policy": (c["HostConfig"].get("RestartPolicy") or {}).get("Name") or "no",
    }


def verdict(st):
    """'ok' (running/healthy), 'done' (one-shot exited 0), 'probe' (running but
    the healthcheck cannot execute) or 'bad'."""
    if st["status"] == "running" and st["health"] in (None, "healthy"):
        return "ok"
    if st["status"] == "running" and st["probe_broken"]:
        return "probe"
    if (
        st["status"] == "exited"
        and st["exit"] == 0
        and st["policy"] in ("no", "on-failure")
    ):
        return "done"
    return "bad"


def describe(st):
    text = st["status"]
    if st["status"] == "exited":
        text += f" ({st['exit']})"
    if st["health"]:
        text += f"/{st['health']}"
    return text


def host_port(c, container_port):
    bindings = (c["NetworkSettings"].get("Ports") or {}).get(
        f"{container_port}/tcp"
    ) or []
    return bindings[0].get("HostPort") if bindings else None


def container_env(c):
    return dict(e.split("=", 1) for e in c["Config"].get("Env") or [] if "=" in e)


# --------------------------------------------------------------------- http --

_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def http(method, url, headers=None, body=None, timeout=15):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url, data=data, method=method, headers=dict(headers or {})
    )
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with _opener.open(req, timeout=timeout) as r:
            return r.status, {k.lower(): v for k, v in r.headers.items()}, r.read()
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read()
    except (urllib.error.URLError, OSError) as e:
        return None, {}, f"connection failed: {getattr(e, 'reason', e)}".encode()


def short(status, body):
    if status is None:
        return body.decode("utf-8", "replace")
    text = body.decode("utf-8", "replace").strip()
    try:
        parsed = json.loads(text)
        if isinstance(parsed, dict) and parsed.get("message"):
            text = str(parsed["message"])
    except ValueError:
        pass
    return f"HTTP {status}: {text[:120]}"


def cors_problem(h, origin, credentials):
    acao = h.get("access-control-allow-origin")
    if acao != origin and not (acao == "*" and not credentials):
        return f"Access-Control-Allow-Origin={acao!r}, expected {origin!r}"
    if credentials and h.get("access-control-allow-credentials", "").lower() != "true":
        return "Access-Control-Allow-Credentials is not true"
    return None


def extract_token(body):
    text = body.decode("utf-8", "replace").strip()
    try:
        parsed = json.loads(text)
    except ValueError:
        parsed = text
    if isinstance(parsed, dict):
        for key in ("token", "access_token", "accessToken"):
            if isinstance(parsed.get(key), str):
                return parsed[key]
        if isinstance(parsed.get("data"), dict):
            return extract_token(json.dumps(parsed["data"]).encode())
        return None
    if isinstance(parsed, str) and parsed.count(".") == 2:
        return parsed
    return None


def jwt_payload(token):
    try:
        part = token.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
    except (IndexError, ValueError):
        return None


def token_problems(token, role, tenant, group_path):
    """Check the Tazama token and the Keycloak token wrapped in it."""
    outer = jwt_payload(token)
    if not isinstance(outer, dict):
        return ["token is not a decodable JWT"]
    inner = outer
    if isinstance(outer.get("tokenString"), str):
        inner = jwt_payload(outer["tokenString"])
        if not isinstance(inner, dict):
            return ["inner Keycloak token is not a decodable JWT"]
    roles = set((inner.get("realm_access") or {}).get("roles") or [])
    if isinstance(outer.get("claims"), list):
        roles.update(outer["claims"])
    problems = []
    if role and role not in roles:
        problems.append(f"role {role} missing")
    # tenant_id comes from the organization group's TENANT_ID attribute. The
    # Tazama token falls back to DEFAULT when it is absent, so check the
    # Keycloak claim itself.
    if inner.get("tenant_id") != tenant:
        problems.append(f"tenant_id={inner.get('tenant_id')!r}, expected {tenant!r}")
    if "tenantId" in outer and outer["tenantId"] != tenant:
        problems.append(f"tenantId={outer['tenantId']!r}, expected {tenant!r}")
    details = inner.get("tenant_details") or []
    if group_path not in details:
        problems.append(f"group {group_path} not in tenant_details {details}")
    return problems


# ------------------------------------------------------------------- checks --


def check_deployment(rep, containers):
    rep.section("Deployment")
    good = True
    for project, required in REQUIRED_FILES.items():
        mine = [
            c
            for c in containers
            if labels(c).get("com.docker.compose.project") == project
        ]
        if not mine:
            rep.fail(project, "no containers; deploy it first")
            good = False
            continue
        used = {basename(f) for c in mine for f in config_files(c)}
        missing = [f for f in required if f not in used]
        if missing:
            rep.fail(
                project,
                "not a full-service DockerHub deployment with auth; missing "
                + ", ".join(missing),
            )
            good = False
        else:
            rep.ok(project, f"{len(mine)} containers")
    forbidden = sorted(
        {
            basename(f)
            for c in containers
            for f in config_files(c)
            if FORBIDDEN_FILE.match(basename(f))
        }
    )
    if forbidden:
        rep.fail("compose files", "unsupported files in use: " + ", ".join(forbidden))
        good = False
    else:
        rep.ok("compose files", "DockerHub only (no dev, multitenant or public files)")
    return good


def check_services(rep, containers):
    rep.section("Services and images")
    groups = {}
    for c in containers:
        lb = labels(c)
        key = (
            lb.get("com.docker.compose.project"),
            lb.get("com.docker.compose.project.working_dir", ""),
            lb.get("com.docker.compose.project.config_files", ""),
            lb.get("com.docker.compose.project.environment_file", ""),
        )
        groups.setdefault(key, set()).add(lb.get("com.docker.compose.service"))
    for (project, workdir, files, env_files), present in sorted(groups.items()):
        envs = [e for e in env_files.split(",") if e] or [
            p
            for p in (
                os.path.join(workdir, ".env"),
                os.path.join(workdir, "secrets.env"),
            )
            if os.path.isfile(p)
        ]
        cmd = ["docker", "compose", "-p", project]
        for e in envs:
            cmd += ["--env-file", e]
        for f in files.split(","):
            cmd += ["-f", f]
        cmd += ["config", "--services"]
        rc, out, err = run(cmd, cwd=workdir or None)
        label = f"{project} ({', '.join(basename(f) for f in files.split(','))})"
        if rc != 0:
            last = (err.strip().splitlines() or ["unknown error"])[-1]
            rep.warn(label, f"could not resolve compose services: {last[:120]}")
            continue
        expected = set(out.split())
        missing = sorted(expected - present)
        if missing:
            rep.fail(label, "no container for: " + ", ".join(missing))
        else:
            rep.ok(label, f"{len(expected)} services")

    local = []
    images = sorted({c["Config"]["Image"] for c in containers})
    for image in images:
        rc, out, _ = run(
            ["docker", "image", "inspect", "--format", "{{json .RepoDigests}}", image]
        )
        if rc != 0 or not json.loads(out or "[]"):
            local.append(image)
    if local:
        rep.fail("images", "not pulled from a registry: " + ", ".join(local))
    else:
        rep.ok("images", f"{len(images)} images, all pulled from a registry")


def check_containers(rep, args):
    rep.section("Containers")
    projects = list(REQUIRED_FILES)
    deadline = time.monotonic() + args.wait
    last = None
    while True:
        containers = inspect_projects(projects)
        pending = sorted(
            name_of(c) for c in containers if verdict(state_of(c)) == "bad"
        )
        if not pending or time.monotonic() >= deadline:
            break
        if pending != last:
            print(
                f"  waiting: {len(containers) - len(pending)}/{len(containers)} ready; "
                f"pending: {', '.join(pending[:6])}{' ...' if len(pending) > 6 else ''}"
            )
            last = pending
        time.sleep(5)

    if not pending and args.settle > 0:
        print(f"  all ready; watching for restarts for {args.settle}s")
        time.sleep(args.settle)
    before = {name_of(c): state_of(c) for c in containers}
    after_list = inspect_projects(projects) if args.settle > 0 else containers
    after = {name_of(c): state_of(c) for c in after_list}

    for name in sorted(set(before) | set(after)):
        b, a = before.get(name), after.get(name)
        if a is None:
            rep.fail(name, "container disappeared")
            continue
        v = verdict(a)
        if v == "bad":
            rep.fail(name, f"{describe(a)}, restarts={a['restarts']}")
        elif b and (a["restarts"] > b["restarts"] or a["started"] != b["started"]):
            rep.fail(
                name,
                f"{describe(a)}, restarted during settle period (restarts={a['restarts']})",
            )
        elif v == "probe":
            rep.warn(name, "running, but its healthcheck cannot execute in the image")
        elif a["restarts"] > 0:
            rep.warn(name, f"{describe(a)}, restarted {a['restarts']}x before settling")
        else:
            rep.ok(name, "completed (exit 0)" if v == "done" else describe(a))
    return after_list


def login(
    rep,
    label,
    url,
    user,
    password,
    role,
    tenant,
    group_path,
    timeout,
    origin=None,
    credentials=False,
):
    headers = {"Origin": origin} if origin else {}
    status, h, body = http(
        "POST", url, headers, {"username": user, "password": password}, timeout
    )
    if status not in (200, 201):
        rep.fail(label, "login " + short(status, body))
        return None
    if origin:
        problem = cors_problem(h, origin, credentials)
        if problem:
            rep.fail(label, f"login CORS: {problem}")
            return None
    token = extract_token(body)
    if not token:
        rep.fail(label, "login response has no token")
        return None
    problems = token_problems(token, role, tenant, group_path)
    if problems:
        rep.fail(label, "; ".join(problems))
        return None
    rep.ok(label, f"tenant={tenant} group={group_path}")
    return token


def check_frontend(rep, fe, by_name, args):
    rep.section(f"{fe['name']} front-end loop")
    c = by_name.get(fe["container"])
    if not c:
        rep.fail(fe["container"], "container not found")
        return
    port = host_port(c, fe["port"])
    if not port:
        rep.fail(fe["container"], f"port {fe['port']} not published")
        return
    origin = f"http://{args.host}:{port}"
    status, h, body = http("GET", origin + "/", timeout=args.http_timeout)
    if status == 200 and "html" in h.get("content-type", ""):
        rep.ok("page", origin)
    else:
        rep.fail("page", f"{origin}: " + short(status, body))

    api = container_env(c).get(fe["api_env"], "").rstrip("/")
    if not api:
        rep.fail("backend URL", f"{fe['api_env']} not set on {fe['container']}")
        return
    login_url = api + fe["login"]
    status, h, body = http(
        "OPTIONS",
        login_url,
        {
            "Origin": origin,
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "content-type",
        },
        timeout=args.http_timeout,
    )
    problem = None if status and 200 <= status < 300 else short(status, body)
    problem = problem or cors_problem(h, origin, fe["credentials"])
    if problem:
        rep.fail("CORS preflight", f"{login_url}: {problem}")
    else:
        rep.ok("CORS preflight", login_url)

    for user, role, group_path in fe["users"]:
        token = login(
            rep,
            user,
            login_url,
            user,
            args.password,
            role,
            TENANT,
            group_path,
            args.http_timeout,
            origin,
            fe["credentials"],
        )
        if not token or fe["name"] != "CMS":
            continue
        auth = {"Origin": origin, "Authorization": f"Bearer {token}"}
        status, h, body = http(
            "GET", f"{api}/v1/auth/me", auth, timeout=args.http_timeout
        )
        problem = (
            short(status, body) if status != 200 else cors_problem(h, origin, True)
        )
        if problem:
            rep.fail(f"  {role} /v1/auth/me", problem)
        else:
            rep.ok(f"  {role} /v1/auth/me")
        if role not in CMS_LIST_CALLERS:
            continue
        for lookup, expected_user in CMS_LIST_LOOKUPS:
            name = f"  {role} list-by-role/{lookup}"
            status, h, body = http(
                "GET",
                f"{api}/v1/user/list-by-role/{lookup}",
                auth,
                timeout=args.http_timeout,
            )
            if status != 200:
                rep.fail(name, short(status, body))
                continue
            try:
                users = json.loads(body)
            except ValueError:
                users = None
            if not isinstance(users, list):
                rep.fail(name, "response is not a list")
            elif not any(expected_user in json.dumps(u).lower() for u in users):
                rep.fail(
                    name,
                    f"{expected_user} not returned ({len(users)} users); "
                    "tenant-scoped user lookup is broken",
                )
            else:
                rep.ok(name, f"{len(users)} users, includes {expected_user}")


def check_core_api(rep, by_name, args):
    rep.section("Core API loop (auth-service)")
    c = by_name.get("auth-service")
    port = host_port(c, 3020) if c else None
    if not port:
        rep.fail("auth-service", "container not found or port 3020 not published")
        return
    url = f"http://{args.host}:{port}/v1/auth/login"
    for user, tenant, group_path in CORE_API_USERS:
        login(
            rep,
            user,
            url,
            user,
            args.password,
            TMS_ROLE,
            tenant,
            group_path,
            args.http_timeout,
        )


# --------------------------------------------------------------------- main --


def main():
    parser = argparse.ArgumentParser(
        description="Smoke test a local authenticated full-service Tazama Core + Extensions "
        "deployment (DockerHub images)."
    )
    parser.add_argument(
        "--host",
        default="localhost",
        help="host the browser uses to reach the front-ends (default: localhost)",
    )
    parser.add_argument(
        "--password",
        default=os.environ.get("TAZAMA_SMOKE_PASSWORD", "password"),
        help="password of the default realm users "
        '(default: $TAZAMA_SMOKE_PASSWORD or "password")',
    )
    parser.add_argument(
        "--wait",
        type=int,
        default=300,
        help="seconds to wait for containers to become ready (default: 300)",
    )
    parser.add_argument(
        "--settle",
        type=int,
        default=30,
        help="seconds containers must run without restarting (default: 30, 0 to skip)",
    )
    parser.add_argument(
        "--http-timeout",
        type=int,
        default=15,
        help="per-request timeout in seconds (default: 15)",
    )
    parser.add_argument(
        "--skip-logins",
        action="store_true",
        help="only check the deployment and containers",
    )
    args = parser.parse_args()

    rc, _, err = run(["docker", "version", "--format", "{{.Server.Version}}"])
    if rc != 0:
        print(f"Docker is not available: {err.strip()}")
        return 2

    rep = Report()
    containers = inspect_projects(list(REQUIRED_FILES))
    if not check_deployment(rep, containers):
        print(
            "\nUnsupported deployment. Deploy Core with tazama-core.bat option 3 "
            "(Full-service, DockerHub) with the auth add-on, and Extensions with "
            "tazama-extensions.bat option 4 (DockerHub)."
        )
        return 2
    check_services(rep, containers)
    containers = check_containers(rep, args)

    if not args.skip_logins:
        by_name = {name_of(c): c for c in containers}
        for fe in FRONTENDS:
            check_frontend(rep, fe, by_name, args)
        check_core_api(rep, by_name, args)

    counts = rep.counts
    print(
        f"\nResult: {counts['PASS']} passed, {counts['WARN']} warnings, {counts['FAIL']} failed"
    )
    return 1 if counts["FAIL"] else 0


if __name__ == "__main__":
    sys.exit(main())
