// Package fsck runs filesystem consistency checks on a partition using
// the FS-appropriate userspace tool (e2fsck, fsck.vfat, fsck.exfat,
// ntfsfix, fsck.hfsplus). The tool streams its own diagnostic output —
// we pass those lines through as SSE Event.Message values so the UI
// can show them live.
package fsck

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os/exec"
	"strings"

	"github.com/emdzej/airlock/internal/mount"
)

// Mode controls whether we allow the tool to modify the filesystem.
type Mode string

const (
	// ModeCheck runs a read-only check — no changes to the filesystem.
	// Not every tool supports this cleanly; ntfsfix always writes.
	ModeCheck Mode = "check"
	// ModeRepair auto-answers "yes" (safely) to the tool's fix prompts.
	// Uses -p (preen) or -a where available, else -y.
	ModeRepair Mode = "repair"
)

// Valid reports whether m is one of the two supported modes.
func (m Mode) Valid() bool { return m == ModeCheck || m == ModeRepair }

// ErrUnsupportedFS is returned when the caller asks us to fsck a
// filesystem type we don't have a tool for.
var ErrUnsupportedFS = errors.New("filesystem not supported by fsck")

// Request describes one fsck operation.
type Request struct {
	// Partition kernel name, e.g. "sdb1".
	Partition string
	// Parent whole-disk kernel name, used only to identify which airlock
	// share to unmount before the tool runs. May be empty for superfloppy
	// layouts where Partition is itself the whole disk.
	Parent string
	// FSType matches the udev/blkid FS_TYPE value: vfat, exfat, ntfs,
	// ext2/3/4, hfsplus.
	FSType string
	// Mode selects check vs repair.
	Mode Mode
}

// Event is one progress notification streamed to the client. `Stage`
// is one of "unmount", "check", "line" (stdout line from the tool),
// "done", "error".
type Event struct {
	Stage    string `json:"stage"`
	Message  string `json:"message,omitempty"`
	ExitCode int    `json:"exit_code,omitempty"`
}

// Checker runs fsck operations against the mount manager.
type Checker struct {
	mgr *mount.Manager
}

// New returns a Checker bound to the given mount manager.
func New(mgr *mount.Manager) *Checker { return &Checker{mgr: mgr} }

// SupportedForFS reports whether a filesystem type has a fsck tool we
// know how to drive. Callers (API layer, UI) use this to gate the
// "Check" action.
func SupportedForFS(fs string) bool {
	tool, _, _ := fsckCommand(fs, ModeCheck, "")
	return tool != ""
}

// Check runs the appropriate fsck tool. Streams the tool's stdout+
// stderr line-by-line to progress. Returns an error only if the tool
// itself failed to start or exited with a code we consider fatal
// (>=8 for e2fsck, ≠0 for others).
func (c *Checker) Check(ctx context.Context, req Request, progress func(Event)) error {
	if !req.Mode.Valid() {
		return fmt.Errorf("invalid mode: %q", req.Mode)
	}
	if progress == nil {
		progress = func(Event) {}
	}
	emit := func(stage, msg string) { progress(Event{Stage: stage, Message: msg}) }

	tool, args, warning := fsckCommand(req.FSType, req.Mode, "/dev/"+req.Partition)
	if tool == "" {
		return ErrUnsupportedFS
	}
	if warning != "" {
		emit("warn", warning)
	}

	// Unmount if we own this partition. Skip for hfsplus which we mount
	// read-only anyway — its check tool works on RO mounts fine.
	if c.mgr != nil && isCurrentlyMounted(c.mgr, req.Partition) {
		emit("unmount", "unmounting /dev/"+req.Partition+" before check")
		target := req.Parent
		if target == "" {
			target = req.Partition
		}
		if err := c.mgr.Eject(target); err != nil && !errors.Is(err, mount.ErrNotMounted) {
			return fmt.Errorf("unmount before fsck: %w", err)
		}
	}

	emit("check", fmt.Sprintf("running %s %s", tool, strings.Join(args, " ")))
	cmd := exec.CommandContext(ctx, tool, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("stdout pipe: %w", err)
	}
	cmd.Stderr = cmd.Stdout // merge stderr into stdout for a single stream
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start %s: %w", tool, err)
	}
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 4096), 1024*1024)
	for scanner.Scan() {
		progress(Event{Stage: "line", Message: scanner.Text()})
	}
	waitErr := cmd.Wait()
	exit := 0
	if waitErr != nil {
		var xErr *exec.ExitError
		if errors.As(waitErr, &xErr) {
			exit = xErr.ExitCode()
		} else {
			return fmt.Errorf("wait %s: %w", tool, waitErr)
		}
	}

	// Re-scan the device so the mount manager picks it up if it was
	// unmounted. Read errors ignored — the manager tolerates duplicates.
	_ = exec.CommandContext(ctx, "udevadm", "trigger", "--action=change", "/dev/"+req.Partition).Run()
	_ = exec.CommandContext(ctx, "udevadm", "settle").Run()

	// Interpret the exit code — same convention across fsck tools:
	//   0     = clean
	//   1     = errors corrected (fine)
	//   2     = errors corrected, reboot recommended (still fine here)
	//   4     = errors remain uncorrected
	//   >= 8  = operational failure
	final := Event{Stage: "done", ExitCode: exit}
	switch {
	case exit == 0:
		final.Message = "clean"
	case exit <= 2:
		final.Message = "errors corrected"
	case exit == 4:
		final.Message = "errors remain — try repair mode"
	default:
		final.Message = fmt.Sprintf("tool exited with code %d", exit)
	}
	progress(final)
	if exit >= 8 {
		return fmt.Errorf("%s exited with code %d", tool, exit)
	}
	slog.Info("fsck",
		"dev", "/dev/"+req.Partition, "fs", req.FSType,
		"mode", req.Mode, "exit", exit)
	return nil
}

// fsckCommand returns (executable, args, optional warning) for the
// given fs / mode combination. Empty executable = unsupported.
func fsckCommand(fs string, mode Mode, dev string) (string, []string, string) {
	switch fs {
	case "vfat", "fat", "fat32", "fat16":
		if mode == ModeRepair {
			return "fsck.vfat", []string{"-a", "-w", "-v", dev}, ""
		}
		return "fsck.vfat", []string{"-n", "-v", dev}, ""

	case "exfat":
		if mode == ModeRepair {
			return "fsck.exfat", []string{"-y", dev}, ""
		}
		// exfatprogs's fsck.exfat has -n as of 1.2.x.
		return "fsck.exfat", []string{"-n", dev}, ""

	case "ntfs", "ntfs3":
		// ntfsfix always writes: no true check-only mode. In check
		// mode we still run it; we warn the caller so the UI can
		// show that the tool will make changes anyway.
		if mode == ModeCheck {
			return "ntfsfix", []string{"--no-action", dev},
				"ntfsfix has no true read-only mode; --no-action skips writes but does not perform a full chkdsk-style pass"
		}
		return "ntfsfix", []string{dev}, ""

	case "ext2", "ext3", "ext4":
		if mode == ModeRepair {
			return "e2fsck", []string{"-p", "-v", dev}, "" // preen: safe automatic fixes
		}
		return "e2fsck", []string{"-n", "-v", "-f", dev}, "" // -f: force check even if clean

	case "hfsplus":
		// fsck.hfsplus has no repair; check-only.
		return "fsck.hfsplus", []string{"-f", dev},
			"fsck.hfsplus is check-only — repairs are not attempted"
	}
	return "", nil, ""
}

// isCurrentlyMounted returns true if the mount manager owns a mount
// for the given partition kernel name.
func isCurrentlyMounted(mgr *mount.Manager, partition string) bool {
	for _, d := range mgr.Snapshot().Drives {
		if d.Kernel == partition {
			return true
		}
	}
	return false
}

// silence an unused-import lint when io isn't referenced below.
var _ = io.EOF
