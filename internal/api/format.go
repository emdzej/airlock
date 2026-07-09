package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"

	"github.com/emdzej/airlock/internal/devices"
	"github.com/emdzej/airlock/internal/format"
	"github.com/emdzej/airlock/internal/fsck"
	"github.com/emdzej/airlock/internal/label"
	"github.com/emdzej/airlock/internal/mount"
)

// GET /api/devices — list every USB-attached block device (whole disks) with
// partition tree. Used by the /devices page.
func (s *Server) handleListDevices(w http.ResponseWriter, _ *http.Request) {
	list, err := devices.List()
	if err != nil {
		slog.Error("devices list", "err", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	out := make([]devicePayload, 0, len(list))
	for _, d := range list {
		out = append(out, s.devicePayload(d))
	}
	writeJSON(w, http.StatusOK, out)
}

// GET /api/devices/{parent}
// Returns extended per-device info: model/vendor/serial, whole-disk size,
// partition table type, and every partition on the device (mounted or not).
func (s *Server) handleDeviceInfo(w http.ResponseWriter, r *http.Request) {
	parent := r.PathValue("parent")
	d, err := devices.Get(parent)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, s.devicePayload(d))
}

// devicePayload is the wire shape for a Device with pre-formatted size
// strings and a filesystem suggestion baked in.
type devicePayload struct {
	Name        string             `json:"name"`
	Path        string             `json:"path"`
	Model       string             `json:"model"`
	Vendor      string             `json:"vendor"`
	Serial      string             `json:"serial"`
	SizeBytes   int64              `json:"size_bytes"`
	SizeHuman   string             `json:"size_human"`
	Transport   string             `json:"transport"`
	PTType      string             `json:"pt_type"`
	ReadOnly    bool               `json:"read_only"`
	AnyRO       bool               `json:"any_partition_read_only"`
	SuggestedFS string             `json:"suggested_fs"`
	Partitions  []partitionPayload `json:"partitions"`
}

type partitionPayload struct {
	Name        string `json:"name"`
	SizeBytes   int64  `json:"size_bytes"`
	SizeHuman   string `json:"size_human"`
	FSType      string `json:"fs_type"`
	Label       string `json:"label"`
	UUID        string `json:"uuid"`
	MountPoint  string `json:"mount_point"`
	IsAirlock   bool   `json:"is_airlock"`
	ShareName   string `json:"share_name,omitempty"` // airlock share, if mounted by us
	CanRelabel  bool   `json:"can_relabel"`          // fs supports airlock relabel
	MaxLabelLen int    `json:"max_label_len"`        // 0 if no relabel support
	CanMount    bool   `json:"can_mount"`            // FS supported and not currently mounted
	CanFsck     bool   `json:"can_fsck"`             // FS supports airlock fsck
}

func (s *Server) devicePayload(d devices.Device) devicePayload {
	// Cross-reference partitions against the mount manager to fill in the
	// airlock share name where applicable — the browser links directly to
	// the file browser using this.
	shareByKernel := make(map[string]string)
	anyRO := d.ReadOnly
	for _, mn := range s.mgr.Snapshot().Drives {
		shareByKernel[mn.Kernel] = mn.ShareName
		if (mn.Kernel == d.Name || mn.Parent == d.Name) && mn.ReadOnly {
			anyRO = true
		}
	}
	parts := make([]partitionPayload, 0, len(d.Partitions))
	for _, p := range d.Partitions {
		parts = append(parts, partitionPayload{
			Name:        p.Name,
			SizeBytes:   p.SizeBytes,
			SizeHuman:   humanBytes(p.SizeBytes),
			FSType:      p.FSType,
			Label:       p.Label,
			UUID:        p.UUID,
			MountPoint:  p.MountPoint,
			IsAirlock:   p.IsAirlock,
			ShareName:   shareByKernel[p.Name],
			CanRelabel:  !d.ReadOnly && label.SupportedForFS(p.FSType),
			MaxLabelLen: label.MaxLenForFS(p.FSType),
			CanMount:    !p.IsAirlock && p.MountPoint == "" && mount.SupportedFilesystems[normalizeFSName(p.FSType)],
			CanFsck:     fsck.SupportedForFS(p.FSType),
		})
	}
	suggested := "vfat"
	if d.SizeBytes >= 32*1000*1000*1000 {
		suggested = "exfat"
	}
	return devicePayload{
		Name:        d.Name,
		Path:        d.Path,
		Model:       d.Model,
		Vendor:      d.Vendor,
		Serial:      d.Serial,
		SizeBytes:   d.SizeBytes,
		SizeHuman:   humanBytes(d.SizeBytes),
		Transport:   d.Transport,
		PTType:      d.PTType,
		ReadOnly:    d.ReadOnly,
		AnyRO:       anyRO,
		SuggestedFS: suggested,
		Partitions:  parts,
	}
}

// POST /api/devices/{parent}/format
// Body: {"fs":"vfat|exfat|ntfs|ext4","label":"..."}
// Response: text/event-stream with `data: {"stage":"...","message":"..."}` per event.
// The final event has stage == "done" or stage == "error".
//
// The format itself runs on a background context — if the client disconnects
// mid-format, the operation still completes cleanly. Interrupting mkfs would
// leave the drive in a worse state than a completed run.
func (s *Server) handleFormat(w http.ResponseWriter, r *http.Request) {
	parent := r.PathValue("parent")

	// Safety gate: the device must be a currently-attached USB block device.
	// This blocks a malicious POST to /api/devices/mmcblk0/format from ever
	// reaching mkfs. Formatting a blank/unpartitioned USB drive with no
	// mounted share is allowed.
	dev, err := devices.Get(parent)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": err.Error()})
		return
	}
	if dev.ReadOnly {
		writeJSON(w, http.StatusForbidden, map[string]string{
			"error": "device is read-only (write-protect switch?)",
		})
		return
	}
	// If any mounted partition on this device is RO (unlikely on a
	// write-enabled disk, but possible for iso9660 hybrid layouts), refuse.
	for _, mn := range s.mgr.Snapshot().Drives {
		if (mn.Kernel == parent || mn.Parent == parent) && mn.ReadOnly {
			writeJSON(w, http.StatusForbidden, map[string]string{
				"error": "at least one partition on this device is read-only",
			})
			return
		}
	}

	var body struct {
		FS    string `json:"fs"`
		Label string `json:"label"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON body"})
		return
	}
	fs := format.Filesystem(body.FS)
	if !fs.Valid() {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unsupported filesystem"})
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	flusher, _ := w.(http.Flusher)

	s.onBusy(true)
	defer s.onBusy(false)

	events := make(chan format.Event, 32)
	go func() {
		defer close(events)
		err := s.fmtr.Format(context.Background(), format.Request{
			Parent: parent,
			FS:     fs,
			Label:  body.Label,
		}, func(ev format.Event) {
			select {
			case events <- ev:
			default:
				// buffer full; drop to keep the format progressing
			}
		})
		if err != nil {
			slog.Error("format failed", "parent", parent, "err", err)
			select {
			case events <- format.Event{Stage: "error", Message: err.Error()}:
			default:
			}
		}
	}()

	for ev := range events {
		data, _ := json.Marshal(ev)
		if _, err := fmt.Fprintf(w, "data: %s\n\n", data); err != nil {
			// Client disconnected. Drain remaining events so the goroutine
			// isn't blocked on send, but stop writing.
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

// POST /api/devices/{parent}/eject — unmounts every partition of the device
// that airlock currently owns. No-op if nothing is mounted.
func (s *Server) handleDeviceEject(w http.ResponseWriter, r *http.Request) {
	parent := r.PathValue("parent")
	if _, err := devices.Get(parent); err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": err.Error()})
		return
	}
	s.onBusy(true)
	defer s.onBusy(false)
	if err := s.mgr.Eject(parent); err != nil && !errors.Is(err, mount.ErrNotMounted) {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	_ = io.EOF // satisfy unused-import guard when nothing else references it
	w.WriteHeader(http.StatusNoContent)
}
