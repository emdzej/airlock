#!/usr/bin/env bash
#
# Build the Airlock image using upstream pi-gen.
#
# Requirements (Linux host, or macOS with Docker Desktop):
#   - docker (pi-gen builds inside a container)
#   - git, go (to cross-compile airlockd)
#   - an arm64 host is strongly preferred; on x86_64, pi-gen needs
#     qemu-user-binfmt and its emulated build is not reliable
#
# Usage:
#   ./image/pi-gen/build.sh
#
# Output: image/pi-gen/.pi-gen/deploy/image_<date>-airlock.img.xz

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE_DIR="${REPO_ROOT}/image/pi-gen"
PIGEN_DIR="${IMAGE_DIR}/.pi-gen"
# pi-gen's `master` branch builds 32-bit (armhf) images regardless of
# ARCH= in config; 64-bit images come from the `arm64` branch. Pin to a
# release tag on that branch so builds are reproducible — bump it when
# Raspberry Pi publishes a new trixie arm64 release.
PIGEN_REF="${PIGEN_REF:-2026-09-15-raspios-trixie-arm64}"

# Marker recording which ref the checkout is on, so bumping PIGEN_REF
# (or overriding it) moves an existing .pi-gen clone instead of silently
# building from the old one.
PIGEN_MARKER="${PIGEN_DIR}/.airlock-pigen-ref"
if [ ! -d "${PIGEN_DIR}" ]; then
    echo ">>> Cloning pi-gen (${PIGEN_REF}) into ${PIGEN_DIR}"
    git clone --depth 1 --branch "${PIGEN_REF}" https://github.com/RPi-Distro/pi-gen "${PIGEN_DIR}"
    echo "${PIGEN_REF}" > "${PIGEN_MARKER}"
elif [ "$(cat "${PIGEN_MARKER}" 2>/dev/null)" != "${PIGEN_REF}" ]; then
    echo ">>> Moving pi-gen checkout to ${PIGEN_REF}"
    git -C "${PIGEN_DIR}" fetch --depth 1 origin "${PIGEN_REF}"
    git -C "${PIGEN_DIR}" checkout -q --force FETCH_HEAD
    echo "${PIGEN_REF}" > "${PIGEN_MARKER}"
fi

# Always rebuild the airlockd arm64 binary — the stage copies it in, and
# a stale bin/airlockd.arm64 from an earlier checkout would silently
# ship old code. `go build` is incremental, so this is cheap. Set
# VERSION=<tag> to stamp a release version (the Makefile default is
# `git describe`).
echo ">>> Building airlockd (arm64)"
(cd "${REPO_ROOT}" && make airlockd-arm64)

# Copy our stage into pi-gen's tree. pi-gen expects stages at its top level.
STAGE_SRC="${IMAGE_DIR}/stage-airlock"
STAGE_DST="${PIGEN_DIR}/stage-airlock"
echo ">>> Syncing custom stage → ${STAGE_DST}"
rm -rf "${STAGE_DST}"
cp -a "${STAGE_SRC}" "${STAGE_DST}"

# Stage the freshly-built binary into the stage's files/ tree.
# Portable across GNU (Linux) and BSD (macOS) install: mkdir + cp
# rather than `install -D`, which macOS's BSD install lacks.
STAGE_BIN_DIR="${STAGE_DST}/01-airlockd/files/usr/local/bin"
mkdir -p "${STAGE_BIN_DIR}"
cp "${REPO_ROOT}/bin/airlockd.arm64" "${STAGE_BIN_DIR}/airlockd"
chmod 0755 "${STAGE_BIN_DIR}/airlockd"

# Copy the pi-gen config in.
cp "${IMAGE_DIR}/config" "${PIGEN_DIR}/config"

# Skip desktop stages by touching SKIP / SKIP_IMAGES.
for s in stage3 stage4 stage5; do
    touch "${PIGEN_DIR}/${s}/SKIP" "${PIGEN_DIR}/${s}/SKIP_IMAGES"
done
# stage2 still has to run (stage-airlock builds on its rootfs), but it
# carries its own EXPORT_IMAGE — without SKIP_IMAGES pi-gen would also
# export a plain `-lite` image next to ours.
touch "${PIGEN_DIR}/stage2/SKIP_IMAGES"

# Build. Remove any leftover work container from a previous failed run —
# pi-gen refuses to start if `pigen_work` already exists and we didn't
# ask it to CONTINUE. Ignore errors; the common case is "no such container".
docker rm -v pigen_work >/dev/null 2>&1 || true

cd "${PIGEN_DIR}"
echo ">>> Running pi-gen build (this takes ~30 minutes)"
./build-docker.sh

echo
echo ">>> Image ready in: ${PIGEN_DIR}/deploy/"
ls -lh "${PIGEN_DIR}/deploy/"
