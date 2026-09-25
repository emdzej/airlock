package label

import (
	"errors"
	"testing"
)

func TestValidateLabel(t *testing.T) {
	ok := map[string]string{"vfat": "MY DISK", "exfat": "Zdjęcia", "ntfs": "Backup 2024", "ext4": "data"}
	for fs, l := range ok {
		if err := validateLabel(fs, l); err != nil {
			t.Errorf("validateLabel(%s, %q): %v", fs, l, err)
		}
	}
	bad := []struct{ fs, label string }{
		{"vfat", ""}, {"vfat", "TOO LONG LABEL"}, {"vfat", "BAD*CHAR"},
		{"ntfs", "--new-serial"}, {"ext4", "a/b"}, {"exfat", "0123456789abcdef"}, {"ext4", "zdjęcia-wakacje!"},
	}
	for _, tc := range bad {
		if err := validateLabel(tc.fs, tc.label); !errors.Is(err, ErrInvalidLabel) {
			t.Errorf("validateLabel(%s, %q) = %v, want ErrInvalidLabel", tc.fs, tc.label, err)
		}
	}
}

func TestLabelCommand(t *testing.T) {
	if cmd, args := labelCommand("vfat", "/dev/sda1", "disk"); cmd != "fatlabel" || args[1] != "DISK" {
		t.Errorf("vfat: %s %v", cmd, args)
	}
	if cmd, _ := labelCommand("hfsplus", "/dev/sda1", "x"); cmd != "" {
		t.Error("hfsplus should be unsupported")
	}
}
