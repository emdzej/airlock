package api

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os/exec"
	"strings"
	"time"

	"github.com/emdzej/airlock/internal/devices"
	"github.com/emdzej/airlock/internal/label"
	"github.com/emdzej/airlock/internal/mount"
)

// POST /api/partitions/{name}/label
// Body: {"label": "NEW_NAME"}
// Sets the volume label on a partition. Only certain filesystems are
// supported (see label.SupportedForFS).
func (s *Server) handleSetLabel(w http.ResponseWriter, r *http.Request) {
	partition := r.PathValue("name")

	dev, part, err := devices.FindPartition(partition)
	if err != nil {
		writeJSON(w, lookupStatus(err), map[string]string{"error": err.Error()})
		return
	}
	fsType, ro := part.FSType, dev.ReadOnly
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

	release, ok := s.beginOp(w, dev.Name, "relabel")
	if !ok {
		return
	}
	defer release()
	s.ops.Add(1)
	defer s.ops.Done()
	s.onBusy(true)
	defer s.onBusy(false)

	// Background context, like the other device operations: a client
	// disconnect must not kill the tool half-way through a write.
	if err := label.Set(context.Background(), s.mgr, label.Request{
		Partition: partition,
		FSType:    fsType,
		Label:     body.Label,
		Release:   release,
	}); err != nil {
		status := http.StatusInternalServerError
		switch {
		case errors.Is(err, label.ErrInvalidLabel), errors.Is(err, label.ErrUnsupportedFS):
			status = http.StatusBadRequest
		case errors.Is(err, mount.ErrBusy):
			status = http.StatusConflict
		}
		writeJSON(w, status, map[string]string{"error": err.Error()})
		return
	}
	slog.Info("relabelled", "partition", partition, "new_label", body.Label)
	w.WriteHeader(http.StatusNoContent)
}

// POST /api/partitions/{name}/mount
// Asks the daemon to mount an unmounted partition. We locate the
// partition via lsblk (safety gate: must be USB-attached with a
// supported FS), then fire `udevadm trigger --action=add /dev/<name>`.
// The daemon's netlink listener picks that up on the normal path.
func (s *Server) handleMountPartition(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")

	_, found, err := devices.FindPartition(name)
	if err != nil {
		writeJSON(w, lookupStatus(err), map[string]string{"error": err.Error()})
		return
	}
	if !mount.IsSupported(found.FSType) {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "filesystem not supported for auto-mount: " + found.FSType,
		})
		return
	}
	if found.IsAirlock {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "partition already mounted"})
		return
	}
	slog.Info("mount requested", "partition", name)
	dev := "/dev/" + name
	out, err := exec.Command("udevadm", "trigger", "--action=add", dev).CombinedOutput()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{
			"error": "udevadm trigger failed: " + strings.TrimSpace(string(out)),
		})
		return
	}
	// Give the daemon a beat to process the event so the UI's next poll
	// shows the mount without needing a manual refresh delay.
	time.Sleep(500 * time.Millisecond)
	w.WriteHeader(http.StatusNoContent)
}

// lookupStatus maps a devices lookup error to an HTTP status.
func lookupStatus(err error) int {
	if errors.Is(err, devices.ErrNotFound) {
		return http.StatusNotFound
	}
	return http.StatusInternalServerError
}
