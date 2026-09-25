package api

import (
	"context"
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
	if !s.requireWritableDevice(w, dev) {
		return
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

	release, ok := s.beginOp(w, parent, "flash")
	if !ok {
		return
	}
	defer release()

	streamOp(s, w, func(emit func(flash.Event)) error {
		// Background context — client aborts should still let us finish
		// (or cleanly fail) the writes we've started. Reading r.Body
		// errors naturally if the client disconnects, which propagates as
		// a flash error.
		err := s.flsh.Flash(context.Background(), flash.Request{
			Parent:      parent,
			Compression: comp,
			Source:      r.Body,
			Release:     release,
		}, emit)
		if err != nil {
			slog.Error("flash failed", "parent", parent, "err", err)
		}
		return err
	}, func(err error) flash.Event {
		return flash.Event{Stage: "error", Message: err.Error()}
	})
}
