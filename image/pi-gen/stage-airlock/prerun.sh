#!/bin/bash -e
# Bootstrap this stage from the previous stage's rootfs.
if [ ! -d "${ROOTFS_DIR}" ]; then
    copy_previous
fi
