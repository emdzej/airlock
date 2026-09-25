package samba

import (
	"strings"
	"testing"

	"github.com/emdzej/airlock/internal/mount"
)

func TestRender(t *testing.T) {
	snap := mount.Snapshot{Drives: []mount.Drive{
		{Kernel: "sdb1", ShareName: "zeta", MountPoint: "/mnt/airlock/zeta", FSType: "exfat"},
		{Kernel: "sda1", ShareName: "alpha", Label: "ALPHA", MountPoint: "/mnt/airlock/alpha", FSType: "vfat", ReadOnly: true},
		{Kernel: "sdc1", ShareName: "going", MountPoint: "/mnt/airlock/going", FSType: "vfat", Ejecting: true},
	}}
	out := Render(snap, Owner{User: "airlock", Group: "airlock"})
	if a, z := strings.Index(out, "[alpha]"), strings.Index(out, "[zeta]"); a < 0 || z < 0 || a > z {
		t.Errorf("shares missing or unsorted:\n%s", out)
	}
	if strings.Contains(out, "[going]") {
		t.Error("ejecting drive must be withdrawn from the config")
	}
	if !strings.Contains(out, "comment = ALPHA (vfat, read-only)") || !strings.Contains(out, "read only = yes") {
		t.Errorf("read-only share rendered wrong:\n%s", out)
	}
	if !strings.Contains(out, "force user = airlock") {
		t.Error("missing force user")
	}
}
