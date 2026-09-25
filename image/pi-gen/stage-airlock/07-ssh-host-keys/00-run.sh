#!/bin/bash -e
# Persist SSH host keys across reboots on the read-only (tmpfs overlay)
# root. See files/usr/local/sbin/airlock-ssh-host-keys for the details.

install -D -m 0755 files/usr/local/sbin/airlock-ssh-host-keys \
    "${ROOTFS_DIR}/usr/local/sbin/airlock-ssh-host-keys"

install -D -m 0644 files/etc/systemd/system/airlock-ssh-host-keys.service \
    "${ROOTFS_DIR}/etc/systemd/system/airlock-ssh-host-keys.service"

# Key-only SSH by default. Done here rather than via pi-gen's
# PUBKEY_ONLY_SSH, which refuses to build without a baked-in key.
install -D -m 0644 files/etc/ssh/sshd_config.d/60-airlock-pubkey-only.conf \
    "${ROOTFS_DIR}/etc/ssh/sshd_config.d/60-airlock-pubkey-only.conf"

on_chroot << EOF
systemctl enable airlock-ssh-host-keys.service
EOF
