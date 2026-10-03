# frigate-panther-lake

Unofficial build of Frigate with Intel Panther Lake NPU support: clones upstream Frigate at each release, applies an NPU driver patch, and publishes a multi-arch image to Docker Hub.

## Releasing

Releases are cut by the code session only: bump `VERSION` in a reviewed PR
and merge it; the release workflow does the rest. Changes reach `main` only
through pull requests.
