#!/usr/bin/env bash
#
# Build the Airlock image using upstream pi-gen.
#
# Requirements (Linux host):
#   - docker (pi-gen builds inside a container)
#   - git
#
# Usage:
#   ./image/pi-gen/build.sh
#
# Output: pi-gen/deploy/<IMG_NAME>.img.xz

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE_DIR="${REPO_ROOT}/image/pi-gen"
PIGEN_DIR="${IMAGE_DIR}/.pi-gen"
PIGEN_REF="${PIGEN_REF:-master}"   # master supports arm64 via ARCH= in config

if [ ! -d "${PIGEN_DIR}" ]; then
    echo ">>> Cloning pi-gen (${PIGEN_REF}) into ${PIGEN_DIR}"
    git clone --depth 1 --branch "${PIGEN_REF}" https://github.com/RPi-Distro/pi-gen "${PIGEN_DIR}"
fi

# Ensure the airlockd arm64 binary exists — the stage copies it in.
if [ ! -f "${REPO_ROOT}/bin/airlockd.arm64" ]; then
    echo ">>> Building airlockd (arm64)"
    (cd "${REPO_ROOT}" && make airlockd-arm64)
fi

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

# Build. Remove any leftover work container from a previous failed run —
# pi-gen refuses to start if `pigen_work` already exists and we didn't
# ask it to CONTINUE. Ignore errors; the common case is "no such container".
docker rm -v pigen_work >/dev/null 2>&1 || true

# On arm64 hosts (Apple Silicon, arm64 Linux) pi-gen's `setarch linux32`
# in stage0 fails — the arm64 kernel can't set the 32-bit personality
# needed. Force the pi-gen container to run as amd64, which Docker
# emulates via QEMU on Apple Silicon. Slower but reliably functional.
if [ "$(uname -m)" = "arm64" ] || [ "$(uname -m)" = "aarch64" ]; then
    export DOCKER_DEFAULT_PLATFORM=linux/amd64
    echo ">>> arm64 host detected — forcing pigen container to linux/amd64"
fi

cd "${PIGEN_DIR}"
echo ">>> Running pi-gen build (this takes ~30 minutes)"
./build-docker.sh

echo
echo ">>> Image ready in: ${PIGEN_DIR}/deploy/"
ls -lh "${PIGEN_DIR}/deploy/"
