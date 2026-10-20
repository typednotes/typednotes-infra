import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("deployment_config", ROOT / "scripts/deployment-config.py")
assert SPEC is not None and SPEC.loader is not None
config = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(config)
DIGEST = "ghcr.io/typednotes/typednotes-lite@sha256:" + "a" * 64


class DeploymentConfigurationTests(unittest.TestCase):
    def test_current_is_persisted_for_pushes_and_manual_operations(self):
        self.assertEqual(config.resolve(), ("lite", config.DEFAULT_IMAGE))
        self.assertEqual(config.resolve(configured="full"), ("full", config.DEFAULT_IMAGE))
        for operation in ("plan", "apply", "destroy"):
            self.assertEqual(config.resolve(configured="full-from-lite", configured_image=DIGEST, operation=operation),
                             ("full-from-lite", config.DEFAULT_IMAGE if operation == "destroy" else DIGEST))

    def test_promotion_and_bundle_upgrade_must_first_be_persisted(self):
        with self.assertRaisesRegex(ValueError, "before promotion"):
            config.resolve(requested="full-from-lite", image=DIGEST)
        with self.assertRaisesRegex(ValueError, "tested bundle digest"):
            config.resolve(configured="full-from-lite")
        updated = DIGEST.replace("a" * 64, "b" * 64)
        with self.assertRaisesRegex(ValueError, "before selecting a new bundle"):
            config.resolve(configured="full-from-lite", configured_image=DIGEST, image=updated)
        self.assertEqual(config.resolve(configured="full-from-lite", configured_image=updated, image=updated)[1], updated)

    def test_downgrade_is_refused_and_emergency_teardown_needs_no_image(self):
        for operation in ("plan", "apply", "destroy"):
            with self.assertRaisesRegex(ValueError, "downgrade/teardown"):
                config.resolve(requested="lite", configured="full-from-lite", configured_image=DIGEST, operation=operation)
        self.assertEqual(config.resolve(configured="full-from-lite", operation="destroy")[0], "full-from-lite")
        self.assertEqual(config.resolve(configured="full-from-lite", configured_image="invalid", operation="destroy")[0], "full-from-lite")
        self.assertEqual(config.resolve(requested="full", configured="full-from-lite")[0], "full")

    def test_invalid_configuration_cannot_inject_workflow_outputs(self):
        for arguments in ({"configured": "bad"}, {"requested": "lite-storage"}, {"image": DIGEST + "\ninjected=true"}):
            with self.assertRaises(ValueError):
                config.resolve(**arguments)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            subprocess.run([sys.executable, str(ROOT / "scripts/deployment-config.py")],
                           env={"PATH": os.environ["PATH"], "GITHUB_OUTPUT": str(output),
                                "CONFIGURED_DEPLOYMENT": "full-from-lite", "CONFIGURED_IMAGE": DIGEST}, check=True)
            self.assertEqual(output.read_text(), f"deployment=full-from-lite\nimage={DIGEST}\n")
