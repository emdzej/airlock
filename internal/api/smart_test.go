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
	c.query = func(context.Context, string, bool) smart.Report {
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

// An idle drive in standby: background probes leave it asleep and keep
// the last real reading; asking for the reading wakes it.
func TestSmartCacheStandby(t *testing.T) {
	var woken, quiet atomic.Int32
	c := newSmartCache(func(string) (string, bool) { return "", false })
	c.query = func(_ context.Context, _ string, wake bool) smart.Report {
		if wake {
			woken.Add(1)
			return smart.Report{Status: smart.StatusPassed, CheckedAt: time.Now()}
		}
		quiet.Add(1)
		return smart.Report{Status: smart.StatusStandby, CheckedAt: time.Now()}
	}
	d := devices.Device{Name: "sdc", Serial: "A", SizeBytes: 1}
	waitStatus(t, c, d, smart.StatusStandby)
	if r, _, _ := c.get(context.Background(), d, false); r.Status != smart.StatusPassed || woken.Load() != 1 {
		t.Fatalf("get: %q, woken %d", r.Status, woken.Load())
	}
	// Five minutes on, the background probe finds it asleep again.
	c.mu.Lock()
	e := c.entries["sdc"]
	e.attempted = time.Now().Add(-2 * smartTTL)
	e.report.CheckedAt = e.attempted
	c.mu.Unlock()
	c.peek(d)
	for i := 0; i < 100 && quiet.Load() < 2; i++ {
		time.Sleep(5 * time.Millisecond)
	}
	time.Sleep(10 * time.Millisecond)
	if st := c.peek(d); st != smart.StatusPassed {
		t.Fatalf("standby replaced the reading: %q", st)
	}
	if r, _, _ := c.get(context.Background(), d, false); r.Status != smart.StatusPassed || woken.Load() != 2 {
		t.Fatalf("stale get didn't wake: %q, woken %d", r.Status, woken.Load())
	}
}
