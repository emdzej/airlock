// Package format handles the destructive lifecycle of "wipe this drive and
// give it a fresh filesystem." Steps: unmount → wipefs → parted (partition
// table + one partition) → partprobe → mkfs → udevadm trigger. The mount
// manager picks up the new partition via its normal udev subscription.
package format

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os/exec"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/emdzej/airlock/internal/devices"
	"github.com/emdzej/airlock/internal/mount"
)

// Filesystem is one of the format-target choices exposed in the API.
type Filesystem string

const (
	FAT32 Filesystem = "vfat"
	EXFAT Filesystem = "exfat"
	NTFS  Filesystem = "ntfs"
	EXT4  Filesystem = "ext4"
)

// Valid reports whether fs is a supported format target.
func (fs Filesystem) Valid() bool {
	switch fs {
	case FAT32, EXFAT, NTFS, EXT4:
		return true
	}
	return false
}

// Request describes a single format operation.
type Request struct {
	// Parent is the kernel name of the whole-disk device, e.g. "sda".
	// Format always operates at the whole-disk level.
	Parent string
	FS     Filesystem
	Label  string // volume label; validated per-fs by mkfs
	// Release lifts the caller's mount.Manager.BeginOp hold. Format calls
	// it just before the final udev re-trigger so the manager mounts the
	// fresh partition. Must be idempotent (BeginOp's is).
	Release func()
}

// Event is one progress notification streamed to the client. Stage names are
// stable strings the UI can key on for display. On failure Stage is "error"
// and Message carries a human-readable explanation.
type Event struct {
	Stage   string `json:"stage"`
	Message string `json:"message,omitempty"`
}

// Formatter runs format operations against the mount manager.
type Formatter struct {
	mgr *mount.Manager
}

// New returns a Formatter bound to the given mount manager.
func New(mgr *mount.Manager) *Formatter { return &Formatter{mgr: mgr} }

// Format runs a full format operation, calling progress with each stage.
// Returns nil on success, error on the first failing step. The Manager will
// re-mount the new partition via its own udev subscription once we emit the
// final trigger. The caller must hold mgr.BeginOp for req.Parent.
func (f *Formatter) Format(ctx context.Context, req Request, progress func(Event)) error {
	if !req.FS.Valid() {
		return fmt.Errorf("unsupported filesystem: %q", req.FS)
	}
	if !devices.ValidKernelName(req.Parent) {
		return fmt.Errorf("invalid parent device: %q", req.Parent)
	}
	emit := func(stage, msg string) {
		if progress != nil {
			progress(Event{Stage: stage, Message: msg})
		}
	}

	dev := "/dev/" + req.Parent

	release := req.Release
	if release == nil {
		release = func() {}
	}

	// 1. Unmount everything on this device we currently own (the manager
	//    closes the Samba shares first so smbd doesn't hold the device
	//    open). If nothing is mounted (blank drive) that's fine.
	emit("unmount", "unmounting existing partitions on "+dev)
	if err := f.mgr.Eject(req.Parent); err != nil && !errors.Is(err, mount.ErrNotMounted) {
		return fmt.Errorf("unmount %s: %w", dev, err)
	}

	//    Flush all in-flight writes to the block layer. The kernel may
	//     otherwise still be draining dirty pages when we open /dev/<parent>.
	syscall.Sync()

	// 2. Wipe filesystem/partition signatures so `parted` doesn't get
	//    confused by stale data. Retry a few times because the kernel can
	//    take a beat to fully release the device after unmount, especially
	//    if a client only just dropped its handle.
	emit("wipe", "wiping filesystem signatures")
	if err := runCmdRetry(ctx, 5, 300*time.Millisecond, "wipefs", "-a", dev); err != nil {
		return err
	}

	// 3. Create a fresh MBR partition table with one partition spanning the
	//    whole disk. MBR is universally recognized by cameras / consumer
	//    devices; when we add >2TB support later we'll flip to GPT above
	//    that threshold.
	emit("partition", "creating partition table")
	if err := runCmd(ctx, "parted", "--script", dev, "mklabel", "msdos"); err != nil {
		return err
	}
	if err := runCmd(ctx, "parted", "--script", dev, "mkpart", "primary", "1MiB", "100%"); err != nil {
		return err
	}

	// 4. Ask the kernel to re-scan the partition table, then wait for udev
	//    to finish processing so the /dev/<partition> node exists before we
	//    hand it to mkfs.
	emit("rescan", "waiting for kernel + udev to catch up")
	_ = runCmd(ctx, "partprobe", dev)
	_ = runCmd(ctx, "udevadm", "settle")

	partition := partitionPath(req.Parent, 1)

	// 5. Run the appropriate mkfs. Fast/quick variants selected everywhere
	//    (`-Q` for NTFS, lazy init on ext4 is the default).
	emit("mkfs", fmt.Sprintf("creating %s filesystem on %s", req.FS, partition))
	name, args := mkfsCommand(req.FS, req.Label, partition)
	if err := runCmd(ctx, name, args...); err != nil {
		return err
	}

	// 6. Lift the quarantine and force udev to re-emit an ADD/CHANGE event
	//    so the mount manager picks up the new partition with fresh blkid
	//    metadata (FS type, UUID, label). Order matters: the quarantine
	//    must be off *before* we trigger, or the manager will skip the
	//    new mount.
	release()
	emit("rescan", "triggering udev re-scan")
	_ = runCmd(ctx, "udevadm", "trigger", "--action=change", partition)
	_ = runCmd(ctx, "udevadm", "settle")

	emit("done", "format complete — new share should appear shortly")
	return nil
}

// partitionPath returns the /dev path of the Nth partition of the given
// whole-disk kernel name. mmcblk / nvme use a "p" separator; scsi disks
// don't.
func partitionPath(parent string, n int) string {
	base := "/dev/" + parent
	if strings.HasPrefix(parent, "mmcblk") || strings.HasPrefix(parent, "nvme") {
		return fmt.Sprintf("%sp%d", base, n)
	}
	return fmt.Sprintf("%s%d", base, n)
}

// mkfsCommand returns the (executable, args) tuple for the requested fs.
func mkfsCommand(fs Filesystem, label, dev string) (string, []string) {
	switch fs {
	case FAT32:
		args := []string{"-F", "32"}
		if label != "" {
			// FAT32 labels are DOS-style, uppercase, max 11 chars. mkfs.vfat
			// truncates and uppercases for us if we don't; explicit uppercase
			// avoids a surprise.
			args = append(args, "-n", truncate(strings.ToUpper(label), 11))
		}
		return "mkfs.vfat", append(args, dev)
	case EXFAT:
		args := []string{}
		if label != "" {
			args = append(args, "-L", truncate(label, 15))
		}
		return "mkfs.exfat", append(args, dev)
	case NTFS:
		// -f: fast format (don't zero blocks). -Q: quick, no bad-block check.
		args := []string{"-f", "-Q"}
		if label != "" {
			args = append(args, "-L", truncate(label, 32))
		}
		return "mkfs.ntfs", append(args, dev)
	case EXT4:
		args := []string{"-F"}
		if label != "" {
			args = append(args, "-L", truncateBytes(label, 16)) // ext4: 16 bytes
		}
		return "mkfs.ext4", append(args, dev)
	}
	return "", nil
}

// truncate shortens s to at most n characters without splitting a UTF-8
// sequence.
func truncate(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}

// truncateBytes shortens s to at most n bytes, backing off to a rune
// boundary.
func truncateBytes(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}

// runCmd executes cmd with args, wrapping stdout+stderr into any error.
func runCmd(ctx context.Context, cmd string, args ...string) error {
	slog.Debug("format: running", "cmd", cmd, "args", args)
	out, err := exec.CommandContext(ctx, cmd, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s: %w: %s", cmd, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// runCmdRetry runs cmd up to `attempts` times with `delay` between tries.
// Used for wipefs where the kernel may still be releasing the block device
// after an unmount — the failure looks like EBUSY and clears within a
// second.
func runCmdRetry(ctx context.Context, attempts int, delay time.Duration, cmd string, args ...string) error {
	var last error
	for i := 0; i < attempts; i++ {
		if err := runCmd(ctx, cmd, args...); err == nil {
			return nil
		} else {
			last = err
			if ctx.Err() != nil {
				return ctx.Err()
			}
			time.Sleep(delay)
		}
	}
	return last
}
