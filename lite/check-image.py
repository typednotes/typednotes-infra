#!/usr/bin/env python3
"""Exercise the real assembled image, one disposable PostgreSQL, and restart/
failure handling. No cloud credentials, live APIs or paid model calls are used.

Usage: python3 lite/check-image.py IMAGE /path/to/exported-lite-config.json
"""
import json
import os
import secrets
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import URLError
from urllib.request import urlopen


def docker(*args, data=None, timeout=60, check=True, env=None):
    result = subprocess.run(["docker", *args], input=data, capture_output=True,
                            text=True, timeout=timeout, env=env, check=False)
    if check and result.returncode:
        raise RuntimeError(f"docker {args[0]} failed: {result.stderr}")
    return result.stdout.strip()


def wait_for(check, description, timeout=180):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(1)
    raise RuntimeError(f"Timed out waiting for {description}")


def main():
    image = sys.argv[1]
    config = json.loads(Path(sys.argv[2]).read_text())
    prefix = "typednotes-lite-smoke-" + secrets.token_hex(4)
    database, app = prefix + "-db", prefix + "-app"
    password = secrets.token_hex(24)
    fixture = {
        "DATABASE_URL": f"postgres://runtime:{password}@database:5432/postgres",
        "SECRETS_MASTER_KEY": secrets.token_hex(32),
        "SECRETS_BOOTSTRAP_PASSWORD": secrets.token_hex(32),
        "SECRETS_SERVER_SERVICE_IDENTITIES": config["vaultIdentities"],
        "LIAISON_ROOT_KEY": secrets.token_hex(32),
        "APP_SECRETS_PASSWORD": secrets.token_hex(32),
        "LIAISON_SECRETS_PASSWORD": secrets.token_hex(32),
        "LUN_SECRETS_PASSWORD": secrets.token_hex(32),
        "LODE_TOKEN": secrets.token_hex(32),
        "LUN_TOKEN": secrets.token_hex(32),
        "LUN_ID_SALT": secrets.token_hex(32),
        "LUN_WORKERS": "1",
        "PUBLIC_URL": "http://localhost:8080",
    }
    try:
        docker("network", "create", prefix)
        docker("run", "--detach", "--name", database, "--network", prefix,
               "--network-alias", "database", "--env", f"POSTGRES_PASSWORD={password}",
               "docker.io/library/postgres:16", timeout=180)
        wait_for(lambda: "accepting connections" in docker("exec", database, "pg_isready", "-U", "postgres", check=False),
                 "disposable PostgreSQL")

        def sql(text):
            return docker("exec", "-i", database, "psql", "-v", "ON_ERROR_STOP=1", "-U", "postgres",
                          data=text)

        for url in config["migrations"]:
            with urlopen(url, timeout=30) as response:
                sql(response.read().decode())
        # Serving with DML-only credentials also checks that no child tries to
        # migrate itself; all four histories share this one logical database.
        sql(f"CREATE ROLE runtime LOGIN PASSWORD '{password}';\n"
            "REVOKE CREATE ON SCHEMA public FROM PUBLIC;\n"
            "GRANT USAGE ON SCHEMA public TO runtime;\n"
            "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO runtime;\n"
            "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO runtime;\n")
        args = ["run", "--detach", "--name", app, "--network", prefix,
                "--publish", "127.0.0.1::8080"]
        for key in fixture:
            args.extend(["--env", key])
        docker(*args, image, env=os.environ | fixture)
        published = docker("port", app, "8080/tcp")
        address = "http://" + published

        def ready():
            state = json.loads(docker("inspect", app))[0]["State"]
            if not state["Running"]:
                raise RuntimeError("Lite exited during startup")
            try:
                with urlopen(address + "/api/health", timeout=5) as response:
                    health = json.load(response)
                    return (all(health.get(key) is True for key in
                                ("database", "schema", "ledger", "vault", "liaison", "computations", "lode", "lun"))
                            and health.get("compute") is False)
            except (OSError, URLError):
                return False

        wait_for(ready, "app and notebook dependencies")
        docker("exec", app, "python3", "/usr/local/lib/typednotes-lite/runtime.py", "--healthcheck")
        # Real Lean/toolchain commands run as each worker with its private elan
        # home; starts catch missing shared libraries in every service binary.
        docker("exec", "-i", app, "python3", "-", data='''
import importlib.util, pathlib, pwd, subprocess, sys, os
spec = importlib.util.spec_from_file_location("runtime", "/usr/local/lib/typednotes-lite/runtime.py")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
for service in module.services(os.environ):
    if service.name not in ("lode", "lun"):
        continue
    identity = pwd.getpwnam(service.name)
    subprocess.run(["lake", "--version"], cwd=service.env["HOME"], env=service.env,
                   user=identity.pw_uid, group=identity.pw_gid, check=True)
    script = pathlib.Path(service.env["HOME"]) / "Smoke.lean"
    script.write_text('def main : IO Unit := IO.println "lite-runtime-ok"\\n')
    subprocess.run(["lean", "--run", str(script)], cwd=service.env["HOME"], env=service.env,
                   user=identity.pw_uid, group=identity.pw_gid, check=True)
''')
        # Persist a vault value, then restart the entire process bundle. The
        # master key and one PostgreSQL database must be sufficient to recover it.
        vault_check = '''
import json, os
from urllib.request import Request, urlopen
def request(path, body=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    with urlopen(Request("http://127.0.0.1:8200/v1/" + path,
                         data=None if body is None else json.dumps(body).encode(), headers=headers)) as response:
        return json.loads(response.read() or b"{}")
token = request("auth/userpass/login", {"username": "admin", "password": os.environ["SECRETS_BOOTSTRAP_PASSWORD"]})["auth"]["client_token"]
if os.environ.get("SMOKE_WRITE"):
    request("secret/data/lite-smoke", {"data": {"value": "survives-restart"}}, token)
else:
    assert request("secret/data/lite-smoke", token=token)["data"]["data"]["value"] == "survives-restart"
'''
        docker("exec", "--env", "SMOKE_WRITE=1", "-i", app, "python3", "-", data=vault_check)
        docker("restart", "--time", "15", app)
        address = "http://" + docker("port", app, "8080/tcp")
        wait_for(ready, "restarted app and dependencies")
        docker("exec", "-i", app, "python3", "-", data=vault_check)
        # A dead sweeper must not leave an apparently healthy application.
        docker("exec", "-i", app, "python3", "-", data='''
import os, signal
from pathlib import Path
for path in Path("/proc").glob("[0-9]*/cmdline"):
    try:
        if path.read_bytes().split(b"\\0")[0] == b"/usr/local/bin/ledger":
            os.kill(int(path.parent.name), signal.SIGKILL)
            break
    except FileNotFoundError:
        continue
else:
    raise RuntimeError("ledger process not found")
''')
        code = int(docker("wait", app, timeout=30))
        if code == 0:
            raise RuntimeError("Lite must exit nonzero after a required service dies")
        print("ok: six real services, shared DML-only PostgreSQL, worker toolchains, vault restart recovery and fail-fast supervision")
    except Exception:
        print(docker("logs", app, check=False), file=sys.stderr)
        raise
    finally:
        docker("rm", "--force", app, database, check=False)
        docker("network", "rm", prefix, check=False)


if __name__ == "__main__":
    main()
