#!/bin/bash -e
#
# Bake the fast-boot service disables + BT firmware skip into the image.
# Mirrors what `AIRLOCK_FAST_BOOT=1 ./install.sh` does on a running Pi,
# but applied at image-build time so a fresh flash boots in ~14 s
# instead of ~24 s.
#
# Wi-Fi is left ENABLED here — the image needs to be flashable on
# Wi-Fi-only setups. Users on Ethernet can add `dtoverlay=disable-wifi`
# to /boot/firmware/config.txt post-flash for another ~0.5 s.

on_chroot << 'EOF'
# Services safe to disable on a headless airlock appliance. Failures
# ignored — some names differ across pi-gen releases or aren't
# installed at all.
for svc in bluetooth.service hciuart.service \
           triggerhappy.service triggerhappy.socket \
           ModemManager.service \
           nmbd.service samba-ad-dc.service winbind.service \
           apt-daily.timer apt-daily-upgrade.timer \
           e2scrub_reap.service e2scrub_all.timer \
           dphys-swapfile.service \
           NetworkManager-wait-online.service \
           rpi-eeprom-update.service; do
    systemctl disable "$svc" >/dev/null 2>&1 || true
done

# Console / keyboard setup would run every boot even on a headless box.
# Mask so systemd doesn't consider them at all.
for svc in keyboard-setup.service console-setup.service; do
    systemctl mask "$svc" >/dev/null 2>&1 || true
done

# pi-gen doesn't include cloud-init, but if a downstream stage adds it
# later, this marker prevents it from running on every boot.
if [ -d /etc/cloud ]; then
    touch /etc/cloud/cloud-init.disabled
fi
EOF

# Firmware overlay to skip Bluetooth radio init (~1 s off kernel time).
# Path is /boot/firmware/config.txt on Bookworm+ pi-gen builds.
CONFIG_TXT="${ROOTFS_DIR}/boot/firmware/config.txt"
if [ -f "$CONFIG_TXT" ] && ! grep -q "^dtoverlay=disable-bt" "$CONFIG_TXT"; then
    echo "" >> "$CONFIG_TXT"
    echo "# airlock: skip Bluetooth radio init at boot (from stage-airlock/06-fast-boot)" >> "$CONFIG_TXT"
    echo "dtoverlay=disable-bt" >> "$CONFIG_TXT"
fi
