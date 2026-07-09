package api

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/emdzej/airlock/internal/devices"
	"github.com/emdzej/airlock/internal/flash"
)

// POST /api/devices/{parent}/flash?compression=none|xz|gz
// Body: the raw image bytes (compressed or not).
// Response: text/event-stream with `data: {"stage":"...","message":"...","written":N}`
// per event. Terminal event is stage=done or stage=error.
//
// Same design as format: destructive, safety-gated to USB-attached
// devices, runs on a background context so client disconnect doesn't
// leave the drive in a partial state we can't reason about.
func (s *Server) handleFlash(w http.ResponseWriter, r *http.Request) {
	parent := r.PathValue("parent")

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
	for _, mn := range s.mgr.Snapshot().Drives {
		if (mn.Kernel == parent || mn.Parent == parent) && mn.ReadOnly {
			writeJSON(w, http.StatusForbidden, map[string]string{
				"error": "at least one partition on this device is read-only",
			})
			return
		}
	}

	comp := flash.Compression(r.URL.Query().Get("compression"))
	if comp == "" {
		comp = flash.CompressionNone
	}
	if !comp.Valid() {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "unsupported compression (want: none, xz, gz)",
		})
		return
	}

	// Cheap early fail: if the upload itself is bigger than the device,
	// refuse before touching anything. Compressed images may still
	// decompress to too much, but we catch that mid-write.
	if r.ContentLength > 0 && dev.SizeBytes > 0 && comp == flash.CompressionNone && r.ContentLength > dev.SizeBytes {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": fmt.Sprintf("image (%d bytes) is larger than device (%d bytes)",
				r.ContentLength, dev.SizeBytes),
		})
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	flusher, _ := w.(http.Flusher)

	s.onBusy(true)
	defer s.onBusy(false)

	events := make(chan flash.Event, 32)
	go func() {
		defer close(events)
		// Background context — client aborts should still let us finish
		// the writes we've started. Reading r.Body will error naturally
		// if the client disconnects, which propagates as a flash error.
		err := s.flsh.Flash(context.Background(), flash.Request{
			Parent:      parent,
			Compression: comp,
			Source:      r.Body,
			UploadBytes: r.ContentLength,
		}, func(ev flash.Event) {
			select {
			case events <- ev:
			default:
				// buffer full — drop this update, more will come
			}
		})
		if err != nil {
			slog.Error("flash failed", "parent", parent, "err", err)
			select {
			case events <- flash.Event{Stage: "error", Message: err.Error()}:
			default:
			}
		}
	}()

	for ev := range events {
		data, _ := json.Marshal(ev)
		if _, err := fmt.Fprintf(w, "data: %s\n\n", data); err != nil {
			// Client disconnected. Drain remaining events so the
			// goroutine can finish and unmount properly.
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
