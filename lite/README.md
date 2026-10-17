# Building Typednotes Lite

Lite packages the Typednotes app, Ledger, Liaison, Secrets, Lode and Lun into
one application image, backed by one PostgreSQL database. This directory
contains the build orchestration, image assembly, process supervisor and checks.
See [the deployment guide](../docs/lite.md) for CI, configuration, database
limitations and recovery.

## What is `docker-bake.hcl`?

[`docker-bake.hcl`](docker-bake.hcl) is the **build recipe that connects the six
service builds to the final Lite image**. It is read by Docker Buildx Bake;
HCL is the configuration language used to describe its build targets.

The file defines:

- **Sources:** each service's Git repository and pinned release tag, selected
  by variables such as `APP_REF` and `LUN_REF`.
- **Service builds:** each repository builds through its own Dockerfile.
- **Dependencies:** the six build results become named inputs to the `lite`
  target, which assembles the combined image using this directory's Dockerfile.
- **Shared settings:** Linux amd64, GitHub Actions build caches, image labels
  and the output image name (`LITE_IMAGE`).

The default group selects `lite`, so building that target also builds the six
service targets it depends on. BuildKit schedules the dependencies and reuses
cached build steps. Intermediate service images do not need to be published.
Service sources come from the configured remote Git tags, rather than sibling
working directories on the build machine.

## How the Dockerfiles connect

The final target declares named contexts:

```hcl
target "lite" {
  context = "."
  dockerfile = "lite/Dockerfile"
  contexts = {
    app = "target:app"
    # The other five services are connected in the same way.
  }
}
```

`target:app` means “use the build result of the `app` Bake target.” This allows
[`Dockerfile`](Dockerfile) to copy the already-built application:

```dockerfile
COPY --from=app /usr/local/app /usr/local/app
```

The same mechanism supplies the other service executables, the Lean toolchain
and the warm package cache. Each service repository owns its compilation steps;
the Lite Dockerfile owns the final filesystem layout and runtime dependencies.

## Build locally

Run these commands **from the repository root**, with Docker Buildx installed.
Inspect the resolved build graph without building images:

```sh
docker buildx bake -f lite/docker-bake.hcl --print
```

Build all six services and load the final image into a running Docker daemon:

```sh
docker buildx bake -f lite/docker-bake.hcl \
  --set '*.cache-from=' \
  --set '*.cache-to=' \
  --set lite.output=type=docker
```

The cache overrides disable GitHub Actions caches, which need the Actions
runtime. The output image defaults to `ghcr.io/typednotes/typednotes-lite:latest`;
set `LITE_IMAGE=typednotes-lite:local` before the command to use a local name.
Building the image does not start the services or deploy cloud resources.

When changing source releases, keep the app, ledger and vault refs aligned with
their schema releases in [`Fleet.lean`](../Fleet.lean). CI checks this alignment
before building.

## Build, runtime and deployment responsibilities

- **`docker-bake.hcl`** coordinates the source builds and their dependencies.
- **`Dockerfile`** assembles the combined application image.
- **[`runtime.py`](runtime.py)** starts and supervises the six service processes
  inside the running container.
- **[`Fleet/Lite.lean`](../Fleet/Lite.lean)** declares the serverless container,
  database, migrations and supporting cloud resources.
- **[`apply.yml`](../.github/workflows/apply.yml)** builds and smoke-tests the
  image, publishes it, then deploys its exact digest when Lite is selected.

Bake is a build-time tool; it does not run inside the deployed container.
For more background, see [Docker's documentation on linking Bake targets](https://docs.docker.com/build/bake/contexts/).
