//go:build linux

package mount

import (
	"encoding/binary"
	"testing"
)

func TestParseUEvent_Libudev(t *testing.T) {
	props := "ACTION=add\x00DEVPATH=/devices/platform/usb/block/sda/sda1\x00SUBSYSTEM=block\x00DEVTYPE=partition\x00DEVNAME=/dev/sda1\x00ID_FS_TYPE=vfat\x00AIRLOCK_MANAGED=1\x00"
	hdr := make([]byte, 40)
	copy(hdr, "libudev\x00")
	binary.LittleEndian.PutUint32(hdr[16:20], 40)
	ev, ok := parseUEvent(append(hdr, props...))
	if !ok {
		t.Fatal("parse failed")
	}
	if ev.Action != ActionAdd || ev.KernelName != "sda1" || ev.DevNode() != "/dev/sda1" || !ev.IsAirlockManaged() {
		t.Errorf("unexpected event: %+v", ev)
	}
}

func TestParseUEvent_Kernel(t *testing.T) {
	msg := "remove@/devices/x/block/sdb\x00ACTION=remove\x00DEVPATH=/devices/x/block/sdb\x00SUBSYSTEM=block\x00"
	ev, ok := parseUEvent([]byte(msg))
	if !ok || ev.Action != ActionRemove || ev.KernelName != "sdb" {
		t.Errorf("unexpected: ok=%v %+v", ok, ev)
	}
	if _, ok := parseUEvent([]byte("garbage-without-nul")); ok {
		t.Error("expected parse failure")
	}
}
