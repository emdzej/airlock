#!/bin/bash -e

install -D -m 0644 files/etc/udev/rules.d/99-airlock.rules \
    "${ROOTFS_DIR}/etc/udev/rules.d/99-airlock.rules"
