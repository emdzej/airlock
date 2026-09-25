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

	"github.com/emdzej/airlock/internal/devices"
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
	// Release lifts the caller's mount.Manager.BeginOp hold; called just
	// before the final udev re-trigger. Must be idempotent.
	Release func()
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

// Flash runs the full destructive flash operation, calling progress
// with each stage plus periodic byte-count updates during the write.
// Runs synchronously; the caller must hold mgr.BeginOp for req.Parent.
func (f *Flasher) Flash(ctx context.Context, req Request, progress func(Event)) error {
	if !req.Compression.Valid() {
		return fmt.Errorf("unsupported compression: %q", req.Compression)
	}
	if !devices.ValidKernelName(req.Parent) {
		return fmt.Errorf("invalid parent device: %q", req.Parent)
	}
	if progress == nil {
		progress = func(Event) {}
	}
	release := req.Release
	if release == nil {
		release = func() {}
	}
	emit := func(stage, msg string) { progress(Event{Stage: stage, Message: msg}) }

	dev := "/dev/" + req.Parent

	// The manager closes Samba sessions on these shares before unmounting,
	// so smbd doesn't race us for the device.
	emit("unmount", "unmounting existing partitions on "+dev)
	if err := f.mgr.Eject(req.Parent); err != nil && !errors.Is(err, mount.ErrNotMounted) {
		return fmt.Errorf("unmount %s: %w", dev, err)
	}
	syscall.Sync()

	// Cancelling ctx on any failure kills the xz child. Without this a
	// failed device write would leave xz blocked on a full stdout pipe and
	// the deferred Wait would hang forever.
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	// Wire up the source stream. For xz we shell out; for gz we use the
	// stdlib. For raw uploads Source is the reader as-is.
	source := req.Source
	var (
		xzCmd *exec.Cmd
		xzErr strings.Builder
	)
	switch req.Compression {
	case CompressionXZ:
		xzCmd = exec.CommandContext(ctx, "xz", "-dc")
		xzCmd.Stdin = req.Source
		xzCmd.Stderr = &xzErr
		// Don't let Wait hang on the stdin copier if the client stalls
		// after we've killed xz.
		xzCmd.WaitDelay = 5 * time.Second
		stdout, err := xzCmd.StdoutPipe()
		if err != nil {
			return fmt.Errorf("xz stdout pipe: %w", err)
		}
		if err := xzCmd.Start(); err != nil {
			return fmt.Errorf("xz start: %w", err)
		}
		// On failure paths: kill xz, then reap it. The success path below
		// calls Wait itself so xz's exit status (corrupt input, truncated
		// upload) turns into a flash error.
		defer func() {
			if xzCmd != nil {
				cancel()
				_ = xzCmd.Wait()
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
	// O_EXCL on a block device fails with EBUSY if anything (a mount, the
	// running system) still holds it — last line of defence against
	// overwriting a live filesystem.
	target, err := os.OpenFile(dev, os.O_WRONLY|os.O_EXCL, 0)
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
		if err := ctx.Err(); err != nil {
			return err
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
	if xzCmd != nil {
		werr := xzCmd.Wait()
		xzCmd = nil // reaped
		if werr != nil {
			return fmt.Errorf("xz: %w: %s", werr, strings.TrimSpace(xzErr.String()))
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
	release()
	_ = exec.CommandContext(ctx, "udevadm", "trigger", "--action=change", dev).Run()
	_ = exec.CommandContext(ctx, "udevadm", "settle").Run()

	emit("done", fmt.Sprintf("flash complete — wrote %d bytes", written))
	slog.Info("flashed", "dev", dev, "bytes", written, "compression", req.Compression)
	return nil
}
