package mount

import (
	"slices"
	"testing"
)

func TestCheckMedia(t *testing.T) {
	m := newTestManager(t)
	sizes := map[string]int64{"sda": 64 << 30, "sdb": 0}
	m.deviceSize = func(k string) int64 { return sizes[k] }
	m.drives["sda1"] = &Drive{Kernel: "sda1", Parent: "sda"}
	m.drives["sdb1"] = &Drive{Kernel: "sdb1", Parent: "sdb"}
	m.drives["sdb2"] = &Drive{Kernel: "sdb2", Parent: "sdb"}
	m.drives["sdc"] = &Drive{Kernel: "sdc"} // superfloppy: fs on the whole disk

	// One zero read isn't enough.
	if got := m.checkMedia(); len(got) != 0 {
		t.Fatalf("first check: got %v, want none", got)
	}
	// sdc has no size entry either: it's gone too, from the second check.
	got := m.checkMedia()
	slices.Sort(got)
	if want := []string{"sdb", "sdc"}; !slices.Equal(got, want) {
		t.Fatalf("second check: got %v, want %v", got, want)
	}

	// A medium that comes back between checks resets the count.
	sizes["sdc"] = 8 << 30
	m.checkMedia()
	sizes["sdc"] = 0
	if got := m.checkMedia(); slices.Contains(got, "sdc") {
		t.Fatalf("sdc reported after one zero read since it came back: %v", got)
	}

	// Disks without drives any more are forgotten.
	delete(m.drives, "sdb1")
	delete(m.drives, "sdb2")
	m.checkMedia()
	if _, ok := m.noMedium["sdb"]; ok {
		t.Fatal("noMedium still tracks sdb after its drives went")
	}
}
