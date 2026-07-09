package api

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/emdzej/airlock/internal/devices"
	"github.com/emdzej/airlock/internal/fsck"
)

// POST /api/partitions/{name}/fsck?mode=check|repair
// Response: text/event-stream with `data: {"stage","message","exit_code"}`
// events. Terminal event is stage=done or stage=error.
func (s *Server) handleFsck(w http.ResponseWriter, r *http.Request) {
	partition := r.PathValue("name")

	// Look up the partition to get the parent + fs type.
	all, err := devices.List()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	var (
		parent string
		fsType string
		found  bool
		roDev  bool
	)
	for _, d := range all {
		for _, p := range d.Partitions {
			if p.Name == partition {
				parent = d.Name
				fsType = p.FSType
				roDev = d.ReadOnly
				found = true
				break
			}
		}
		if found {
			break
		}
	}
	if !found {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "partition not found"})
		return
	}
	if !fsck.SupportedForFS(fsType) {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "filesystem " + fsType + " not supported for fsck",
		})
		return
	}

	mode := fsck.Mode(r.URL.Query().Get("mode"))
	if mode == "" {
		mode = fsck.ModeCheck
	}
	if !mode.Valid() {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid mode"})
		return
	}
	if mode == fsck.ModeRepair && roDev {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "device is read-only"})
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	flusher, _ := w.(http.Flusher)

	s.onBusy(true)
	defer s.onBusy(false)

	events := make(chan fsck.Event, 128)
	go func() {
		defer close(events)
		// Background context: an fsck that has started should be allowed
		// to finish even if the client disconnects — interrupting mid-run
		// can leave the FS in a worse state.
		err := s.fsck.Check(context.Background(), fsck.Request{
			Partition: partition,
			Parent:    parent,
			FSType:    fsType,
			Mode:      mode,
		}, func(ev fsck.Event) {
			select {
			case events <- ev:
			default:
			}
		})
		if err != nil {
			slog.Error("fsck failed", "partition", partition, "err", err)
			select {
			case events <- fsck.Event{Stage: "error", Message: err.Error()}:
			default:
			}
		}
	}()

	for ev := range events {
		data, _ := json.Marshal(ev)
		if _, err := fmt.Fprintf(w, "data: %s\n\n", data); err != nil {
			go func() {
				for range events {
				}
			}()
			return
		}
		if flusher != nil {
			flusher.Flush()
		}
	}
}
