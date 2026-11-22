// Package burn writes a ready-made disc image (ISO 9660, UDF, hybrid)
// onto a CD, DVD or Blu-ray in a USB optical drive, with xorriso.
//
// Unlike flash, the upload is not streamed onto the medium. A recordable
// disc is written once: an upload that stalls or drops halfway through
// would ruin it, and a drive that runs dry mid-burn may too. So the whole
// image is received (and decompressed) into a cache directory first,
// checked against the disc's capacity, and only then burned from local
// storage. The cached copy is also what the burn is verified against.
package burn

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/emdzej/airlock/internal/devices"
	"github.com/emdzej/airlock/internal/flash"
	"github.com/emdzej/airlock/internal/mount"
)

// DefaultCacheDir is where images wait to be burned, unless
// AIRLOCK_BURN_CACHE says otherwise. It must sit on disk-backed storage
// with room for the largest image: on the stock image's tmpfs overlay
// root it is RAM, which only fits CD-sized images.
const DefaultCacheDir = "/var/cache/airlock/burn"

// cacheMargin is free space left over in the cache directory after the
// image, so caching never fills the filesystem to the last byte.
const cacheMargin = 256 << 20

// Request describes one burn.
type Request struct {
	// Device is the kernel name of the optical drive, e.g. "sr0".
	Device string
	// Compression tells us how to decode Source before caching it.
	Compression flash.Compression
	// Source is the image byte stream, usually r.Body. Read to EOF.
	Source io.Reader
	// Size is the upload's length (Content-Length), or -1 if unknown.
	Size int64
	// Verify reads the disc back and compares it with the image.
	Verify bool
	// Eject opens the tray when done; otherwise the new disc is mounted.
	Eject bool
	// Speed is the write speed in kB/s (a Disc.Speeds value); 0 burns at
	// the drive's maximum. The drive picks the nearest speed it supports.
	Speed int
	// Release lifts the caller's mount.Manager.BeginOp hold; called just
	// before the final udev re-trigger. Must be idempotent.
	Release func()
}

// Event is one progress notification streamed to the client. Stages:
// "check", "unmount", "cache", "burn", "verify", "eject", "line" (a line
// of xorriso output), "done", "error". During burn and verify Written
// counts towards Total.
type Event struct {
	Stage   string `json:"stage"`
	Message string `json:"message,omitempty"`
	Written int64  `json:"written,omitempty"`
	Total   int64  `json:"total,omitempty"`
}

// Burner runs burns against the mount manager.
type Burner struct {
	mgr *mount.Manager
	dir string
}

// New returns a Burner caching images in dir, and removes images a
// previous run left behind (a crash or power cut mid-burn).
func New(mgr *mount.Manager, dir string) *Burner {
	if dir == "" {
		dir = DefaultCacheDir
	}
	if old, err := filepath.Glob(filepath.Join(dir, "burn-*.img")); err == nil {
		for _, f := range old {
			if err := os.Remove(f); err == nil {
				slog.Info("removed stale burn cache", "file", f)
			}
		}
	}
	return &Burner{mgr: mgr, dir: dir}
}

// CacheDir is the directory images are cached in.
func (b *Burner) CacheDir() string { return b.dir }

// CacheFree returns the bytes an image may take up in the cache directory
// (free space less the margin), creating the directory if needed.
func (b *Burner) CacheFree() (int64, error) {
	if err := os.MkdirAll(b.dir, 0o700); err != nil {
		return 0, fmt.Errorf("burn cache %s: %w", b.dir, err)
	}
	var st syscall.Statfs_t
	if err := syscall.Statfs(b.dir, &st); err != nil {
		return 0, fmt.Errorf("burn cache %s: %w", b.dir, err)
	}
	return max(int64(st.Bavail)*int64(st.Bsize)-cacheMargin, 0), nil
}

// Burn runs the whole operation, calling progress with each stage and
// periodic byte counts. Runs synchronously; the caller must hold
// mgr.BeginOp for req.Device.
func (b *Burner) Burn(ctx context.Context, req Request, progress func(Event)) error {
	if !req.Compression.Valid() {
		return fmt.Errorf("unsupported compression: %q", req.Compression)
	}
	if !devices.ValidKernelName(req.Device) {
		return fmt.Errorf("invalid device: %q", req.Device)
	}
	if progress == nil {
		progress = func(Event) {}
	}
	release := req.Release
	if release == nil {
		release = func() {}
	}
	emit := func(stage, msg string) { progress(Event{Stage: stage, Message: msg}) }
	dev := "/dev/" + req.Device

	emit("check", "checking the disc in "+dev)
	disc, err := Inspect(ctx, dev)
	if err != nil {
		return err
	}
	if !disc.Writable {
		return errors.New(disc.Reason)
	}
	// Uncompressed uploads are the image: refuse one that can't fit before
	// receiving gigabytes of it. Compressed ones are checked once cached.
	if req.Compression == flash.CompressionNone && req.Size > 0 && disc.CapacityBytes > 0 && req.Size > disc.CapacityBytes {
		return tooBig(req.Size, disc)
	}
	free, err := b.CacheFree()
	if err != nil {
		return err
	}
	if req.Size > free {
		return fmt.Errorf("not enough room to cache the image: %s needed, %s free in %s",
			human(req.Size), human(free), b.dir)
	}

	img, err := b.cache(ctx, req, free, emit)
	if err != nil {
		return err
	}
	defer os.Remove(img)
	st, err := os.Stat(img)
	if err != nil {
		return err
	}
	size := st.Size()
	if size == 0 {
		return errors.New("the image is empty")
	}
	if disc.CapacityBytes > 0 && size > disc.CapacityBytes {
		return tooBig(size, disc)
	}

	// Only now, with the image safely on local storage, touch the drive.
	// The manager closes Samba sessions on the disc's share first.
	emit("unmount", "unmounting the disc in "+dev)
	if err := b.mgr.Eject(req.Device); err != nil && !errors.Is(err, mount.ErrNotMounted) {
		return fmt.Errorf("unmount %s: %w", dev, err)
	}

	msg := fmt.Sprintf("burning %s onto the %s", human(size), disc.Media)
	if req.Speed > 0 {
		msg += " at " + speedLabel(req.Speed, disc.Speeds)
	}
	if disc.Erases {
		msg += " (erasing it)"
	}
	emit("burn", msg)
	if err := burnImage(ctx, dev, img, size, !disc.Rewritable, req.Speed, progress); err != nil {
		return err
	}
	progress(Event{Stage: "burn", Written: size, Total: size})

	if req.Verify {
		emit("verify", "reading the disc back")
		if err := verify(ctx, dev, img, size, progress); err != nil {
			return err
		}
	}

	if req.Eject {
		emit("eject", "opening the tray")
		if err := EjectTray(dev); err != nil {
			slog.Warn("eject tray", "dev", dev, "err", err)
		}
	}
	// Lift the quarantine BEFORE the trigger, so the new disc is mounted.
	release()
	_ = exec.CommandContext(ctx, "udevadm", "trigger", "--action=change", dev).Run()
	_ = exec.CommandContext(ctx, "udevadm", "settle").Run()

	done := "burn complete — wrote " + human(size)
	if req.Verify {
		done += ", verified"
	}
	emit("done", done)
	slog.Info("burned", "dev", dev, "bytes", size, "media", disc.Media, "verified", req.Verify)
	return nil
}

// speedLabel names a speed in kB/s: its "8x" label when the drive listed
// it, else the throughput.
func speedLabel(kbps int, speeds []Speed) string {
	for _, s := range speeds {
		if s.KBps == kbps {
			return s.Label
		}
	}
	return fmt.Sprintf("%.1f MB/s", float64(kbps)/1000)
}

func tooBig(size int64, d Disc) error {
	return fmt.Errorf("the image (%s) doesn't fit on this %s (%s)", human(size), d.Media, human(d.CapacityBytes))
}

// cache receives the (decoded) image into a file in the cache directory
// and returns its path. A failed or cut-off upload leaves nothing behind.
func (b *Burner) cache(ctx context.Context, req Request, free int64, emit func(string, string)) (path string, err error) {
	f, err := os.CreateTemp(b.dir, "burn-*.img")
	if err != nil {
		return "", fmt.Errorf("burn cache: %w", err)
	}
	defer func() {
		if cerr := f.Close(); err == nil && cerr != nil {
			err = fmt.Errorf("burn cache: %w", cerr)
		}
		if err != nil {
			os.Remove(f.Name())
		}
	}()
	dec, err := flash.NewDecoder(ctx, req.Source, req.Compression)
	if err != nil {
		return "", err
	}
	defer dec.Abort()

	emit("cache", "receiving the image")
	// A decompressed image can outgrow the upload: stop at the free space
	// rather than at a full filesystem.
	n, err := io.Copy(f, io.LimitReader(dec, free+1))
	if err != nil {
		return "", fmt.Errorf("receive image: %w", err)
	}
	if n > free {
		return "", fmt.Errorf("not enough room to cache the image: more than %s free in %s", human(free), b.dir)
	}
	if err := dec.Finish(); err != nil {
		return "", err
	}
	if req.Size > 0 && req.Compression == flash.CompressionNone && n != req.Size {
		return "", fmt.Errorf("upload ended early: %d of %d bytes", n, req.Size)
	}
	if err := f.Sync(); err != nil {
		return "", fmt.Errorf("burn cache: %w", err)
	}
	emit("cache", "received "+human(n))
	return f.Name(), nil
}

// progressRE matches xorriso's burn progress, e.g.
// "xorriso : UPDATE :  1234 of  4400 MB written (fifo 95%) [buf 100%]  4.0x."
var progressRE = regexp.MustCompile(`(\d+) of\s+(\d+) MB written`)

// burnImage runs xorriso's cdrecord emulation, the way it burns a prepared
// image: blank rewritable media as needed, write one session, close the
// disc. Write-once media are written disc-at-once (no run-out blocks after
// the image on a CD); rewritable ones in the default mode, since a
// fast-blanked DVD-RW takes no disc-at-once write. speed is in kB/s, 0
// for the drive's maximum. Progress lines become burn events, everything
// else log lines.
func burnImage(ctx context.Context, dev, img string, size int64, dao bool, speed int, progress func(Event)) error {
	args := []string{"-as", "cdrecord", "-v", "dev=" + dev, "blank=as_needed"}
	if dao {
		args = append(args, "-dao")
	}
	if speed > 0 {
		args = append(args, fmt.Sprintf("speed=%dk", speed))
	}
	cmd := exec.CommandContext(ctx, "xorriso", append(args, img)...)
	// xorriso reports on stderr; one reader keeps the lines in order.
	pr, pw := io.Pipe()
	cmd.Stdout = pw
	cmd.Stderr = pw
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start xorriso: %w", err)
	}
	waitErr := make(chan error, 1)
	go func() {
		err := cmd.Wait()
		pw.Close()
		waitErr <- err
	}()

	var tail []string // the last few lines, for the error message
	sc := bufio.NewScanner(pr)
	sc.Buffer(make([]byte, 0, 4096), 1024*1024)
	sc.Split(scanLinesCR)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		if m := progressRE.FindStringSubmatch(line); m != nil {
			done, _ := strconv.ParseInt(m[1], 10, 64)
			progress(Event{Stage: "burn", Written: min(done<<20, size), Total: size})
			continue
		}
		progress(Event{Stage: "line", Message: line})
		if tail = append(tail, line); len(tail) > 3 {
			tail = tail[1:]
		}
	}
	_, _ = io.Copy(io.Discard, pr) // a line past the buffer limit stops the scanner
	if err := <-waitErr; err != nil {
		return fmt.Errorf("xorriso: %w: %s", err, strings.Join(tail, "; "))
	}
	return nil
}

// scanLinesCR splits on \n or \r: progress meters may redraw in place.
func scanLinesCR(data []byte, atEOF bool) (advance int, token []byte, err error) {
	if i := bytes.IndexAny(data, "\r\n"); i >= 0 {
		return i + 1, data[:i], nil
	}
	if atEOF && len(data) > 0 {
		return len(data), data, nil
	}
	return 0, nil, nil
}

// verify reads the first size bytes of the disc and compares them with
// the cached image.
func verify(ctx context.Context, dev, img string, size int64, progress func(Event)) error {
	// The kernel may still hold the empty disc's size and cached blocks
	// from before the burn; reload the tray if needed so it re-reads both.
	if err := waitForMedium(ctx, dev, size); err != nil {
		return err
	}
	disc, err := os.Open(dev)
	if err != nil {
		return fmt.Errorf("verify: open %s: %w", dev, err)
	}
	defer disc.Close()
	flushBuffers(disc)
	return compareImage(ctx, disc, img, size, progress)
}

// compareImage checks that disc starts with the size bytes of img.
func compareImage(ctx context.Context, disc io.Reader, img string, size int64, progress func(Event)) error {
	src, err := os.Open(img)
	if err != nil {
		return fmt.Errorf("verify: %w", err)
	}
	defer src.Close()

	const chunk = 4 << 20
	a := make([]byte, chunk)
	bb := make([]byte, chunk)
	var off int64
	var lastEmit time.Time
	for off < size {
		if err := ctx.Err(); err != nil {
			return err
		}
		n := int(min(int64(chunk), size-off))
		if _, err := io.ReadFull(src, a[:n]); err != nil {
			return fmt.Errorf("verify: read image: %w", err)
		}
		if _, err := io.ReadFull(disc, bb[:n]); err != nil {
			return fmt.Errorf("verify: read disc at %s: %w", human(off), err)
		}
		if !bytes.Equal(a[:n], bb[:n]) {
			i := 0
			for a[i] == bb[i] {
				i++
			}
			return fmt.Errorf("verify failed: the disc differs from the image at byte %d", off+int64(i))
		}
		off += int64(n)
		if time.Since(lastEmit) >= 500*time.Millisecond {
			progress(Event{Stage: "verify", Written: off, Total: size})
			lastEmit = time.Now()
		}
	}
	progress(Event{Stage: "verify", Written: size, Total: size})
	return nil
}

// waitForMedium waits until the kernel sees at least size bytes on the
// disc. Drives that don't report the new medium by themselves get their
// tray reloaded once (a slot-loading or tray-less drive can't be).
func waitForMedium(ctx context.Context, dev string, size int64) error {
	_ = exec.CommandContext(ctx, "udevadm", "settle").Run()
	if waitSize(ctx, dev, size, 15*time.Second) {
		return nil
	}
	slog.Info("reloading tray to re-read the disc", "dev", dev)
	if err := reloadTray(dev); err != nil {
		return fmt.Errorf("verify: the drive still reports the old disc size and couldn't reload its tray (%v); eject and reinsert the disc to check it", err)
	}
	if waitSize(ctx, dev, size, 60*time.Second) {
		return nil
	}
	return errors.New("verify: the drive reports less data on the disc than was burned; eject and reinsert the disc to check it")
}

// waitSize polls the kernel's view of the disc size.
func waitSize(ctx context.Context, dev string, size int64, timeout time.Duration) bool {
	sysSize := filepath.Join("/sys/class/block", filepath.Base(dev), "size")
	deadline := time.Now().Add(timeout)
	for {
		if b, err := os.ReadFile(sysSize); err == nil {
			if n, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64); err == nil && n*512 >= size {
				return true
			}
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			return false
		}
		time.Sleep(time.Second)
	}
}

func human(n int64) string {
	const unit = 1000
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for m := n / unit; m >= unit; m /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(n)/float64(div), "kMGTPE"[exp])
}
