package api

import (
	"compress/gzip"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"

	"github.com/emdzej/airlock/internal/devices"
	"github.com/emdzej/airlock/internal/flash"
)

// GET /api/devices/{parent}/dump?compression=none|xz|gz
//
// Streams the raw contents of /dev/<parent> to the client as a
// downloadable image (`Content-Disposition: attachment`), optionally
// compressed on the fly. Read-only: no unmount, no lifecycle side
// effects on the daemon or on SMB clients. We do call sync() first
// so any FS-buffered writes hit the block layer before we read.
//
// For a fully-clean snapshot users can eject the drive first (Devices
// tab → per-device Eject) and then dump; sync-alone is usually enough
// for backups where a bit-for-bit-identical dump isn't required.
func (s *Server) handleDump(w http.ResponseWriter, r *http.Request) {
	parent := r.PathValue("parent")
	dev, err := devices.Get(parent)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": err.Error()})
		return
	}

	comp := flash.Compression(r.URL.Query().Get("compression"))
	if comp == "" {
		comp = flash.CompressionXZ // sensible default: mostly-empty cards compress hard
	}
	if !comp.Valid() {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unsupported compression"})
		return
	}

	filename := dumpFilename(dev, comp)

	syscall.Sync()

	devPath := "/dev/" + parent
	src, err := os.Open(devPath)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	defer src.Close()

	w.Header().Set("Content-Type", contentTypeFor(comp))
	w.Header().Set("Content-Disposition", `attachment; filename="`+filename+`"`)
	// Content-Length is only useful for uncompressed streams; xz/gz sizes
	// aren't known ahead of time.
	if comp == flash.CompressionNone && dev.SizeBytes > 0 {
		w.Header().Set("Content-Length", fmt.Sprintf("%d", dev.SizeBytes))
	}
	w.WriteHeader(http.StatusOK)

	s.onBusy(true)
	defer s.onBusy(false)

	slog.Info("dump start", "dev", devPath, "compression", comp)
	start := time.Now()

	var (
		written int64
		copyErr error
	)
	switch comp {
	case flash.CompressionNone:
		written, copyErr = io.Copy(w, src)

	case flash.CompressionGZ:
		gz := gzip.NewWriter(w)
		written, copyErr = io.Copy(gz, src)
		if closeErr := gz.Close(); copyErr == nil {
			copyErr = closeErr
		}

	case flash.CompressionXZ:
		// Pipeline: src → xz -c (multi-threaded) → response body.
		cmd := exec.CommandContext(r.Context(), "xz", "-c", "-T", "0")
		cmd.Stdout = w
		var stderrBuf strings.Builder
		cmd.Stderr = &stderrBuf
		stdin, pErr := cmd.StdinPipe()
		if pErr != nil {
			slog.Error("dump: xz stdin pipe", "err", pErr)
			return
		}
		if pErr := cmd.Start(); pErr != nil {
			slog.Error("dump: xz start", "err", pErr)
			return
		}
		written, copyErr = io.Copy(stdin, src)
		_ = stdin.Close()
		waitErr := cmd.Wait()
		if copyErr == nil {
			copyErr = waitErr
		}
		if e := strings.TrimSpace(stderrBuf.String()); e != "" {
			slog.Warn("dump: xz stderr", "err", e)
		}
	}
	if copyErr != nil {
		// The response headers are already sent, so we can only log —
		// the client will see a truncated download and can retry.
		slog.Error("dump aborted", "err", copyErr, "written", written)
		return
	}
	slog.Info("dump complete",
		"dev", devPath, "raw_bytes", written, "compression", comp,
		"seconds", time.Since(start).Seconds())
}

func contentTypeFor(c flash.Compression) string {
	switch c {
	case flash.CompressionXZ:
		return "application/x-xz"
	case flash.CompressionGZ:
		return "application/gzip"
	default:
		return "application/octet-stream"
	}
}

func dumpFilename(d devices.Device, c flash.Compression) string {
	base := ""
	for _, p := range d.Partitions {
		if p.Label != "" {
			base = sanitizeForFilename(p.Label)
			break
		}
	}
	if base == "" {
		base = sanitizeForFilename(strings.TrimSpace(d.Vendor + " " + d.Model))
	}
	if base == "" {
		base = d.Name
	}
	date := time.Now().UTC().Format("2006-01-02")
	ext := ".img"
	switch c {
	case flash.CompressionXZ:
		ext = ".img.xz"
	case flash.CompressionGZ:
		ext = ".img.gz"
	}
	return fmt.Sprintf("airlock-%s-%s%s", base, date, ext)
}

// sanitizeForFilename keeps the filename portable across
// Windows/macOS/Linux — lowercase alphanumerics + `-_.` only.
func sanitizeForFilename(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z',
			r >= '0' && r <= '9',
			r == '-', r == '_', r == '.':
			b.WriteRune(r)
		case r == ' ':
			b.WriteRune('-')
		}
	}
	out := b.String()
	if len(out) > 40 {
		out = out[:40]
	}
	return strings.Trim(out, "-._")
}
