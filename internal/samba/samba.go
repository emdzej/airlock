// Package samba writes the dynamic share configuration file that the base
// smb.conf `include`s, and asks smbd to reload it. One file is regenerated on
// every mount/unmount — Samba re-reads it without restarting.
package samba

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/emdzej/airlock/internal/mount"
)

// DefaultConfigPath is the file included from /etc/samba/smb.conf.
const DefaultConfigPath = "/etc/samba/smb.conf.d/airlock.conf"

// Owner is the local Unix user/group Samba maps every guest connection to.
// Files created via SMB will appear owned by this account on-disk. On
// filesystems that carry POSIX ownership (ext4, HFS+ under some conditions)
// this user must have read/write access; on FAT/exFAT/NTFS the mount options
// (see mount.DefaultOwnerUID) determine ownership uniformly and this just
// needs to be the *name* of the user whose UID matches.
type Owner struct {
	User  string
	Group string
}

// Writer regenerates the Samba include file and asks smbd to reload.
type Writer struct {
	path  string
	owner Owner
}

// New returns a Writer targeting the given include path and using the given
// owner for `force user` / `force group`. Pass "" for the default include
// path (/etc/samba/smb.conf.d/airlock.conf).
func New(path string, owner Owner) *Writer {
	if path == "" {
		path = DefaultConfigPath
	}
	return &Writer{path: path, owner: owner}
}

// Apply renders the config for snap and writes it atomically to disk, then
// asks smbd to reload. If smbd is not running (e.g. during development), the
// reload error is returned but the file is still written.
func (w *Writer) Apply(snap mount.Snapshot) error {
	body := Render(snap, w.owner)
	if err := writeAtomic(w.path, []byte(body), 0o644); err != nil {
		return fmt.Errorf("write %s: %w", w.path, err)
	}
	return reload()
}

// Render produces the smb.conf fragment for the given drive snapshot. Exposed
// separately from Apply so tests can assert on the output without touching
// the filesystem.
func Render(snap mount.Snapshot, owner Owner) string {
	// Sort by share name so the output is deterministic (helps testing and
	// diffing when debugging).
	drives := append([]mount.Drive(nil), snap.Drives...)
	sort.Slice(drives, func(i, j int) bool { return drives[i].ShareName < drives[j].ShareName })

	var b strings.Builder
	b.WriteString("# Managed by airlockd. Do not edit by hand — changes are overwritten.\n\n")
	for _, d := range drives {
		writeShare(&b, d, owner)
	}
	return b.String()
}

func writeShare(b *strings.Builder, d mount.Drive, owner Owner) {
	label := d.Label
	if label == "" {
		label = d.Kernel
	}
	comment := fmt.Sprintf("%s (%s%s)", label, d.FSType, roSuffix(d.ReadOnly))

	fmt.Fprintf(b, "[%s]\n", d.ShareName)
	fmt.Fprintf(b, "    comment = %s\n", comment)
	fmt.Fprintf(b, "    path = %s\n", d.MountPoint)
	fmt.Fprintf(b, "    browseable = yes\n")
	fmt.Fprintf(b, "    guest ok = yes\n")
	fmt.Fprintf(b, "    guest only = yes\n")
	if d.ReadOnly {
		fmt.Fprintf(b, "    read only = yes\n")
	} else {
		fmt.Fprintf(b, "    read only = no\n")
	}
	fmt.Fprintf(b, "    create mask = 0664\n")
	fmt.Fprintf(b, "    directory mask = 0775\n")
	fmt.Fprintf(b, "    force user = %s\n", owner.User)
	fmt.Fprintf(b, "    force group = %s\n", owner.Group)
	b.WriteString("\n")
}

func roSuffix(ro bool) string {
	if ro {
		return ", read-only"
	}
	return ""
}

// writeAtomic writes data to path via a temp file + rename so smbd never sees
// a half-written config (it re-reads the file on SIGHUP / smbcontrol reload).
func writeAtomic(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".airlock.conf.")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	// Cleanup on any error path below.
	defer func() {
		if tmpPath != "" {
			_ = os.Remove(tmpPath)
		}
	}()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return err
	}
	tmpPath = ""
	return nil
}

// reload asks smbd to re-read its configuration. This is a live reload — no
// restart, no dropped connections. If smbd isn't running (dev laptop, or
// service failed) the error is returned so the caller can log it, but the
// config file has already been persisted.
func reload() error {
	cmd := exec.Command("smbcontrol", "smbd", "reload-config")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("smbcontrol reload-config: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}
