package smart

import (
	"os"
	"strings"
	"testing"
)

func parseFixture(t *testing.T, name string) Report {
	t.Helper()
	data, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	r, err := Parse(data)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// A healthy SandForce SSD behind a USB SAT bridge (smartctl 7.4, Pi).
func TestParseATAPassed(t *testing.T) {
	r := parseFixture(t, "ata_sat_ssd.json")
	if r.Status != StatusPassed || r.Protocol != "ATA" {
		t.Fatalf("status %q protocol %q: %v", r.Status, r.Protocol, r.Warnings)
	}
	if r.TemperatureC == nil || *r.TemperatureC != 26 {
		t.Errorf("temperature %v", r.TemperatureC)
	}
	if r.PowerOnHours == nil || *r.PowerOnHours != 58192 {
		t.Errorf("power-on hours %v", r.PowerOnHours)
	}
	// SSD_Life_Left = 93 → 7% used; id 177 here is Wear_Range_Delta and
	// must not be read as wear.
	if r.PercentageUsed == nil || *r.PercentageUsed != 7 {
		t.Errorf("percentage used %v", r.PercentageUsed)
	}
	if r.ReallocatedSectors == nil || *r.ReallocatedSectors != 0 {
		t.Errorf("reallocated %v", r.ReallocatedSectors)
	}
	if len(r.Attributes) == 0 || r.Attributes[0].Threshold == nil {
		t.Errorf("attributes %+v", r.Attributes)
	}
}

func TestParseATAFailing(t *testing.T) {
	r := parseFixture(t, "ata_failing.json")
	if r.Status != StatusFailing {
		t.Fatalf("status %q", r.Status)
	}
	joined := strings.Join(r.Warnings, "|")
	for _, want := range []string{"120 reallocated sectors", "8 sectors pending", "below its failure threshold"} {
		if !strings.Contains(joined, want) {
			t.Errorf("warnings %q lack %q", joined, want)
		}
	}
}

func TestParseNVMe(t *testing.T) {
	r := parseFixture(t, "nvme.json")
	if r.Status != StatusPassed || r.Protocol != "NVMe" {
		t.Fatalf("status %q protocol %q: %v", r.Status, r.Protocol, r.Warnings)
	}
	if r.PercentageUsed == nil || *r.PercentageUsed != 8 || r.AvailableSpare == nil || *r.AvailableSpare != 100 {
		t.Errorf("used %v spare %v", r.PercentageUsed, r.AvailableSpare)
	}
	if r.DataWrittenBytes == nil || *r.DataWrittenBytes != 353966798*nvmeDataUnit {
		t.Errorf("written %v", r.DataWrittenBytes)
	}
	if r.UnsafeShutdowns == nil || *r.UnsafeShutdowns != 17 {
		t.Errorf("unsafe shutdowns %v", r.UnsafeShutdowns)
	}
	if len(r.Attributes) != 15 {
		t.Errorf("%d NVMe rows", len(r.Attributes))
	}
}

func TestParseNVMeWorn(t *testing.T) {
	data, _ := os.ReadFile("testdata/nvme.json")
	data = []byte(strings.Replace(string(data), `"percentage_used": 8`, `"percentage_used": 97`, 1))
	r, err := Parse(data)
	if err != nil {
		t.Fatal(err)
	}
	if r.Status != StatusWarning || !strings.Contains(r.Summary, "97% of rated write endurance") {
		t.Fatalf("%q: %q", r.Status, r.Summary)
	}
}

// A Genesys SD card reader: smartctl doesn't know the bridge.
func TestParseUnknownBridge(t *testing.T) {
	r := parseFixture(t, "usb_unknown_bridge.json")
	if r.Status != StatusUnsupported || len(r.Messages) != 1 {
		t.Fatalf("%q %v", r.Status, r.Messages)
	}
}

func TestParseStandby(t *testing.T) {
	r, err := Parse([]byte(`{"smartctl":{"exit_status":2,"messages":[{"string":"Device is in STANDBY mode, exit(2)","severity":"information"}]},
		"device":{"protocol":"ATA"},"smart_support":{"available":true,"enabled":true}}`))
	if err != nil || r.Status != StatusStandby {
		t.Fatalf("%q %v", r.Status, err)
	}
}

func TestParseSMARTDisabled(t *testing.T) {
	r, _ := Parse([]byte(`{"smartctl":{"exit_status":4},"device":{"protocol":"ATA"},"smart_support":{"available":true,"enabled":false}}`))
	if r.Status != StatusUnsupported || !strings.Contains(r.Summary, "turned off") {
		t.Fatalf("%q %q", r.Status, r.Summary)
	}
}

func TestParseGarbage(t *testing.T) {
	if _, err := Parse([]byte("smartctl: not json")); err == nil {
		t.Fatal("want error")
	}
}
