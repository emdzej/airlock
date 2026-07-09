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
PIGEN_REF="${PIGEN_REF:-arm64}"    # pi-gen branch; 'arm64' produces 64-bit images

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
install -D -m 0755 "${REPO_ROOT}/bin/airlockd.arm64" \
    "${STAGE_DST}/01-airlockd/files/usr/local/bin/airlockd"

# Copy the pi-gen config in.
cp "${IMAGE_DIR}/config" "${PIGEN_DIR}/config"

# Skip desktop stages by touching SKIP / SKIP_IMAGES.
for s in stage3 stage4 stage5; do
    touch "${PIGEN_DIR}/${s}/SKIP" "${PIGEN_DIR}/${s}/SKIP_IMAGES"
done

# Build.
cd "${PIGEN_DIR}"
echo ">>> Running pi-gen build (this takes ~30 minutes)"
./build-docker.sh

echo
echo ">>> Image ready in: ${PIGEN_DIR}/deploy/"
ls -lh "${PIGEN_DIR}/deploy/"
