package api

import (
	"strings"
	"testing"

	"github.com/emdzej/airlock/internal/devices"
	"github.com/emdzej/airlock/internal/flash"
)

func TestDumpFilename(t *testing.T) {
	d := devices.Device{Name: "sda", Vendor: "Kingston", Model: "DataTraveler 2.0",
		Partitions: []devices.Partition{{Name: "sda1", Label: "My Photos/2024"}}}
	got := dumpFilename(d, flash.CompressionXZ)
	if !strings.HasPrefix(got, "airlock-my-photos2024-") || !strings.HasSuffix(got, ".img.xz") {
		t.Errorf("unexpected name %q", got)
	}
	d.Partitions = nil
	if got := dumpFilename(d, flash.CompressionNone); !strings.HasPrefix(got, "airlock-kingston-datatraveler-2.0-") || !strings.HasSuffix(got, ".img") {
		t.Errorf("unexpected fallback name %q", got)
	}
	if got := dumpFilename(devices.Device{Name: "sdb"}, flash.CompressionGZ); !strings.HasPrefix(got, "airlock-sdb-") {
		t.Errorf("unexpected kernel-name fallback %q", got)
	}
}
