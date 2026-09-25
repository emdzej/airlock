package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"

	"github.com/emdzej/airlock/internal/devices"
	"github.com/emdzej/airlock/internal/mount"
)

// beginOp claims exclusive use of a disk for a long-running operation.
// On conflict it writes a 409 and returns ok=false. The returned release
// function is idempotent; pass it to the operation (which calls it before
// its final udev re-trigger) and also defer it.
func (s *Server) beginOp(w http.ResponseWriter, disk, op string) (release func(), ok bool) {
	release, err := s.mgr.BeginOp(disk, op)
	if err != nil {
		status := http.StatusInternalServerError
		if errors.Is(err, mount.ErrBusy) {
			status = http.StatusConflict
		}
		writeJSON(w, status, map[string]string{"error": err.Error()})
		return nil, false
	}
	return release, true
}

// requireWritableDevice refuses destructive whole-disk operations on
// write-protected media: either the disk itself is RO, or one of its
// mounted partitions is (possible for iso9660 hybrid layouts).
func (s *Server) requireWritableDevice(w http.ResponseWriter, dev devices.Device) bool {
	if dev.ReadOnly {
		writeJSON(w, http.StatusForbidden, map[string]string{
			"error": "device is read-only (write-protect switch?)",
		})
		return false
	}
	for _, mn := range s.mgr.Snapshot().Drives {
		if (mn.Kernel == dev.Name || mn.Parent == dev.Name) && mn.ReadOnly {
			writeJSON(w, http.StatusForbidden, map[string]string{
				"error": "at least one partition on this device is read-only",
			})
			return false
		}
	}
	return true
}

// streamOp runs op and relays its progress events to the client as
// Server-Sent Events (`data: <json>\n\n`). errEvent converts op's error
// into the terminal event.
//
// The handler does not return until op has finished — even if the client
// disconnects. That keeps the request body valid for operations that
// stream it (flash), keeps the busy LED honest, and lets graceful shutdown
// wait for destructive work instead of killing it mid-write. Events are
// never dropped: the only consumer is this loop, which always drains.
func streamOp[E any](s *Server, w http.ResponseWriter, run func(emit func(E)) error, errEvent func(error) E) {
	s.ops.Add(1)
	defer s.ops.Done()

	rc := http.NewResponseController(w)
	// Flash reads the upload while we write progress; without full duplex
	// net/http may discard the unread body once the response starts.
	_ = rc.EnableFullDuplex()

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	s.onBusy(true)
	defer s.onBusy(false)

	events := make(chan E, 64)
	go func() {
		defer close(events)
		if err := run(func(ev E) { events <- ev }); err != nil {
			events <- errEvent(err)
		}
	}()

	clientGone := false
	for ev := range events {
		if clientGone {
			continue // keep draining so the operation never blocks
		}
		data, _ := json.Marshal(ev)
		if _, err := fmt.Fprintf(w, "data: %s\n\n", data); err != nil {
			clientGone = true
			continue
		}
		if err := rc.Flush(); err != nil {
			clientGone = true
		}
	}
}
