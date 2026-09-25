package mount

import (
	"errors"
	"strings"
	"testing"
)

func newTestManager(t *testing.T) *Manager {
	t.Helper()
	m, err := NewManager(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func TestSanitizeName(t *testing.T) {
	cases := map[string]string{
		"KINGSTON":              "kingston",
		"  My Photos!  ":        "my-photos",
		"--.weird._":            "weird",
		"Zdjęcia 2024":          "zdj-cia-2024",
		strings.Repeat("a", 40): strings.Repeat("a", 32),
		"":                      "",
	}
	for in, want := range cases {
		if got := sanitizeName(in); got != want {
			t.Errorf("sanitizeName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestReserveName(t *testing.T) {
	m := newTestManager(t)
	if got := m.reserveName("GLOBAL", "sda1"); got != "global-sda1" {
		t.Errorf("reserved label: got %q", got)
	}
	if got := m.reserveName("", "sdb1"); got != "sdb1" {
		t.Errorf("empty label: got %q", got)
	}
	m.drives["sdc1"] = &Drive{Kernel: "sdc1", ShareName: "stick"}
	if got := m.reserveName("Stick", "sdd1"); got != "stick-2" {
		t.Errorf("collision: got %q", got)
	}
}

func TestMountOptions(t *testing.T) {
	for _, fs := range []string{"vfat", "exfat", "ntfs3", "ext4", "hfsplus", "iso9660"} {
		opts := mountOptions(fs, false)
		for _, must := range []string{"nosuid", "nodev", "noexec"} {
			if !strings.Contains(opts, must) {
				t.Errorf("%s: missing %s in %q", fs, must, opts)
			}
		}
	}
	for _, fs := range []string{"hfsplus", "iso9660", "udf"} {
		if !strings.Contains(mountOptions(fs, false), ",ro") {
			t.Errorf("%s must always mount read-only", fs)
		}
	}
	if strings.Count(mountOptions("hfsplus", true), "ro,") > 1 {
		t.Errorf("hfsplus ro duplicated: %q", mountOptions("hfsplus", true))
	}
}

func TestIsSupported(t *testing.T) {
	for _, fs := range []string{"vfat", "fat32", "ntfs", "ntfs3", "exfat", "ext4"} {
		if !IsSupported(fs) {
			t.Errorf("IsSupported(%q) = false", fs)
		}
	}
	for _, fs := range []string{"", "btrfs", "swap", "crypto_LUKS"} {
		if IsSupported(fs) {
			t.Errorf("IsSupported(%q) = true", fs)
		}
	}
}

func TestBeginOp(t *testing.T) {
	m := newTestManager(t)
	release, err := m.BeginOp("sda", "format")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.BeginOp("sda", "flash"); !errors.Is(err, ErrBusy) {
		t.Errorf("second op: expected ErrBusy, got %v", err)
	}
	if !m.isQuarantinedLocked("sda") {
		t.Error("disk should be quarantined while op held")
	}
	other, err := m.BeginOp("sdb", "dump")
	if err != nil {
		t.Errorf("op on another disk should succeed: %v", err)
	}
	other()
	release()
	release() // idempotent
	if m.isQuarantinedLocked("sda") {
		t.Error("quarantine not lifted")
	}
	r2, err := m.BeginOp("sda", "flash")
	if err != nil {
		t.Errorf("op after release: %v", err)
	}
	r2()
}

func TestNotify_OrderAndEjectingSkip(t *testing.T) {
	var got []int
	m, err := NewManager(t.TempDir(), func(s Snapshot) { got = append(got, len(s.Drives)) })
	if err != nil {
		t.Fatal(err)
	}
	m.drives["sda1"] = &Drive{Kernel: "sda1"}
	m.notify()
	delete(m.drives, "sda1")
	m.notify()
	if len(got) != 2 || got[0] != 1 || got[1] != 0 {
		t.Errorf("notify sequence = %v", got)
	}
}
