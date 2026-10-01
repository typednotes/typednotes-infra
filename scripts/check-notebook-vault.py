#!/usr/bin/env python3
"""Verify the authored ACLs with a real secrets-server and disposable PostgreSQL.

Usage: python3 scripts/check-notebook-vault.py /path/to/secrets-server
Requires initdb, pg_ctl and psql on PATH. Never contacts a cloud or production DB.
"""
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
SCRATCH = os.environ.get("NOTEBOOK_TEST_TMPDIR", tempfile.gettempdir())


def port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def run(*args, **kwargs):
    try:
        return subprocess.check_output(args, stderr=subprocess.STDOUT, **kwargs)
    except subprocess.CalledProcessError as error:
        raise RuntimeError(f"{args[0]} failed: {error.output.decode(errors='replace')}") from error


def main():
    binary = Path(sys.argv[1]).resolve()
    assert binary.is_file(), "Pass the compiled secrets-server executable"
    identities = run("lake", "env", "lean", "--run", "scripts/notebook-vault-config.lean", cwd=ROOT).decode()
    with tempfile.TemporaryDirectory(prefix="notebook-vault-", dir=SCRATCH) as directory:
        work = Path(directory)
        pg = work / "postgres"
        pg_port, http_port = port(), port()
        run("initdb", "-D", str(pg), "-U", "fixture", "--auth=trust", "--no-locale", "--encoding=UTF8")
        run("pg_ctl", "-D", str(pg), "-l", str(work / "postgres.log"), "-o",
            f"-h 127.0.0.1 -p {pg_port} -c unix_socket_directories=''", "-w", "start")
        server = None
        try:
            url = f"postgres://fixture@127.0.0.1:{pg_port}/postgres"
            passwords = {user: secrets.token_hex(32) for user in ("admin", "typednotes-app", "liaison", "lun")}
            env = {"PATH": os.environ["PATH"], "HOME": str(work),
                   "SECRETS_MASTER_KEY": secrets.token_hex(32),
                   "SECRETS_SERVER_LISTEN_ADDR": f"127.0.0.1:{http_port}",
                   "SECRETS_SERVER_STORAGE_DATABASE_URL": url,
                   "SECRETS_SERVER_BOOTSTRAP_USERNAME": "admin",
                   "SECRETS_SERVER_BOOTSTRAP_PASSWORD": passwords["admin"],
                   "SECRETS_SERVER_SERVICE_IDENTITIES": identities,
                   "APP_SECRETS_PASSWORD": passwords["typednotes-app"],
                   "LIAISON_SECRETS_PASSWORD": passwords["liaison"],
                   "LUN_SECRETS_PASSWORD": passwords["lun"]}
            with (work / "vault.log").open("wb") as log:
                server = subprocess.Popen([str(binary)], cwd=work, env=env, stdout=log, stderr=log)
                base = f"http://127.0.0.1:{http_port}"

                def request(method, path, body=None, token=None):
                    headers = {"Content-Type": "application/json"}
                    if token:
                        headers["Authorization"] = f"Bearer {token}"
                    try:
                        with urlopen(Request(base + path, method=method, headers=headers,
                                             data=None if body is None else json.dumps(body).encode()), timeout=5) as response:
                            return response.status, json.loads(response.read() or b"{}")
                    except HTTPError as error:
                        return error.code, {}

                deadline = time.monotonic() + 30
                while True:
                    assert server.poll() is None, "Vault rejected the authored identity configuration"
                    try:
                        code, body = request("POST", "/v1/auth/userpass/login", {
                            "username": "admin", "password": passwords["admin"]})
                        if code == 200:
                            break
                    except URLError:
                        pass
                    assert time.monotonic() < deadline, "Vault startup timeout"
                    time.sleep(0.1)
                tokens = {"admin": body["auth"]["client_token"]}
                for user in ("typednotes-app", "liaison", "lun"):
                    code, body = request("POST", "/v1/auth/userpass/login", {"username": user, "password": passwords[user]})
                    assert code == 200, f"Identity login refused: {user}"
                    tokens[user] = body["auth"]["client_token"]

                checks = 0

                def expect(user, method, path, allowed, body=None):
                    nonlocal checks
                    code, _ = request(method, "/v1/" + path, body, tokens[user])
                    assert (200 <= code < 300) if allowed else code == 403, (user, method, path, code)
                    checks += 1

                paths = ["secret/data/compute/org/user", "secret/data/graph/org/graph/token",
                         "secret/data/connector-policy/org/postgres/compute",
                         "secret/data/connector-authority/org/run/warrant",
                         "secret/data/thirdparty/postgres/user/compute/permissions",
                         "secret/data/thirdparty/vault/user/graph/permissions"]
                for path in paths:
                    expect("typednotes-app", "POST", path, True, {"data": {"value": "fixture"}})
                    expect("lun", "GET", path, True)
                    expect("typednotes-app", "GET", path, False)
                provider = "secret/data/thirdparty/anthropic/user/account"
                expect("typednotes-app", "POST", provider, True, {"data": {"token": "fixture"}})
                expect("lun", "GET", provider, False)
                expect("liaison", "GET", provider, True)
                expect("lun", "POST", paths[0], False, {"data": {"value": "forged"}})
                expect("lun", "DELETE", paths[0], False)
                expect("lun", "POST", paths[1], True, {"data": {"value": "runtime"}})
                expect("lun", "DELETE", paths[1], False)
                expect("typednotes-app", "POST", paths[1], True, {"data": {"value": "updated"}})
                expect("lun", "GET", "secret/metadata/graph/org/graph?list=true", True)
                expect("typednotes-app", "GET", "secret/metadata/graph/org/graph?list=true", False)
                expect("lun", "POST", paths[2], False, {"data": {"scopes": []}})
                print(f"ok: real vault parser, service login and {checks} permitted/denied namespace calls")
        finally:
            if server is not None:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()
            run("pg_ctl", "-D", str(pg), "-m", "immediate", "-w", "stop")


if __name__ == "__main__":
    main()
