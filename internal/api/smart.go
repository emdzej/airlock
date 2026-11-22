package api

import (
	"context"
	"log/slog"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/emdzej/airlock/internal/devices"
	"github.com/emdzej/airlock/internal/smart"
)

// smartTTL is how long a SMART reading is reused. Health moves slowly, and
// every read is a round trip through a USB bridge that may be mid-transfer.
const smartTTL = 5 * time.Minute

// smartCache holds the latest SMART reading per disk and runs at most one
// smartctl per disk at a time. Entries are tied to the medium's identity
// (serial + size), so a swapped drive on the same /dev name isn't shown
// the previous one's health.
//
// Background probes (from the device list) never wake a sleeping drive,
// and finding it asleep doesn't replace a real reading. A client asking
// for the reading itself (opening the drive's health) is on demand: that
// wakes the drive.
type smartCache struct {
	query func(ctx context.Context, path string, wake bool) smart.Report
	busy  func(disk string) (op string, running bool)

	mu      sync.Mutex
	entries map[string]*smartEntry // key: kernel name
}

type smartEntry struct {
	identity  string
	report    *smart.Report // nil until the first probe finishes
	attempted time.Time     // when the last probe started, woken or not
	running   chan struct{} // non-nil while a probe runs; closed when it ends
	waking    bool          // the running probe wakes the drive
}

func newSmartCache(busy func(string) (string, bool)) *smartCache {
	return &smartCache{query: smart.Query, busy: busy, entries: make(map[string]*smartEntry)}
}

func smartIdentity(d devices.Device) string {
	return d.Serial + "/" + d.Model + "/" + strconv.FormatInt(d.SizeBytes, 10)
}

// entryLocked returns the entry for d, replacing one for a different medium.
func (c *smartCache) entryLocked(d devices.Device) *smartEntry {
	e := c.entries[d.Name]
	if e == nil || e.identity != smartIdentity(d) {
		e = &smartEntry{identity: smartIdentity(d)}
		c.entries[d.Name] = e
	}
	return e
}

// startLocked launches a probe for d unless one is running, and returns
// the channel that closes when the running probe finishes.
func (c *smartCache) startLocked(d devices.Device, e *smartEntry, wake bool) chan struct{} {
	if e.running != nil {
		return e.running
	}
	done := make(chan struct{})
	e.running, e.waking, e.attempted = done, wake, time.Now()
	go func() {
		r := c.query(context.Background(), d.Path, wake)
		if r.Status == smart.StatusFailing || r.Status == smart.StatusWarning {
			slog.Warn("smart", "disk", d.Name, "status", r.Status, "summary", r.Summary)
		}
		c.mu.Lock()
		if r.Status != smart.StatusStandby || !hasData(e.report) {
			e.report = &r
		}
		e.running = nil
		c.mu.Unlock()
		close(done)
	}()
	return done
}

// hasData reports whether r is a reading worth keeping over "asleep".
func hasData(r *smart.Report) bool { return r != nil && r.Status != smart.StatusStandby }

func fresh(r *smart.Report) bool { return hasData(r) && time.Since(r.CheckedAt) < smartTTL }

// peek returns d's cached status without waiting, and starts a background
// probe (one that doesn't wake the drive) if the last one is smartTTL
// old. Empty slots and disks under a format / flash / dump aren't probed.
func (c *smartCache) peek(d devices.Device) smart.Status {
	if d.SizeBytes == 0 || d.Optical {
		return ""
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	e := c.entryLocked(d)
	if _, running := c.busy(d.Name); !running && time.Since(e.attempted) >= smartTTL {
		c.startLocked(d, e, false)
	}
	if e.report == nil {
		return ""
	}
	return e.report.Status
}

// get returns a reading for d, waking the drive and waiting for a probe
// if the cached reading is missing, stale, "asleep", or force is set.
// While an operation holds the disk the last reading is returned as is;
// ok is false if there is none.
func (c *smartCache) get(ctx context.Context, d devices.Device, force bool) (r smart.Report, op string, ok bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e := c.entryLocked(d)
	if op, running := c.busy(d.Name); running {
		if e.report == nil {
			return smart.Report{}, op, false
		}
		return *e.report, op, true
	}
	if !force && fresh(e.report) {
		return *e.report, "", true
	}
	for {
		done := c.startLocked(d, e, true)
		waking := e.waking
		c.mu.Unlock()
		select {
		case <-done:
			c.mu.Lock()
		case <-ctx.Done():
			c.mu.Lock()
			return smart.Report{}, "", false
		}
		// A background probe was already running: use what it read
		// unless it found the drive asleep, then wake it.
		if waking || fresh(e.report) {
			return *e.report, "", true
		}
	}
}

// prune drops entries for disks that are gone.
func (c *smartCache) prune(present []devices.Device) {
	keep := make(map[string]bool, len(present))
	for _, d := range present {
		keep[d.Name] = true
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	for name, e := range c.entries {
		if !keep[name] && e.running == nil {
			delete(c.entries, name)
		}
	}
}

// GET /api/devices/{parent}/smart[?refresh=1]
// The device's SMART reading (smart.Report), waking the drive if it's
// asleep. Cached for smartTTL; refresh forces a new smartctl run. 409 while a whole-disk operation holds the
// device and nothing was read before it started.
func (s *Server) handleSmart(w http.ResponseWriter, r *http.Request) {
	d, err := devices.Get(r.PathValue("parent"))
	if err != nil {
		writeJSON(w, lookupStatus(err), map[string]string{"error": err.Error()})
		return
	}
	if d.Optical {
		writeJSON(w, http.StatusOK, smart.Report{
			Status: smart.StatusUnsupported, Summary: "Optical drives don't report SMART health.", CheckedAt: time.Now(),
		})
		return
	}
	if d.SizeBytes == 0 {
		writeJSON(w, http.StatusOK, smart.Report{
			Status: smart.StatusUnsupported, Summary: "No medium in the slot.", CheckedAt: time.Now(),
		})
		return
	}
	report, op, ok := s.smart.get(r.Context(), d, r.URL.Query().Get("refresh") == "1")
	if !ok {
		if op != "" {
			writeJSON(w, http.StatusConflict, map[string]string{"error": op + " in progress on " + d.Name})
		}
		return // client gone
	}
	writeJSON(w, http.StatusOK, report)
}
