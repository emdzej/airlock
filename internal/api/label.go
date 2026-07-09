package api

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"github.com/emdzej/airlock/internal/devices"
	"github.com/emdzej/airlock/internal/label"
)

// POST /api/partitions/{name}/label
// Body: {"label": "NEW_NAME"}
// Sets the volume label on a partition. Only certain filesystems are
// supported (see label.SupportedForFS).
func (s *Server) handleSetLabel(w http.ResponseWriter, r *http.Request) {
	partition := r.PathValue("name")

	// Look up the partition through the devices enumeration to find its
	// parent and current filesystem type.
	all, err := devices.List()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	var (
		parent string
		fsType string
		ro     bool
		found  bool
	)
	for _, d := range all {
		if d.Name == partition {
			// Whole-disk with a filesystem (superfloppy layout).
			parent = ""
			fsType = ""
			for _, p := range d.Partitions {
				_ = p
			}
			// A whole disk with an fs on itself isn't captured by the
			// devices/partitions split; skip and continue looking below.
		}
		for _, p := range d.Partitions {
			if p.Name == partition {
				parent = d.Name
				fsType = p.FSType
				ro = d.ReadOnly
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
	if ro {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "device is read-only"})
		return
	}
	if !label.SupportedForFS(fsType) {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "filesystem " + fsType + " does not support relabelling from Airlock",
		})
		return
	}

	var body struct {
		Label string `json:"label"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON body"})
		return
	}

	s.onBusy(true)
	defer s.onBusy(false)

	if err := label.Set(r.Context(), s.mgr, label.Request{
		Partition: partition,
		Parent:    parent,
		FSType:    fsType,
		Label:     body.Label,
	}); err != nil {
		status := http.StatusInternalServerError
		if errors.Is(err, label.ErrInvalidLabel) {
			status = http.StatusBadRequest
		} else if errors.Is(err, label.ErrUnsupportedFS) {
			status = http.StatusBadRequest
		}
		writeJSON(w, status, map[string]string{"error": err.Error()})
		return
	}
	slog.Info("relabelled", "partition", partition, "new_label", body.Label)
	w.WriteHeader(http.StatusNoContent)
}
