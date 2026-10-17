#!/usr/bin/env python3
"""Check both Bake targets against the frozen newest-release build manifest."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from images.releases import MANIFEST_LABEL, SERVICES, canonical, validate


def check(config, bake):
    validate(config)
    targets = bake["target"]
    expected = {"app", "ledger", "liaison", "vault", "lode", "lun"}
    contexts = targets["lite"]["contexts"]
    if contexts != {name: f"target:{name}" for name in expected}:
        raise ValueError("Lite must assemble all six source-build targets")
    if targets["local"]["contexts"] != {"combined": "target:lite"}:
        raise ValueError("Local must extend the exact Lite build")
    platform = targets["lite"]["platforms"]
    if platform not in (["linux/amd64"], ["linux/arm64"]):
        raise ValueError("Expected one supported native build platform")
    for name in expected | {"lite", "local"}:
        if targets[name].get("platforms") != platform:
            raise ValueError(f"{name} uses a different platform")
    for name in expected:
        context = targets[name]["context"]
        if context != f"https://github.com/{SERVICES[name][0]}.git#{config['sources'][name]['commit']}":
            raise ValueError(f"{name} must build the resolved release commit")
    for name in ("lite", "local"):
        if targets[name]["labels"].get(MANIFEST_LABEL) != canonical(config):
            raise ValueError(f"{name} must embed its matching source/schema manifest")
    args = targets["lite"]["args"]
    for worker in ("lode", "lun"):
        if args.get(worker.upper() + "_LINEN_REF") != config["sources"][worker]["linen"]:
            raise ValueError(f"{worker}'s native build dependencies must match its release")
    if args.get("LODE_TOOLCHAIN") != config["sources"]["lode"]["toolchain"]:
        raise ValueError("Lode's generated-project toolchain must match its release")


if __name__ == "__main__":
    with open(sys.argv[1]) as stream:
        config = json.load(stream)
    with open(sys.argv[2]) as stream:
        bake = json.load(stream)
    check(config, bake)
    print("ok: both images use the same six resolved release commits and matching SQL")
