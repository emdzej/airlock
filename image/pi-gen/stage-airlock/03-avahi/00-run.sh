#!/bin/bash -e

install -D -m 0644 files/etc/avahi/services/airlock.service \
    "${ROOTFS_DIR}/etc/avahi/services/airlock.service"

on_chroot << EOF
systemctl enable avahi-daemon.service
EOF
