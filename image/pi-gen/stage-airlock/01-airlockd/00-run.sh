#!/bin/bash -e
# Stage the airlockd binary and its systemd unit into the rootfs.
# The binary itself is placed under files/usr/local/bin/airlockd by build.sh
# before pi-gen is invoked.

install -D -m 0755 files/usr/local/bin/airlockd \
    "${ROOTFS_DIR}/usr/local/bin/airlockd"

install -D -m 0644 files/etc/systemd/system/airlockd.service \
    "${ROOTFS_DIR}/etc/systemd/system/airlockd.service"

# Enable the service on boot. smartmontools is installed for smartctl
# (SMART health on the Devices page); its smartd monitor stays off so it
# doesn't poll, and wake, every drive plugged in.
on_chroot << EOF
systemctl enable airlockd.service
systemctl disable smartmontools.service >/dev/null 2>&1 || true
EOF
