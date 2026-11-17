"""Resolve the persisted repository topology for all deployment workflows."""
import os
import re

MODES = ("lite", "full-from-lite", "full")
DEFAULT_IMAGE = "ghcr.io/typednotes/typednotes-lite:latest"
DIGEST = re.compile(r"ghcr\.io/typednotes/typednotes-lite@sha256:[0-9a-f]{64}\Z")
IMAGE = re.compile(r"ghcr\.io/typednotes/typednotes-lite(?::[-\w.]+|@sha256:[0-9a-f]{64})\Z")


def resolve(requested: str = "current", configured: str = "", image: str = "", configured_image: str = "",
            operation: str = "plan") -> tuple[str, str]:
    if operation not in ("plan", "apply", "destroy"):
        raise ValueError("Invalid deployment operation")
    current = configured or "lite"
    if current not in MODES:
        raise ValueError("Repository variable TYPEDNOTES_DEPLOYMENT must be lite, full-from-lite or full")
    mode = current if requested == "current" else requested
    if mode not in MODES:
        raise ValueError("Invalid deployment selection")
    if current == "full-from-lite" and mode == "lite":
        raise ValueError("The configured fleet is full-from-lite; Lite downgrade/teardown is not supported")
    if mode == "full-from-lite":
        if current != mode:
            raise ValueError("Set repository variable TYPEDNOTES_DEPLOYMENT=full-from-lite before promotion")
        if operation != "destroy":
            if not DIGEST.fullmatch(configured_image):
                raise ValueError("Set repository variable TYPEDNOTES_LITE_IMAGE to a tested bundle digest")
            if image and image != configured_image:
                raise ValueError("Update repository variable TYPEDNOTES_LITE_IMAGE before selecting a new bundle")
        selected_image = DEFAULT_IMAGE if operation == "destroy" else configured_image
    else:
        selected_image = image or DEFAULT_IMAGE
    if not IMAGE.fullmatch(selected_image):
        raise ValueError("Invalid Lite image reference")
    return mode, selected_image


if __name__ == "__main__":
    try:
        mode, image = resolve(os.environ.get("REQUESTED_DEPLOYMENT", "current"),
                              os.environ.get("CONFIGURED_DEPLOYMENT", ""), os.environ.get("REQUESTED_IMAGE", ""),
                              os.environ.get("CONFIGURED_IMAGE", ""), os.environ.get("DEPLOYMENT_OPERATION", "plan"))
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write(f"deployment={mode}\nimage={image}\n")
    except ValueError as error:
        raise SystemExit(str(error)) from None
