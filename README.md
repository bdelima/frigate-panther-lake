# frigate-panther-lake

An unofficial build of [Frigate](https://github.com/blakeblackshear/frigate) with Intel Panther Lake NPU support. For each upstream Frigate release, this repo clones upstream at that tag, patches the NPU driver (and the iHD media driver) to newer versions, builds it with Frigate's own `make local`, and publishes the result to Docker Hub as [`bdelima/frigate-panther-lake`](https://hub.docker.com/r/bdelima/frigate-panther-lake).

**This is an unofficial, personal build.** It is not affiliated with, endorsed by, or supported by Frigate, Inc. or Kellen Renshaw. See [`ATTRIBUTION.md`](ATTRIBUTION.md) for credit and licensing on everything this build bundles.

This repo contains only the build tooling: no Frigate source, no fork. Nothing is merged or pushed back anywhere during a build.

## What gets patched

Applied to upstream's `docker/main/` files at build time by [`scripts/build.sh`](scripts/build.sh), which is the single source of truth for exact versions:

1. **NPU driver** (`install_deps.sh`): upstream ships three `.deb` downloads (currently driver v1.19.0). The build replaces them with the single release tarball of a newer driver (currently `v1.38.0`), and points the Level Zero loader line at the paired `libze1` package.
2. **iHD media driver and `gmmlib`** (`build_intel_media_driver.sh`): bumped to current quarterly releases, compiled from source (not an apt pin).

The NPU change follows the approach of Kellen Renshaw's upstream PR [#24007](https://github.com/blakeblackshear/frigate/pull/24007) (see `ATTRIBUTION.md`), applied directly to upstream with this repo's newer driver version.

### Removed: the QSV runtime pin (2026-09-22)

Earlier builds also pinned the QSV runtime (`libmfxgen1`/`libvpl2`) to older, pre-regression versions from Intel's jammy apt repo, working around a QSV performance regression in Frigate 0.18. That diagnosis was later found to be wrong: the real cause was a filter-chain ordering bug in `frigate/ffmpeg_presets.py`, which this build deliberately does not patch (it's worked around with a config-level `output_args.detect` override in `config.yaml`). The pin outlived its purpose and, in the `0.18.0-panther_lake` build, was paired for the first time with the bumped iHD media driver, an untested combination that turned out to be ABI-incompatible: every camera failed at ffmpeg startup with `[QSV @ ...] Error setting child device handle: -17`. The pin was removed entirely (not re-pinned) since it never solved a real problem. If you're running an image built before this fix, roll back to the previous working tag and rebuild. **Do not re-add it.**

## Inspecting a running image's build metadata

Beyond Frigate's own `/api/version`, this build labels the image so `docker inspect bdelima/frigate-panther-lake:<tag>` shows what went into it:

- `org.opencontainers.image.version` / `.revision`: this build's version string and the exact commit of this repo it was built from.
- `org.opencontainers.image.source` / `.url`: this repo (`bdelima/frigate-panther-lake`).
- `dev.pumapants.upstream-frigate-tag` / `.upstream-frigate-revision`: the upstream Frigate release and commit it was cloned from.
- `dev.pumapants.npu-driver-version` / `.media-driver-version` / `.gmmlib-version`: the patched driver versions baked into this build.
- `PANTHER_LAKE_BUILD_VERSION`: the version string, also available as an environment variable inside the container.

## How builds happen

[`.github/workflows/auto-build-publish.yml`](.github/workflows/auto-build-publish.yml) (daily once enabled; manual via *Run workflow* any time):

1. Finds the latest stable upstream release tag (`vX.Y.Z`, no rc/beta), or uses the `tag` you give it.
2. Checks Docker Hub; if that version is already published, it stops (no-op), unless `force` is set.
3. Runs `scripts/build.sh <tag>`: shallow-clones upstream at the tag, patches it, runs `make local` (never plain `docker build`: it skips generating `frigate/version.py` and the image crash-loops on startup), tags and labels the image.
4. Pushes `:<version>` and `:latest` to Docker Hub and creates a GitHub Release.

Manual-run options: `dry_run` builds without publishing; `force` republishes an existing version.

The job runs in the `release` Environment, restricted to the `main` branch, which holds the Docker Hub secrets.

## When a build fails

The patch is an exact match on purpose. If upstream restructures the NPU section of `install_deps.sh` (or merges the driver bump itself), `build.sh` fails with a message saying which lines it couldn't find, and the run stops without publishing. To investigate locally:

```bash
scripts/build.sh v0.18.1 --patch-only --workdir /tmp/frigate-test   # clone + patch, no docker build
grep -n -B2 -A6 linux-npu-driver /tmp/frigate-test/docker/main/install_deps.sh
```

Then update the patch logic or version variables at the top of `scripts/build.sh`, and re-run the workflow.

To bump the NPU driver when Intel ships a newer one, update `NPU_DRIVER_TAG`, `NPU_DRIVER_ASSET` and `LEVEL_ZERO_DEB_URL` in `scripts/build.sh`.

## Running it

```yaml
services:
  frigate:
    image: bdelima/frigate-panther-lake:latest   # or pin to a specific version, e.g. :0.18.1
    # ... your existing Frigate compose config (devices, volumes, ports) is unchanged
```

See [`docker-compose.example.yml`](docker-compose.example.yml).

## Repo setup notes

- Docker Hub credentials are Environment secrets on the `release` Environment: `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (use a token scoped to this one image, Read & Write, no Delete). Only the repo owner sets them.
- Changes reach `main` only through pull requests (ruleset `protect-main`).
