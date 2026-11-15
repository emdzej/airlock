package api

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/emdzej/airlock/internal/devices"
	"github.com/emdzej/airlock/internal/smart"
)

func testSmartCache(busyOp string) (*smartCache, *atomic.Int32) {
	var calls atomic.Int32
	c := newSmartCache(func(string) (string, bool) { return busyOp, busyOp != "" })
	c.query = func(context.Context, string) smart.Report {
		calls.Add(1)
		return smart.Report{Status: smart.StatusPassed, CheckedAt: time.Now()}
	}
	return c, &calls
}

func waitStatus(t *testing.T, c *smartCache, d devices.Device, want smart.Status) {
	t.Helper()
	for i := 0; i < 100; i++ {
		if c.peek(d) == want {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("peek never returned %q", want)
}

func TestSmartCacheProbesOnceAndReuses(t *testing.T) {
	c, calls := testSmartCache("")
	d := devices.Device{Name: "sdc", Path: "/dev/sdc", Serial: "A", SizeBytes: 1}
	waitStatus(t, c, d, smart.StatusPassed)
	if _, _, ok := c.get(context.Background(), d, false); !ok || calls.Load() != 1 {
		t.Fatalf("ok=%v calls=%d", ok, calls.Load())
	}
	if _, _, _ = c.get(context.Background(), d, true); calls.Load() != 2 {
		t.Fatalf("force: calls=%d", calls.Load())
	}
	// A different medium on the same name starts over.
	d.Serial = "B"
	if c.peek(d) != "" {
		t.Fatal("swapped drive inherited the old reading")
	}
}

func TestSmartCacheSkipsEmptyAndBusy(t *testing.T) {
	c, calls := testSmartCache("format")
	if c.peek(devices.Device{Name: "sda"}) != "" {
		t.Fatal("empty slot probed")
	}
	d := devices.Device{Name: "sdc", Serial: "A", SizeBytes: 1}
	c.peek(d)
	if _, op, ok := c.get(context.Background(), d, true); ok || op != "format" {
		t.Fatalf("busy disk: ok=%v op=%q", ok, op)
	}
	time.Sleep(20 * time.Millisecond)
	if calls.Load() != 0 {
		t.Fatalf("busy disk probed %d times", calls.Load())
	}
}

func TestSmartCacheStale(t *testing.T) {
	c, calls := testSmartCache("")
	d := devices.Device{Name: "sdc", Serial: "A", SizeBytes: 1}
	c.get(context.Background(), d, false)
	c.mu.Lock()
	c.entries["sdc"].report.CheckedAt = time.Now().Add(-2 * smartTTL)
	c.mu.Unlock()
	c.get(context.Background(), d, false)
	if calls.Load() != 2 {
		t.Fatalf("stale reading reused: calls=%d", calls.Load())
	}
	c.prune(nil)
	if len(c.entries) != 0 {
		t.Fatal("prune kept a removed disk")
	}
}
