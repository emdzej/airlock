#!/bin/bash -e
# Stage the airlockd binary and its systemd unit into the rootfs.
# The binary itself is placed under files/usr/local/bin/airlockd by build.sh
# before pi-gen is invoked.

install -D -m 0755 files/usr/local/bin/airlockd \
    "${ROOTFS_DIR}/usr/local/bin/airlockd"

install -D -m 0644 files/etc/systemd/system/airlockd.service \
    "${ROOTFS_DIR}/etc/systemd/system/airlockd.service"

# Enable the service on boot.
on_chroot << EOF
systemctl enable airlockd.service
EOF
