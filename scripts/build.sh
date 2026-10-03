#!/usr/bin/env bash
#
# scripts/build.sh
#
# Builds an unofficial Frigate image with Intel Panther Lake NPU support:
# clones upstream Frigate at a release tag into a throwaway working copy,
# patches the NPU driver (and iHD media driver) versions in place, builds it
# with Frigate's own `make local`, and labels the result.
#
# Nothing here forks, merges, or pushes anything back to a repo. The NPU
# change is the same one proposed in blakeblackshear/frigate PR #24007
# (see ATTRIBUTION.md), applied directly to upstream's install_deps.sh with
# this script's own, newer driver version.
#
# Usage:
#   scripts/build.sh <upstream-tag> [--patch-only] [--workdir DIR]
#
#   --patch-only   clone and patch, then stop (no docker build). Used to test
#                  that the patches still apply to a new upstream tag.
#   --workdir DIR  where to clone upstream (default: <repo>/build/frigate)
#
# Exit codes:
#   0 — success
#   1 — a real error (bad tag, patch didn't apply, build failed, ...)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG=""
PATCH_ONLY=0
WORKDIR="$ROOT/build/frigate"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --patch-only) PATCH_ONLY=1; shift ;;
    --workdir)    WORKDIR="${2:?--workdir needs a directory}"; shift 2 ;;
    -*)           echo "ERROR: unknown option $1" >&2; exit 1 ;;
    *)            [[ -z "$TAG" ]] || { echo "ERROR: unexpected argument $1" >&2; exit 1; }; TAG="$1"; shift ;;
  esac
done
[[ -n "$TAG" ]] || { echo "ERROR: usage: $0 <upstream-tag> [--patch-only] [--workdir DIR]" >&2; exit 1; }

UPSTREAM_URL="https://github.com/blakeblackshear/frigate.git"

# ---------------------------------------------------------------------------
# Versions patched in. To bump the NPU driver when Intel ships a newer one,
# update these three variables (check
# https://github.com/intel/linux-npu-driver/releases for the tarball filename
# and the release notes for the paired Level Zero loader).
# ---------------------------------------------------------------------------
NPU_DRIVER_TAG="v1.38.0"
NPU_DRIVER_ASSET="linux-npu-driver-v1.38.0.20260910-34487311128-ubuntu2404.tar.gz"
LEVEL_ZERO_DEB_URL="https://snapshot.ppa.launchpadcontent.net/kobuk-team/intel-graphics/ubuntu/20260830T100000Z/pool/main/l/level-zero-loader/libze1_1.32.0-1~24.04~ppa1_amd64.deb"

# iHD media driver and gmmlib: bumped only when upstream still carries the OLD
# values; if upstream has moved on, the bump is skipped with a warning.
NEW_MEDIA_DRIVER_VERSION="intel-media-26.2.4"
NEW_GMMLIB_VERSION="intel-gmmlib-22.10.0"
OLD_MEDIA_DRIVER_VERSION="intel-media-25.2.6"
OLD_GMMLIB_VERSION="intel-gmmlib-22.7.2"

# (A QSV runtime pin used to be patched here too. It was removed on 2026-09-22
# because it caused an oneVPL/iHD ABI mismatch and never solved a real
# problem; see the README. Do not re-add it.)

log() { echo -e "\n==> $*"; }
die() { echo -e "\nERROR: $*" >&2; exit 1; }

# First interpreter that actually runs (on Windows, `python3` can be a Store stub).
PY=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import sys' >/dev/null 2>&1; then PY="$cand"; break; fi
done
[[ -n "$PY" ]] || die "a working python3 is required for the install_deps.sh patch"

# ---------------------------------------------------------------------------
# Step 1: clone upstream at the tag
# ---------------------------------------------------------------------------
log "Cloning $UPSTREAM_URL at $TAG into $WORKDIR"
rm -rf "$WORKDIR"
git -c core.autocrlf=false clone --quiet --depth 1 --branch "$TAG" "$UPSTREAM_URL" "$WORKDIR" \
  || die "Could not clone tag '$TAG' from upstream (does it exist?)."
UPSTREAM_COMMIT="$(git -C "$WORKDIR" rev-parse HEAD)"

# ---------------------------------------------------------------------------
# Step 2: patch the NPU driver in docker/main/install_deps.sh
#
# Upstream ships the NPU driver as three separate .deb downloads. This swaps
# them for the single release tarball (download, tar -xf, rm) and points the
# Level Zero loader line at the paired libze1 package. Exact-match on purpose:
# if upstream restructures these lines the patch fails loudly instead of
# producing an image without NPU support.
# ---------------------------------------------------------------------------
INSTALL_DEPS="$WORKDIR/docker/main/install_deps.sh"
[[ -f "$INSTALL_DEPS" ]] || die "$INSTALL_DEPS not found at $TAG"

log "Patching NPU driver -> $NPU_DRIVER_TAG"
"$PY" - "$INSTALL_DEPS" "$NPU_DRIVER_TAG" "$NPU_DRIVER_ASSET" "$LEVEL_ZERO_DEB_URL" <<'PYEOF'
import re, sys

path, tag, asset, lz_url = sys.argv[1:5]
s = open(path, encoding="utf-8", newline="").read()

if f"linux-npu-driver/releases/download/{tag}/" in s:
    print(f"install_deps.sh already references {tag} -- nothing to patch")
    sys.exit(0)

deb_re = re.compile(
    r"^(?P<i>[ \t]*)wget https://github\.com/intel/linux-npu-driver/releases/download/[^\s]+\.deb(?P<nl>\r?\n)",
    re.M,
)
matches = list(deb_re.finditer(s))
if len(matches) != 3:
    sys.exit(
        f"expected 3 linux-npu-driver .deb wget lines in {path}, found {len(matches)}; "
        "upstream may have changed this section. Inspect it with "
        "'grep -n -B2 -A6 linux-npu-driver docker/main/install_deps.sh' and update scripts/build.sh."
    )

indent = matches[0].group("i")
nl = matches[0].group("nl")
base = f"https://github.com/intel/linux-npu-driver/releases/download/{tag}/{asset}"
block = f"{indent}wget {base}{nl}{indent}tar -xf {asset}{nl}{indent}rm {asset}{nl}"

for m in reversed(matches[1:]):                      # drop the 2nd and 3rd .deb lines
    s = s[: m.start()] + s[m.end():]
m = matches[0]
s = s[: m.start()] + block + s[m.end():]             # first .deb line -> tarball block

lz_re = re.compile(r"wget https://github\.com/oneapi-src/level-zero/releases/download/v[0-9.]+/level-zero_[^\s]+\.deb")
if len(lz_re.findall(s)) != 1:
    sys.exit("expected exactly 1 oneapi-src/level-zero wget line to replace; upstream may have changed it.")
s = lz_re.sub(lambda _: f"wget {lz_url}", s, count=1)

open(path, "w", encoding="utf-8", newline="").write(s)
print("NPU driver patch applied")
PYEOF
grep -q "linux-npu-driver/releases/download/${NPU_DRIVER_TAG}/" "$INSTALL_DEPS" \
  || die "NPU driver patch did not take effect"

# ---------------------------------------------------------------------------
# Step 3: bump the iHD media driver (VAAPI) and gmmlib
# ---------------------------------------------------------------------------
MEDIA_DRIVER_SCRIPT="$WORKDIR/docker/main/build_intel_media_driver.sh"
if grep -qF "MEDIA_DRIVER_VERSION=\"${NEW_MEDIA_DRIVER_VERSION}\"" "$MEDIA_DRIVER_SCRIPT" 2>/dev/null; then
  log "build_intel_media_driver.sh already at ${NEW_MEDIA_DRIVER_VERSION} -- skipping"
elif grep -qF "MEDIA_DRIVER_VERSION=\"${OLD_MEDIA_DRIVER_VERSION}\"" "$MEDIA_DRIVER_SCRIPT" 2>/dev/null; then
  log "Bumping iHD media driver ${OLD_MEDIA_DRIVER_VERSION} -> ${NEW_MEDIA_DRIVER_VERSION}, gmmlib -> ${NEW_GMMLIB_VERSION}"
  sed -i "s|MEDIA_DRIVER_VERSION=\"${OLD_MEDIA_DRIVER_VERSION}\"|MEDIA_DRIVER_VERSION=\"${NEW_MEDIA_DRIVER_VERSION}\"|" "$MEDIA_DRIVER_SCRIPT"
  sed -i "s|GMMLIB_VERSION=\"${OLD_GMMLIB_VERSION}\"|GMMLIB_VERSION=\"${NEW_GMMLIB_VERSION}\"|" "$MEDIA_DRIVER_SCRIPT"
  grep -qF "MEDIA_DRIVER_VERSION=\"${NEW_MEDIA_DRIVER_VERSION}\"" "$MEDIA_DRIVER_SCRIPT" || die "iHD/gmmlib bump did not apply."
else
  echo "WARNING: neither the old (${OLD_MEDIA_DRIVER_VERSION}) nor new (${NEW_MEDIA_DRIVER_VERSION}) iHD version string found in $MEDIA_DRIVER_SCRIPT -- skipping the bump. Upstream may have moved on; check manually." >&2
fi

if [[ "$PATCH_ONLY" -eq 1 ]]; then
  log "Patches applied to $WORKDIR (--patch-only: not building)"
  echo "UPSTREAM_COMMIT=${UPSTREAM_COMMIT}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 4: build with Frigate's own make target
# ---------------------------------------------------------------------------
log "Building image with 'make local' (never plain 'docker build': it skips generating frigate/version.py and the image crash-loops on startup)"
( cd "$WORKDIR" && make local )

VERSION="${TAG#v}"
IMAGE_TAG="frigate:${VERSION}"
log "Tagging built image as $IMAGE_TAG"
docker tag frigate:latest "$IMAGE_TAG"

# Thin label-only layer so `docker inspect` shows which patched versions and
# which commits went into this build (no functional change to the image).
BUILD_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
log "Labeling image (NPU driver ${NPU_DRIVER_TAG}, build commit ${BUILD_COMMIT})"
docker build -t "$IMAGE_TAG" - <<EOF
FROM ${IMAGE_TAG}
LABEL org.opencontainers.image.source="https://github.com/bdelima/frigate-panther-lake"
LABEL org.opencontainers.image.url="https://github.com/bdelima/frigate-panther-lake"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.revision="${BUILD_COMMIT}"
LABEL dev.pumapants.upstream-frigate-tag="${TAG}"
LABEL dev.pumapants.upstream-frigate-revision="${UPSTREAM_COMMIT}"
LABEL dev.pumapants.npu-driver-version="${NPU_DRIVER_TAG}"
LABEL dev.pumapants.media-driver-version="${NEW_MEDIA_DRIVER_VERSION}"
LABEL dev.pumapants.gmmlib-version="${NEW_GMMLIB_VERSION}"
ENV PANTHER_LAKE_BUILD_VERSION="${VERSION}"
EOF

log "Verifying version.py inside the built image"
docker run --rm --entrypoint sh "$IMAGE_TAG" -c "cat /opt/frigate/frigate/version.py"

echo
echo "============================================================"
echo " Build complete: $IMAGE_TAG"
echo " Upstream: $TAG ($UPSTREAM_COMMIT)"
echo " Build commit: ${BUILD_COMMIT}"
echo " NPU driver baked in: $NPU_DRIVER_TAG"
echo " iHD media driver: ${NEW_MEDIA_DRIVER_VERSION} (gmmlib ${NEW_GMMLIB_VERSION})"
echo "============================================================"

# Export for the calling workflow
echo "IMAGE_TAG=${IMAGE_TAG}" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
echo "VERSION=${VERSION}" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
