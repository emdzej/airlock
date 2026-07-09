#!/bin/bash -e

# Base smb.conf — includes the dynamic file that airlockd manages.
install -D -m 0644 files/etc/samba/smb.conf \
    "${ROOTFS_DIR}/etc/samba/smb.conf"

# Dynamic share config, initially empty. airlockd rewrites this file
# whenever a drive is mounted or unmounted, then calls smbcontrol reload-config.
install -D -m 0644 /dev/null \
    "${ROOTFS_DIR}/etc/samba/smb.conf.d/airlock.conf"

on_chroot << EOF
systemctl enable smbd.service
# nmbd (NetBIOS) is not needed for SMB2/3 discovery on modern clients; disable it.
systemctl disable nmbd.service || true
systemctl mask nmbd.service || true
EOF
