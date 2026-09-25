#!/bin/bash -e

install -D -m 0644 files/etc/overlayroot.conf \
    "${ROOTFS_DIR}/etc/overlayroot.conf"

# No update-initramfs here: pi-gen's export-image stage runs
# `update-initramfs -k all -c` in the final rootfs, which picks up
# overlayroot's initramfs hooks installed by 00-install-packages.
