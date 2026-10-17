#!/usr/bin/env python3
"""Check Bake's resolved graph against the schema releases Infra will apply."""
import json
import sys


def check(config, bake):
    targets = bake["target"]
    expected = {"app", "ledger", "liaison", "vault", "lode", "lun"}
    contexts = targets["lite"]["contexts"]
    if contexts != {name: f"target:{name}" for name in expected}:
        raise ValueError("Lite must assemble all six source-build targets")
    for name in expected | {"lite"}:
        if targets[name].get("platforms") != ["linux/amd64"]:
            raise ValueError(f"{name} must build for Scaleway's Linux amd64 runtime")
    for name in expected:
        context = targets[name]["context"]
        repo = {"app": "typednotes", "vault": "secrets"}.get(name, name)
        prefix = f"https://github.com/typednotes/{repo}.git#"
        if not context.startswith(prefix) or not context[len(prefix):].startswith("v"):
            raise ValueError(f"{name} must build its own pinned source release")
    for name, ref in config["schemaRefs"].items():
        if not targets[name]["context"].endswith("#" + ref):
            raise ValueError(f"{name}'s image source must match the declared schema release {ref}")


if __name__ == "__main__":
    with open(sys.argv[1]) as stream:
        config = json.load(stream)
    with open(sys.argv[2]) as stream:
        bake = json.load(stream)
    check(config, bake)
    print("ok: all six source builds, with application/ledger/vault schema releases aligned")
