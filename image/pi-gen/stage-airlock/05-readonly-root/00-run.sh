#!/bin/bash -e

install -D -m 0644 files/etc/overlayroot.conf \
    "${ROOTFS_DIR}/etc/overlayroot.conf"

# Rebuild the initramfs so overlayroot's hooks are picked up. This must
# happen inside the chroot because it needs to see the installed kernel.
on_chroot << EOF
update-initramfs -u -k all
EOF
