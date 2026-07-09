package api

import (
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

// POST /api/partitions/{name}/mount
// Asks the daemon to mount an unmounted partition. We locate the
// partition via lsblk (safety gate: must be USB-attached with a
// supported FS), then fire `udevadm trigger --action=add /dev/<name>`.
// The daemon's netlink listener picks that up on the normal path.
func (s *Server) handleMountPartition(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")

	all, err := devices.List()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	var found devices.Partition
	var device devices.Device
	for _, d := range all {
		for _, p := range d.Partitions {
			if p.Name == name {
				found = p
				device = d
				break
			}
		}
		if found.Name != "" {
			break
		}
	}
	if found.Name == "" {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "partition not found (not USB-attached?)"})
		return
	}
	if !mount.SupportedFilesystems[normalizeFSName(found.FSType)] {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "filesystem not supported for auto-mount: " + found.FSType,
		})
		return
	}
	if found.IsAirlock {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "partition already mounted"})
		return
	}
	_ = device // reserved for future safety checks

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

// normalizeFSName maps blkid's FS name string to the key used in
// mount.SupportedFilesystems (which uses "vfat", "exfat", "ntfs", etc.).
func normalizeFSName(fs string) string {
	switch fs {
	case "fat", "fat32", "fat16":
		return "vfat"
	case "ntfs3":
		return "ntfs"
	default:
		return fs
	}
}
