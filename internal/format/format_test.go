package format

import (
	"reflect"
	"testing"
)

func TestMkfsCommand(t *testing.T) {
	cases := []struct {
		fs    Filesystem
		label string
		cmd   string
		args  []string
	}{
		{FAT32, "photos 2024!", "mkfs.vfat", []string{"-F", "32", "-n", "PHOTOS 2024", "/dev/sda1"}},
		{EXFAT, "", "mkfs.exfat", []string{"/dev/sda1"}},
		{NTFS, "Backup", "mkfs.ntfs", []string{"-f", "-Q", "-L", "Backup", "/dev/sda1"}},
		{EXT4, "zdjęcia-wakacje-2024", "mkfs.ext4", []string{"-F", "-L", "zdjęcia-wakacje", "/dev/sda1"}},
	}
	for _, tc := range cases {
		cmd, args := mkfsCommand(tc.fs, tc.label, "/dev/sda1")
		if cmd != tc.cmd || !reflect.DeepEqual(args, tc.args) {
			t.Errorf("%s: got %s %v, want %s %v", tc.fs, cmd, args, tc.cmd, tc.args)
		}
	}
}

func TestPartitionPath(t *testing.T) {
	if got := partitionPath("sda", 1); got != "/dev/sda1" {
		t.Errorf("sda: %s", got)
	}
	if got := partitionPath("mmcblk0", 1); got != "/dev/mmcblk0p1" {
		t.Errorf("mmcblk0: %s", got)
	}
}
