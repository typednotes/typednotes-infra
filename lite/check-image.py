#!/usr/bin/env python3
"""Exercise the real assembled image, one disposable PostgreSQL, and restart/
failure handling. No cloud credentials, live APIs or paid model calls are used.

Usage: python3 lite/check-image.py IMAGE /path/to/exported-lite-config.json
"""
import json
import os
import secrets
import sys
from pathlib import Path
from urllib.error import URLError
from urllib.request import urlopen

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from images import migrations
from images.releases import validate
from images.smoke import VAULT_CHECK, WORKER_CHECK, docker, wait_for


def main():
    image = sys.argv[1]
    config = json.loads(Path(sys.argv[2]).read_text())
    validate(config)
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
            return docker("exec", "-i", database, "psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-U", "postgres",
                          data=text)

        migrations.apply(sql, config, Path(sys.argv[2]).parent)
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
        docker("exec", "-i", app, "python3", "-", data=WORKER_CHECK)
        # Persist a vault value, then restart the entire process bundle. The
        # master key and one PostgreSQL database must be sufficient to recover it.
        docker("exec", "--env", "SMOKE_WRITE=1", "-i", app, "python3", "-", data=VAULT_CHECK)
        docker("restart", "--time", "15", app)
        address = "http://" + docker("port", app, "8080/tcp")
        wait_for(ready, "restarted app and dependencies")
        docker("exec", "-i", app, "python3", "-", data=VAULT_CHECK)
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
