// Package flash streams an image (raw or xz/gz-compressed) from an
// io.Reader (usually the request body) straight onto a whole-disk block
// device. No intermediate storage: bytes go from the HTTP body through
// an optional decompressor into /dev/<parent>. This keeps memory usage
// bounded regardless of image size and avoids writing multi-GB scratch
// files to the Pi's boot SD.
package flash

import (
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"

	"github.com/emdzej/airlock/internal/mount"
)

// Compression is one of the supported input formats.
type Compression string

const (
	CompressionNone Compression = "none"
	CompressionXZ   Compression = "xz"
	CompressionGZ   Compression = "gz"
)

// Valid reports whether c is a supported compression setting.
func (c Compression) Valid() bool {
	switch c {
	case CompressionNone, CompressionXZ, CompressionGZ:
		return true
	}
	return false
}

// AutoDetect returns the Compression implied by filename's extension.
// Callers can use the client-side detection as a fallback.
func AutoDetect(filename string) Compression {
	f := strings.ToLower(filename)
	switch {
	case strings.HasSuffix(f, ".xz"):
		return CompressionXZ
	case strings.HasSuffix(f, ".gz"), strings.HasSuffix(f, ".gzip"):
		return CompressionGZ
	default:
		return CompressionNone
	}
}

// Request describes one flash operation.
type Request struct {
	// Parent is the kernel name of the whole-disk USB device, e.g. "sdb".
	Parent string
	// Compression tells us how to decode Source before writing.
	Compression Compression
	// Source is the byte stream — usually r.Body. Read to EOF.
	Source io.Reader
	// UploadBytes is Content-Length from the request, when known. Used
	// only for early-fail sanity: if the raw upload is already larger
	// than the target, we can refuse before opening the device.
	UploadBytes int64
}

// Event is one progress notification streamed to the client. Stage
// strings are stable so the UI can key on them. On failure Stage is
// "error" and Message carries a human-readable explanation.
type Event struct {
	Stage   string `json:"stage"`
	Message string `json:"message,omitempty"`
	Written int64  `json:"written,omitempty"`
}

// Flasher runs streaming flash operations against the mount manager.
type Flasher struct {
	mgr *mount.Manager
}

// New returns a Flasher bound to the given mount manager.
func New(mgr *mount.Manager) *Flasher { return &Flasher{mgr: mgr} }

// isSafeKernelName defends against attacker-supplied Parent values —
// only lowercase letters + digits (matches "sda", "sdb1", "nvme0n1", …).
func isSafeKernelName(name string) bool {
	if name == "" || len(name) > 32 {
		return false
	}
	for _, r := range name {
		if (r < 'a' || r > 'z') && (r < '0' || r > '9') {
			return false
		}
	}
	return true
}

// Flash runs the full destructive flash operation, calling progress
// with each stage plus periodic byte-count updates during the write.
// Runs synchronously; callers wanting async should invoke in a goroutine.
func (f *Flasher) Flash(ctx context.Context, req Request, progress func(Event)) error {
	if !req.Compression.Valid() {
		return fmt.Errorf("unsupported compression: %q", req.Compression)
	}
	if !isSafeKernelName(req.Parent) {
		return fmt.Errorf("invalid parent device: %q", req.Parent)
	}
	if progress == nil {
		progress = func(Event) {}
	}
	emit := func(stage, msg string) { progress(Event{Stage: stage, Message: msg}) }

	dev := "/dev/" + req.Parent

	// Quarantine so the mount manager ignores any udev events for this
	// device while we're mid-flash. Otherwise the new partition table
	// created by the image would fire ADDs that race with mkfs. Same
	// pattern as format.
	f.mgr.Quarantine(req.Parent)
	quarantineLifted := false
	defer func() {
		if !quarantineLifted {
			f.mgr.Unquarantine(req.Parent)
		}
	}()

	// Drop any Samba client sessions that are currently holding shares
	// on this device open. Without this, umount races with smbd's fds.
	for _, d := range f.mgr.Snapshot().Drives {
		if d.Kernel == req.Parent || d.Parent == req.Parent {
			_, _ = exec.CommandContext(ctx, "smbcontrol", "smbd", "close-share", d.ShareName).CombinedOutput()
		}
	}

	emit("unmount", "unmounting existing partitions on "+dev)
	if err := f.mgr.Eject(req.Parent); err != nil && !errors.Is(err, mount.ErrNotMounted) {
		return fmt.Errorf("unmount %s: %w", dev, err)
	}
	syscall.Sync()

	// Wire up the source stream. For xz we shell out; for gz we use the
	// stdlib. For raw uploads Source is the reader as-is.
	source := req.Source
	var xzCmd *exec.Cmd
	switch req.Compression {
	case CompressionXZ:
		xzCmd = exec.CommandContext(ctx, "xz", "-dc")
		xzCmd.Stdin = req.Source
		stdout, err := xzCmd.StdoutPipe()
		if err != nil {
			return fmt.Errorf("xz stdout pipe: %w", err)
		}
		var xzErr strings.Builder
		xzCmd.Stderr = &xzErr
		if err := xzCmd.Start(); err != nil {
			return fmt.Errorf("xz start: %w", err)
		}
		defer func() {
			_ = xzCmd.Wait()
			if e := strings.TrimSpace(xzErr.String()); e != "" {
				slog.Warn("xz stderr", "err", e)
			}
		}()
		source = stdout
	case CompressionGZ:
		gzr, err := gzip.NewReader(req.Source)
		if err != nil {
			return fmt.Errorf("gzip reader: %w", err)
		}
		defer gzr.Close()
		source = gzr
	}

	emit("write", "writing to "+dev)
	target, err := os.OpenFile(dev, os.O_WRONLY, 0)
	if err != nil {
		return fmt.Errorf("open %s: %w", dev, err)
	}
	defer target.Close()

	// Copy in 4 MB chunks. Progress events fire at most every 500 ms so
	// we don't flood the SSE stream on fast writes.
	buf := make([]byte, 4*1024*1024)
	var written int64
	var lastEmit time.Time
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		n, rerr := source.Read(buf)
		if n > 0 {
			if _, werr := target.Write(buf[:n]); werr != nil {
				return fmt.Errorf("write to %s: %w", dev, werr)
			}
			written += int64(n)
			if time.Since(lastEmit) >= 500*time.Millisecond {
				progress(Event{Stage: "write", Written: written})
				lastEmit = time.Now()
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return fmt.Errorf("read source: %w", rerr)
		}
	}
	// Final "here's the total" event so the UI shows the last number.
	progress(Event{Stage: "write", Written: written})

	emit("sync", "flushing kernel buffers")
	if err := target.Sync(); err != nil {
		return fmt.Errorf("sync %s: %w", dev, err)
	}
	if err := target.Close(); err != nil {
		return fmt.Errorf("close %s: %w", dev, err)
	}
	syscall.Sync()

	// Tell the kernel to re-read the on-device partition table and wait
	// for udev to settle before we hand things back to the mount manager.
	emit("rescan", "re-reading partition table")
	_ = exec.CommandContext(ctx, "partprobe", dev).Run()
	_ = exec.CommandContext(ctx, "udevadm", "settle").Run()

	// Lift the quarantine BEFORE trigger — otherwise the daemon would
	// skip the new partitions.
	f.mgr.Unquarantine(req.Parent)
	quarantineLifted = true
	_ = exec.CommandContext(ctx, "udevadm", "trigger", "--action=change", dev).Run()
	_ = exec.CommandContext(ctx, "udevadm", "settle").Run()

	emit("done", fmt.Sprintf("flash complete — wrote %d bytes", written))
	slog.Info("flashed", "dev", dev, "bytes", written, "compression", req.Compression)
	return nil
}
