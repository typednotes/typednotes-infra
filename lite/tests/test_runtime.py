import importlib.util
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("lite_runtime", ROOT / "runtime.py")
assert spec is not None and spec.loader is not None
runtime = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = runtime
spec.loader.exec_module(runtime)


def configuration():
    keys = ("DATABASE_URL", "SECRETS_MASTER_KEY", "SECRETS_BOOTSTRAP_PASSWORD",
            "SECRETS_SERVER_SERVICE_IDENTITIES", "LIAISON_ROOT_KEY", "APP_SECRETS_PASSWORD",
            "LIAISON_SECRETS_PASSWORD", "LUN_SECRETS_PASSWORD", "LODE_TOKEN", "LUN_TOKEN", "LUN_ID_SALT")
    return {key: "fixture-" + key for key in keys}


class EnvironmentTests(unittest.TestCase):
    def test_workers_do_not_inherit_privileged_credentials(self):
        source = configuration() | {"SCW_SECRET_KEY": "cloud-secret", "GITHUB_CLIENT_SECRET": "oauth-secret",
                                    "COMPUTE_DB_PASSWORD": "admin-secret", "LODE_MODEL_API_KEY": "direct-secret"}
        definitions = {service.name: service for service in runtime.services(source)}
        for name in ("lode", "lun"):
            env = definitions[name].env
            for key in ("DATABASE_URL", "SECRETS_MASTER_KEY", "LIAISON_ROOT_KEY", "SCW_SECRET_KEY",
                        "GITHUB_CLIENT_SECRET", "COMPUTE_DB_PASSWORD", "LODE_MODEL_API_KEY",
                        "APP_SECRETS_PASSWORD", "LIAISON_SECRETS_PASSWORD"):
                self.assertNotIn(key, env, (name, key))
        self.assertNotIn("SECRETS_MASTER_KEY", definitions["app"].env)
        self.assertNotIn("SECRETS_PASSWORD", definitions["lode"].env)
        self.assertEqual(definitions["lun"].env["SECRETS_PASSWORD"], source["LUN_SECRETS_PASSWORD"])
        self.assertEqual(definitions["app"].env["SECRETS_PASSWORD"], source["APP_SECRETS_PASSWORD"])
        self.assertEqual(definitions["liaison"].env["SECRETS_PASSWORD"], source["LIAISON_SECRETS_PASSWORD"])
        self.assertEqual(definitions["ledger"].env["PORT"], "8081")

    def test_app_is_last_and_internal_ports_cannot_collide(self):
        source = configuration() | {"PORT": "9000"}
        definitions = runtime.services(source)
        self.assertEqual(definitions[-1].name, "app")
        self.assertEqual(definitions[-1].env["PORT"], "9000")
        for port in ("8081", "8082", "8083", "8084", "8200", "0", "65536"):
            with self.assertRaises(ValueError):
                runtime.services(source | {"PORT": port})

    def test_missing_configuration_reports_names_not_values(self):
        source = configuration()
        del source["LUN_TOKEN"]
        with self.assertRaisesRegex(ValueError, "LUN_TOKEN") as raised:
            runtime.services(source)
        self.assertNotIn(source["SECRETS_MASTER_KEY"], str(raised.exception))

    def test_serverless_mode_never_silently_accepts_compute_administrator(self):
        with self.assertRaisesRegex(ValueError, "COMPUTE_DB_URL"):
            runtime.services(configuration() | {"COMPUTE_DB_URL": "postgres://admin@compute/db"})


class LocalSupervisor(runtime.Supervisor):
    """Real child processes without container-only Unix users or root privileges."""
    def start(self, service):
        child = subprocess.Popen(service.command, cwd=service.cwd, env=service.env, start_new_session=True)
        self.children.append((service, child))


class SupervisionTests(unittest.TestCase):
    def service(self, name, code, cwd):
        return runtime.Service(name, [sys.executable, "-c", code], {}, "http://unused", cwd=cwd)

    def test_even_a_successful_early_exit_stops_the_whole_container(self):
        with tempfile.TemporaryDirectory() as directory:
            definitions = [self.service("dependency", "import time; time.sleep(60)", directory),
                           self.service("app", "import time; time.sleep(0.1)", directory)]
            supervisor = LocalSupervisor(definitions, shutdown_timeout=1)
            with patch.object(runtime, "healthy", return_value=True):
                self.assertEqual(supervisor.run(), 1)
            self.assertTrue(all(child.poll() is not None for _, child in supervisor.children))

    def test_shutdown_during_startup_is_graceful_and_does_not_start_app(self):
        with tempfile.TemporaryDirectory() as directory:
            definitions = [self.service("dependency", "import time; time.sleep(60)", directory),
                           self.service("app", "import time; time.sleep(60)", directory)]
            supervisor = LocalSupervisor(definitions, shutdown_timeout=1)
            timer = threading.Timer(0.1, supervisor.stop)
            timer.start()
            try:
                with patch.object(runtime, "healthy", return_value=False):
                    self.assertEqual(supervisor.run(), 0)
            finally:
                timer.join()
            self.assertEqual(len(supervisor.children), 1)
            self.assertIsNotNone(supervisor.children[0][1].poll())

    def test_startup_timeout_stops_started_services(self):
        with tempfile.TemporaryDirectory() as directory:
            supervisor = LocalSupervisor([self.service("vault", "import time; time.sleep(60)", directory)],
                                         startup_timeout=0.01, shutdown_timeout=1)
            started = time.monotonic()
            with patch.object(runtime, "healthy", return_value=False):
                self.assertEqual(supervisor.run(), 1)
            self.assertLess(time.monotonic() - started, 3)
            self.assertIsNotNone(supervisor.children[0][1].poll())


class DeploymentSecretTests(unittest.TestCase):
    def run_check(self, mode, **extra):
        env = {"PATH": os.environ["PATH"], "TYPEDNOTES_DEPLOYMENT": mode}
        for key in ("SCW_ACCESS_KEY", "SCW_SECRET_KEY", "SCW_DEFAULT_PROJECT_ID", "SCW_DEFAULT_ORGANIZATION_ID",
                    "SECRETS_MASTER_KEY", "SECRETS_BOOTSTRAP_PASSWORD", "LIAISON_ROOT_KEY",
                    "APP_SECRETS_PASSWORD", "LIAISON_SECRETS_PASSWORD", "LUN_SECRETS_PASSWORD",
                    "LODE_TOKEN", "LUN_TOKEN", "LUN_ID_SALT", "GITHUB_CLIENT_ID", "GITHUB_CLIENT_SECRET",
                    "GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET", "GITLAB_CLIENT_ID", "GITLAB_CLIENT_SECRET",
                    "DROPBOX_CLIENT_ID", "DROPBOX_CLIENT_SECRET", "SLACK_CLIENT_ID", "SLACK_CLIENT_SECRET",
                    "SLACK_SIGNING_SECRET", "WHATSAPP_APP_SECRET", "WHATSAPP_VERIFY_TOKEN"):
            env[key] = "x" * 32
        env.update(extra)
        return subprocess.run(["bash", str(ROOT.parent / "scripts/check-deployment-secrets.sh")],
                              env=env, capture_output=True, text=True, check=False)

    def test_lite_does_not_require_compute_or_inspector_secrets(self):
        result = self.run_check("lite")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_full_still_requires_its_database_and_inspector_secrets(self):
        result = self.run_check("full")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("COMPUTE_DB_PASSWORD", result.stderr)
        self.assertIn("DB_INSPECTOR_PASSWORD", result.stderr)
        result = self.run_check("full", COMPUTE_DB_PASSWORD="Valid-Password1", DB_INSPECTOR_USERNAME="operator",
                                DB_INSPECTOR_PASSWORD="fixture")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_full_rejects_invalid_compute_password_and_lite_rejects_short_tokens(self):
        result = self.run_check("full", COMPUTE_DB_PASSWORD="invalid", DB_INSPECTOR_USERNAME="operator",
                                DB_INSPECTOR_PASSWORD="fixture")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("COMPUTE_DB_PASSWORD", result.stderr)
        result = self.run_check("lite", LUN_TOKEN="short")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("LUN_TOKEN", result.stderr)
