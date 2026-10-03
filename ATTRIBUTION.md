# Attribution

This build combines several projects. None of the actual NVR functionality, NPU driver support, or media driver code originates in this repo. This repo's own contribution is limited to the version-bump patches and CI automation in `scripts/build.sh` and `.github/workflows/`.

## Frigate

- **Project:** [Frigate](https://github.com/blakeblackshear/frigate), an open-source NVR with realtime AI object detection.
- **License:** MIT, © Frigate, Inc.
- **Trademark:** the "Frigate" name, branding, and logo are trademarks of Frigate, Inc. and are **not** covered by the MIT License (Frigate's own repo carries a separate trademark policy). This build's Docker Hub tag (`bdelima/frigate-panther-lake`) uses "frigate" descriptively, to say what it's a build of. It is not an official Frigate, Inc. release and carries no official branding or endorsement.

## Kellen Renshaw's Panther Lake NPU driver PR

- **Upstream PR:** [blakeblackshear/frigate#24007](https://github.com/blakeblackshear/frigate/pull/24007), "Update Intel NPU drivers to 1.28.0" (open, not merged as of this writing); from [KellenRenshaw/frigate](https://github.com/KellenRenshaw/frigate), branch `npu-update`.
- **License:** MIT, inherited unchanged from Frigate.
- The PR showed how to add Panther Lake NPU support to Frigate's image: replace the three separate NPU driver `.deb` downloads in `docker/main/install_deps.sh` with the single driver release tarball. This repo applies that same change directly to upstream at build time (in `scripts/build.sh`), with a newer driver version than the PR pins, instead of merging his branch. This build is not a derivative of his repo and does not fetch from it, but the NPU support it relies on originates from his work, and that credit stands regardless of how the build is wired.

## Intel NPU driver

- **Project:** [intel/linux-npu-driver](https://github.com/intel/linux-npu-driver)
- **License:** MIT, © Intel Corporation.
- Downloaded as a prebuilt release tarball during the image build (see `scripts/build.sh` for the pinned version).

## Intel media driver (iHD) and gmmlib

- **Projects:** [intel/media-driver](https://github.com/intel/media-driver), [intel/gmmlib](https://github.com/intel/gmmlib)
- Compiled from source during the image build (see `docker/main/build_intel_media_driver.sh` in the Frigate tree, and the version pins in `scripts/build.sh`).

---

If you hold rights to any of the above and have concerns about this build, please open an issue on this repo.
