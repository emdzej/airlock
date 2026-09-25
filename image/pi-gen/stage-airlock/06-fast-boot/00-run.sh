#!/bin/bash -e
#
# Bake the fast-boot service disables + BT firmware skip into the image.
# Mirrors what `AIRLOCK_FAST_BOOT=1 ./install.sh` does on a running Pi
# (minus the cloud-init disable, see below), but applied at image-build
# time so a fresh flash boots in well under the stock ~24 s.
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
EOF

# cloud-init is deliberately left ENABLED (unlike `AIRLOCK_FAST_BOOT=1`
# in install.sh, which runs on an already-provisioned Pi). On trixie,
# Raspberry Pi Imager's OS customisation — user, password, SSH key,
# Wi-Fi, hostname — is delivered as cloud-init user-data on the boot
# partition. With the tmpfs overlay root it re-applies on every boot,
# which is what keeps those settings in place. That costs ~2 s of boot.

# Firmware overlay to skip Bluetooth radio init (~1 s off kernel time).
# Path is /boot/firmware/config.txt on Bookworm+ pi-gen builds.
CONFIG_TXT="${ROOTFS_DIR}/boot/firmware/config.txt"
if [ -f "$CONFIG_TXT" ] && ! grep -q "^dtoverlay=disable-bt" "$CONFIG_TXT"; then
    {
        echo ""
        echo "# airlock: skip Bluetooth radio init at boot (from stage-airlock/06-fast-boot)"
        echo "dtoverlay=disable-bt"
    } >> "$CONFIG_TXT"
fi
