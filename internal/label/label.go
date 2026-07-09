// Package label sets the volume label on a partition. Each supported
// filesystem has its own userspace tool; we shell out to the appropriate
// one after unmounting the partition (some tools refuse online, and even
// those that don't are safer with the volume idle).
package label

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os/exec"
	"regexp"
	"strings"

	"github.com/emdzej/airlock/internal/mount"
)

// ErrUnsupportedFS is returned when the caller asks us to relabel a
// filesystem type we don't have a tool for.
var ErrUnsupportedFS = errors.New("filesystem does not support relabelling")

// ErrInvalidLabel is returned when the label fails per-FS validation
// (length, illegal characters).
var ErrInvalidLabel = errors.New("invalid label")

// Request describes one relabel operation.
type Request struct {
	// Partition is the kernel name of the partition, e.g. "sdb1".
	Partition string
	// Parent is the whole-disk kernel name, used to identify which airlock
	// share (if any) needs to be unmounted first. If empty, we assume
	// Partition is the whole disk (superfloppy).
	Parent string
	// FSType matches the udev/blkid FS_TYPE value: vfat, exfat, ntfs, ext2/3/4.
	FSType string
	// Label is the new label to set. Trimmed and validated per FS.
	Label string
}

// Set validates the request, unmounts any airlock-owned mount for this
// partition, runs the FS-specific tool, then triggers udev so the daemon
// re-mounts the volume under its new label.
func Set(ctx context.Context, mgr *mount.Manager, req Request) error {
	label := strings.TrimSpace(req.Label)
	if err := validateLabel(req.FSType, label); err != nil {
		return err
	}

	dev := "/dev/" + req.Partition

	// If we currently own a mount for this partition, drop it before the
	// tool runs. The parent-based Eject also handles sibling partitions on
	// the same device, which is fine — the udevadm trigger at the end
	// picks them up again.
	if isCurrentlyMounted(mgr, req.Partition) {
		targetParent := req.Parent
		if targetParent == "" {
			targetParent = req.Partition
		}
		if err := mgr.Eject(targetParent); err != nil && !errors.Is(err, mount.ErrNotMounted) {
			return fmt.Errorf("unmount before relabel: %w", err)
		}
	}

	cmd, args := labelCommand(req.FSType, dev, label)
	if cmd == "" {
		return ErrUnsupportedFS
	}
	slog.Info("relabel", "dev", dev, "fs", req.FSType, "label", label)
	if out, err := exec.CommandContext(ctx, cmd, args...).CombinedOutput(); err != nil {
		return fmt.Errorf("%s: %w: %s", cmd, err, strings.TrimSpace(string(out)))
	}

	// Nudge udev so the mount manager picks up the fresh blkid metadata.
	_ = exec.CommandContext(ctx, "udevadm", "trigger", "--action=change", dev).Run()
	_ = exec.CommandContext(ctx, "udevadm", "settle").Run()
	return nil
}

// SupportedForFS reports whether a filesystem type has a relabel tool we
// know how to drive. Used by the API layer to gate the UI.
func SupportedForFS(fs string) bool {
	cmd, _ := labelCommand(fs, "", "")
	return cmd != ""
}

// MaxLenForFS returns the maximum label length for the given filesystem.
// Used by the UI to size the input field and give quick feedback.
func MaxLenForFS(fs string) int {
	switch fs {
	case "vfat", "fat", "fat32", "fat16":
		return 11
	case "exfat":
		return 15
	case "ntfs", "ntfs3":
		return 32
	case "ext2", "ext3", "ext4":
		return 16
	}
	return 0
}

// labelCommand returns the (executable, args) tuple for setting a label on
// the given fs, or ("", nil) if we don't know how.
func labelCommand(fs, dev, label string) (string, []string) {
	switch fs {
	case "vfat", "fat", "fat32", "fat16":
		// fatlabel uppercases automatically, but callers can pass either case.
		return "fatlabel", []string{dev, strings.ToUpper(label)}
	case "exfat":
		return "exfatlabel", []string{dev, label}
	case "ntfs", "ntfs3":
		return "ntfslabel", []string{"--force", dev, label}
	case "ext2", "ext3", "ext4":
		return "e2label", []string{dev, label}
	}
	return "", nil
}

// validateLabel does a quick sanity check before we spawn the tool. The
// tool itself is authoritative — we err on the side of accepting anything
// non-obviously-bad and letting mkfs/fatlabel/etc. reject if needed.
func validateLabel(fs, label string) error {
	if label == "" {
		return fmt.Errorf("%w: empty", ErrInvalidLabel)
	}
	if strings.ContainsAny(label, "\x00/") {
		return fmt.Errorf("%w: contains NUL or slash", ErrInvalidLabel)
	}
	max := MaxLenForFS(fs)
	if max > 0 && len(label) > max {
		return fmt.Errorf("%w: too long for %s (max %d chars)", ErrInvalidLabel, fs, max)
	}
	// FAT is very restrictive on legal characters — the tool will error
	// anyway, but a preflight avoids a confusing shell-output message.
	if isFATish(fs) {
		if !fatLabelPattern.MatchString(strings.ToUpper(label)) {
			return fmt.Errorf("%w: FAT labels allow A-Z 0-9 and space/_-.$~!# only", ErrInvalidLabel)
		}
	}
	return nil
}

func isFATish(fs string) bool {
	switch fs {
	case "vfat", "fat", "fat32", "fat16":
		return true
	}
	return false
}

// fatLabelPattern is intentionally permissive within the DOS 8.3-derived
// legal set; anything not in this pattern is rejected client-side before
// we spawn fatlabel.
var fatLabelPattern = regexp.MustCompile(`^[A-Z0-9 _\-.$~!#]+$`)

// isCurrentlyMounted returns true if the mount manager is holding a mount
// for the given partition kernel name.
func isCurrentlyMounted(mgr *mount.Manager, partition string) bool {
	for _, d := range mgr.Snapshot().Drives {
		if d.Kernel == partition {
			return true
		}
	}
	return false
}
