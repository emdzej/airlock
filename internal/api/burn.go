package api

import (
	"context"
	"log/slog"
	"net/http"
	"strconv"

	"github.com/emdzej/airlock/internal/burn"
	"github.com/emdzej/airlock/internal/devices"
	"github.com/emdzej/airlock/internal/flash"
)

// discPayload is a burn.Disc plus where the image would be cached.
type discPayload struct {
	burn.Disc
	CacheFreeBytes int64 `json:"cache_free_bytes"`
}

// GET /api/devices/{parent}/disc
// Reports the disc in an optical drive: media type, blank / written,
// whether an image can be burned onto it and how big it may be, and the
// free space in the burn cache.
func (s *Server) handleDisc(w http.ResponseWriter, r *http.Request) {
	dev, ok := s.opticalDevice(w, r.PathValue("parent"))
	if !ok {
		return
	}
	if op, running := s.mgr.RunningOp(dev.Name); running {
		writeJSON(w, http.StatusConflict, map[string]string{"error": op + " in progress on " + dev.Name})
		return
	}
	disc, err := burn.Inspect(r.Context(), dev.Path)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	free, err := s.burner.CacheFree()
	if err != nil {
		slog.Warn("burn cache", "err", err)
	}
	writeJSON(w, http.StatusOK, discPayload{Disc: disc, CacheFreeBytes: free})
}

// POST /api/devices/{parent}/burn?compression=none|xz|gz&verify=0|1&eject=0|1&speed=<kB/s>
// Body: the image bytes (compressed or not).
// Response: text/event-stream with `data: {"stage":"...","message":"...","written":N,"total":N}`
// per event. Terminal event is stage=done or stage=error.
//
// The image is cached on the Pi in full before the drive is touched, so
// a dropped upload fails the request with the disc untouched. verify
// defaults to on, eject to off (the new disc is mounted instead). speed is
// a kbps value from the disc's speeds; absent or 0 burns at the maximum.
func (s *Server) handleBurn(w http.ResponseWriter, r *http.Request) {
	dev, ok := s.opticalDevice(w, r.PathValue("parent"))
	if !ok {
		return
	}
	q := r.URL.Query()
	comp := flash.Compression(q.Get("compression"))
	if comp == "" {
		comp = flash.CompressionNone
	}
	if !comp.Valid() {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "unsupported compression (want: none, xz, gz)",
		})
		return
	}

	speed := 0
	if v := q.Get("speed"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 0 || n > 1_000_000 {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "speed must be a write speed in kB/s"})
			return
		}
		speed = n
	}

	release, ok := s.beginOp(w, dev.Name, "burn")
	if !ok {
		return
	}
	defer release()

	streamOp(s, w, func(emit func(burn.Event)) error {
		// Background context, as for flash: a client that goes away
		// mid-upload fails the read (and the burn, before it starts);
		// one that goes away mid-burn doesn't stop it.
		err := s.burner.Burn(context.Background(), burn.Request{
			Device:      dev.Name,
			Compression: comp,
			Source:      r.Body,
			Size:        r.ContentLength,
			Verify:      q.Get("verify") != "0",
			Eject:       q.Get("eject") == "1",
			Speed:       speed,
			Release:     release,
		}, emit)
		if err != nil {
			slog.Error("burn failed", "device", dev.Name, "err", err)
		}
		return err
	}, func(err error) burn.Event {
		return burn.Event{Stage: "error", Message: err.Error()}
	})
}

// opticalDevice looks up a USB optical drive, writing a 404 or 400 if
// name isn't one.
func (s *Server) opticalDevice(w http.ResponseWriter, name string) (devices.Device, bool) {
	dev, err := devices.Get(name)
	if err != nil {
		writeJSON(w, lookupStatus(err), map[string]string{"error": err.Error()})
		return devices.Device{}, false
	}
	if !dev.Optical {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": name + " is not an optical drive"})
		return devices.Device{}, false
	}
	return dev, true
}

// SetBurnCache points the burn cache at dir (AIRLOCK_BURN_CACHE); empty
// keeps burn.DefaultCacheDir.
func (s *Server) SetBurnCache(dir string) {
	if dir != "" {
		s.burner = burn.New(s.mgr, dir)
	}
}
