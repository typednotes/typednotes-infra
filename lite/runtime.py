#!/usr/bin/env python3
"""Supervise the six Lite services; schemas are applied by Infra, never here."""

import os
import pwd
import shutil
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.error import URLError
from urllib.request import ProxyHandler, Request, build_opener


@dataclass
class Service:
    name: str
    command: list[str]
    env: dict[str, str]
    health: str
    cwd: str = "/usr/local/app"
    token: str | None = None


def services(source, *, state_root=None, allow_compute=False):
    """Allowlist inherited variables: workers must not inherit the parent's
    vault master key, warrant root, database URL or provider credentials.
    Every service also runs under a different Unix identity.
    """
    required = (
        "DATABASE_URL", "SECRETS_MASTER_KEY", "SECRETS_BOOTSTRAP_PASSWORD",
        "SECRETS_SERVER_SERVICE_IDENTITIES", "LIAISON_ROOT_KEY",
        "APP_SECRETS_PASSWORD", "LIAISON_SECRETS_PASSWORD", "LUN_SECRETS_PASSWORD",
        "LODE_TOKEN", "LUN_TOKEN", "LUN_ID_SALT",
    )
    missing = [key for key in required if not source.get(key)]
    if missing:
        raise ValueError("Missing configuration: " + ", ".join(missing))
    if source.get("COMPUTE_DB_URL") and not allow_compute:
        raise ValueError("Lite uses Serverless SQL; COMPUTE_DB_URL must be unset")
    port = int(source.get("PORT", "8080"))
    if not 1 <= port <= 65535 or port in (8081, 8082, 8083, 8084, 8200):
        raise ValueError("PORT must be valid and distinct from Lite's internal ports")

    def home(name):
        return str(Path(state_root or "/var/lib") / name)

    def environment(name, keys=(), prefixes=(), **overrides):
        env = {key: source[key] for key in ("PATH", "SSL_CERT_FILE", "SSL_CERT_DIR") if key in source}
        env.update({key: value for key, value in source.items()
                    if key in keys or any(key.startswith(prefix) for prefix in prefixes)})
        env.update(HOME=home(name), LANG="C.UTF-8", **overrides)
        return env

    oauth_prefixes = ("GITHUB_CLIENT_", "GOOGLE_CLIENT_", "GITLAB_CLIENT_",
                      "DROPBOX_CLIENT_", "SLACK_", "WHATSAPP_", "MICROSOFT_CLIENT_")
    vault = Service("vault", ["/usr/local/bin/secrets-server"], environment(
        "vault", ("SECRETS_MASTER_KEY", "SECRETS_MASTER_KEY_RETIRED",
                  "SECRETS_SERVER_SERVICE_IDENTITIES", "APP_SECRETS_PASSWORD",
                  "LIAISON_SECRETS_PASSWORD", "LUN_SECRETS_PASSWORD"),
        SECRETS_SERVER_LISTEN_ADDR="127.0.0.1:8200",
        SECRETS_SERVER_STORAGE_DATABASE_URL=source["DATABASE_URL"],
        SECRETS_SERVER_STORAGE_MIGRATE="false",
        SECRETS_SERVER_BOOTSTRAP_USERNAME="admin",
        SECRETS_SERVER_BOOTSTRAP_PASSWORD=source["SECRETS_BOOTSTRAP_PASSWORD"],
    ), "http://127.0.0.1:8200/v1/sys/health")
    ledger = Service("ledger", ["/usr/local/bin/ledger"], environment(
        "ledger", ("DATABASE_URL", "LEDGER_SWEEP_INTERVAL_SECONDS"), PORT="8081",
    ), "http://127.0.0.1:8081/health")
    liaison = Service("liaison", ["/usr/local/bin/liaison"], environment(
        "liaison", ("DATABASE_URL", "LIAISON_ROOT_KEY"), oauth_prefixes,
        LIAISON_PORT="8082", SECRETS_HOST="127.0.0.1", SECRETS_PORT="8200",
        SECRETS_INSECURE="1", SECRETS_USERNAME="liaison",
        SECRETS_PASSWORD=source["LIAISON_SECRETS_PASSWORD"],
    ), "http://127.0.0.1:8082/_health")
    lun = Service("lun", ["/usr/local/bin/lun"], environment(
        "lun", ("LUN_TOKEN", "LUN_ID_SALT", "LUN_WORKERS", "LUN_BUILD_TIMEOUT",
                "LUN_FETCH_TIMEOUT", "LUN_CALL_TIMEOUT"),
        LUN_PORT="8083", LUN_WORKDIR=home("lun") + "/work", LUN_PACKAGE_CACHE="/opt/lun/cache",
        LUN_LIAISON_URL="http://127.0.0.1:8082", ELAN_HOME=home("lun") + "/elan",
        SECRETS_HOST="127.0.0.1", SECRETS_PORT="8200", SECRETS_INSECURE="1",
        SECRETS_USERNAME="lun", SECRETS_PASSWORD=source["LUN_SECRETS_PASSWORD"],
    ), "http://127.0.0.1:8083/_health", token=source["LUN_TOKEN"])
    lode = Service("lode", ["/usr/local/bin/lode"], environment(
        "lode", ("LODE_TOKEN", "LODE_MAX_STEPS", "LODE_MODEL_TIMEOUT", "LODE_GIT_TIMEOUT",
                 "LODE_CHECK_TIMEOUT", "LODE_LUN_BUILD_TIMEOUT", "LODE_LUN_CALL_TIMEOUT"),
        LODE_PORT="8084", LODE_WORKDIR=home("lode") + "/work", LODE_PACKAGE_CACHE="/opt/lode/cache",
        LODE_LINEN_REV=source.get("LODE_LINEN_REF", "v1.12.0"), ELAN_HOME=home("lode") + "/elan",
        LODE_TOOLCHAIN=source.get("LODE_TOOLCHAIN", "leanprover/lean4:v4.34.0"),
        LODE_LIAISON_URL="http://127.0.0.1:8082", LODE_LUN_URL="http://127.0.0.1:8083",
        LODE_LUN_TOKEN=source["LUN_TOKEN"],
    ), "http://127.0.0.1:8084/_health", token=source["LODE_TOKEN"])
    app = Service("app", ["/usr/local/app/server"], environment(
        "app", ("DATABASE_URL", "LIAISON_ROOT_KEY", "LODE_TOKEN", "LUN_TOKEN", "PUBLIC_URL"),
        oauth_prefixes + ("TYPEDNOTES_",),
        IP="0.0.0.0", PORT=str(port),
        SECRETS_URL="http://127.0.0.1:8200", SECRETS_USERNAME="typednotes-app",
        SECRETS_PASSWORD=source["APP_SECRETS_PASSWORD"],
        LIAISON_URL="http://127.0.0.1:8082", LODE_URL="http://127.0.0.1:8084",
        LUN_URL="http://127.0.0.1:8083",
    ), f"http://127.0.0.1:{port}/api/health")
    if allow_compute and source.get("COMPUTE_DB_URL"):
        app.env["COMPUTE_DB_URL"] = source["COMPUTE_DB_URL"]
    # Do not accept public traffic until every dependency is serving.
    return [vault, ledger, liaison, lun, lode, app]


def healthy(service):
    headers = {"Authorization": f"Bearer {service.token}"} if service.token else {}
    try:
        # Loopback checks must not follow deployment HTTP proxy settings.
        with build_opener(ProxyHandler({})).open(Request(service.health, headers=headers), timeout=2) as reply:
            return reply.status == 200
    except (OSError, URLError):
        return False


def prepare_home(service):
    identity = pwd.getpwnam(service.name)
    home = Path(service.env["HOME"])
    home.parent.mkdir(mode=0o711, parents=True, exist_ok=True)
    home.mkdir(mode=0o700, exist_ok=True)
    os.chmod(home, 0o700)
    os.chown(home, identity.pw_uid, identity.pw_gid)
    return identity


def prepare_worker(name):
    # Run AFTER dropping privileges. Persistent worker files must never direct
    # privileged filesystem writes through user-created symlinks on restart.
    tools = Path(os.environ["ELAN_HOME"]) / "toolchains"
    tools.mkdir(parents=True, exist_ok=True)
    for entry in tools.iterdir():
        if entry.is_symlink() and not entry.exists():
            entry.unlink()
    settings = tools.parent / "settings.toml"
    if settings.is_symlink():
        settings.unlink()
    shutil.copyfile(f"/opt/typednotes/{name}-settings.toml", settings)
    for toolchain in Path("/opt/elan/toolchains").iterdir():
        target = tools / toolchain.name
        if not target.exists():
            target.symlink_to(toolchain, target_is_directory=True)


class Supervisor:
    def __init__(self, definitions, startup_timeout=180, shutdown_timeout=10):
        self.definitions = definitions
        self.startup_timeout = startup_timeout
        self.shutdown_timeout = shutdown_timeout
        self.children = []
        self.stopping = threading.Event()

    def stop(self, *_):
        self.stopping.set()

    def check_children(self):
        for service, child in self.children:
            code = child.poll()
            if code is not None:
                raise RuntimeError(f"{service.name} exited ({code})")

    def start(self, service):
        identity = prepare_home(service)
        if service.name in ("lode", "lun"):
            subprocess.run([sys.executable, __file__, "--prepare-worker", service.name],
                           env=service.env, user=identity.pw_uid, group=identity.pw_gid,
                           extra_groups=[], umask=0o077, check=True)
        child = subprocess.Popen(service.command, cwd=service.cwd, env=service.env,
                                 user=identity.pw_uid, group=identity.pw_gid,
                                 extra_groups=[], umask=0o077, start_new_session=True)
        self.children.append((service, child))
        print(f"lite: started {service.name}", flush=True)

    def shutdown(self):
        # Signal whole groups, including compiler and generated-code children.
        for _, child in reversed(self.children):
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + self.shutdown_timeout
        while time.monotonic() < deadline:
            if all(child.poll() is not None for _, child in self.children):
                break
            time.sleep(0.1)
        # Kill any remaining group members even if their parent already exited.
        for _, child in reversed(self.children):
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()

    def run(self):
        try:
            for service in self.definitions:
                if self.stopping.is_set():
                    return 0
                self.start(service)
                deadline = time.monotonic() + self.startup_timeout
                while not healthy(service):
                    self.check_children()
                    if self.stopping.wait(0.2):
                        return 0
                    if time.monotonic() >= deadline:
                        raise RuntimeError(f"{service.name} did not become healthy")
            print("lite: all six services ready", flush=True)
            while not self.stopping.wait(0.5):
                self.check_children()
            return 0
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            # Do not stringify exceptions that could include environment values.
            print(f"lite: {error}" if isinstance(error, RuntimeError) else "lite: could not start service", file=sys.stderr)
            return 1
        finally:
            self.shutdown()


def main():
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "--prepare-worker" and sys.argv[2] in ("lode", "lun"):
            prepare_worker(sys.argv[2])
            return 0
        definitions = services(os.environ)
        if sys.argv[1:] == ["--healthcheck"]:
            return 0 if all(healthy(service) for service in definitions) else 1
        if sys.argv[1:]:
            raise ValueError("Usage: runtime.py [--healthcheck]")
        supervisor = Supervisor(definitions, startup_timeout=int(os.environ.get("LITE_STARTUP_TIMEOUT", "180")))
        signal.signal(signal.SIGTERM, supervisor.stop)
        signal.signal(signal.SIGINT, supervisor.stop)
        return supervisor.run()
    except ValueError as error:
        print(f"lite: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
