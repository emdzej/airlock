package api

import (
	"context"
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

	dev, part, err := devices.FindPartition(partition)
	if err != nil {
		writeJSON(w, lookupStatus(err), map[string]string{"error": err.Error()})
		return
	}
	fsType := part.FSType
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
	if mode == fsck.ModeRepair && dev.ReadOnly {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "device is read-only"})
		return
	}

	release, ok := s.beginOp(w, dev.Name, "fsck")
	if !ok {
		return
	}
	defer release()

	streamOp(s, w, func(emit func(fsck.Event)) error {
		// Background context: an fsck that has started should be allowed
		// to finish even if the client disconnects — interrupting mid-run
		// can leave the FS in a worse state.
		err := s.fsck.Check(context.Background(), fsck.Request{
			Partition: partition,
			FSType:    fsType,
			Mode:      mode,
			Release:   release,
		}, emit)
		if err != nil {
			slog.Error("fsck failed", "partition", partition, "err", err)
		}
		return err
	}, func(err error) fsck.Event {
		return fsck.Event{Stage: "error", Message: err.Error()}
	})
}
