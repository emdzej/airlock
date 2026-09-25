package fsck

import (
	"slices"
	"testing"
)

func TestFsckCommand(t *testing.T) {
	cases := []struct {
		fs       string
		mode     Mode
		tool     string
		mustHave string
	}{
		{"vfat", ModeCheck, "fsck.vfat", "-n"},
		{"vfat", ModeRepair, "fsck.vfat", "-a"},
		{"exfat", ModeCheck, "fsck.exfat", "-n"},
		{"ext4", ModeCheck, "e2fsck", "-n"},
		{"ext4", ModeRepair, "e2fsck", "-p"},
		{"ntfs", ModeCheck, "ntfsfix", "--no-action"},
		{"hfsplus", ModeCheck, "fsck.hfsplus", "-f"},
	}
	for _, tc := range cases {
		tool, args, _ := fsckCommand(tc.fs, tc.mode, "/dev/sda1")
		if tool != tc.tool || !slices.Contains(args, tc.mustHave) || args[len(args)-1] != "/dev/sda1" {
			t.Errorf("%s/%s: %s %v", tc.fs, tc.mode, tool, args)
		}
	}
	if SupportedForFS("btrfs") {
		t.Error("btrfs should be unsupported")
	}
}
