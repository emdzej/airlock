package mount

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
)

// DefaultBaseDir is where per-drive mount points are created.
const DefaultBaseDir = "/mnt/airlock"

// DefaultOwnerUID/GID are the ownership numbers applied to mount options on
// filesystems that don't carry POSIX ownership (vfat/exfat/ntfs/hfsplus). This
// is the UID of the `airlock` user created by pi-gen (first user, uid 1000).
const (
	DefaultOwnerUID = 1000
	DefaultOwnerGID = 1000
)

// SupportedFilesystems lists filesystems airlockd will mount. Others are
// ignored (logged, not mounted).
var SupportedFilesystems = map[string]bool{
	"vfat":     true,
	"exfat":    true,
	"ntfs":     true, // kernel ntfs3 driver on 5.15+
	"ntfs3":    true,
	"ext2":     true,
	"ext3":     true,
	"ext4":     true,
	"hfsplus":  true, // mounted read-only regardless of the journal state
	"iso9660":  true,
	"udf":      true,
}

// Drive is one mounted filesystem on the appliance.
type Drive struct {
	Kernel     string // "sda1"
	Parent     string // "sda"  — whole-disk kernel name, empty if device is itself the fs
	DevNode    string // "/dev/sda1"
	Label      string // filesystem label from udev, if any
	UUID       string // filesystem UUID
	FSType     string // "vfat", "exfat", ...
	ReadOnly   bool   // media forced read-only (WP switch, RO filesystem)
	MountPoint string // "/mnt/airlock/kingston"
	ShareName  string // last path component of MountPoint — used by Samba
	SizeBytes  int64  // 0 if unknown
}

// Snapshot is a point-in-time list of mounted drives.
type Snapshot struct {
	Drives []Drive
}

// Listener is invoked on the caller's goroutine whenever the set of mounted
// drives changes. Called with the mutex released.
type Listener func(Snapshot)

// Manager owns the set of currently-mounted airlock drives and drives the
// mount/unmount lifecycle in response to udev events.
type Manager struct {
	baseDir   string
	listener  Listener
	listeners []Listener

	mu         sync.Mutex
	drives     map[string]*Drive // key: kernel name
	quarantine map[string]bool   // parent kernel names to ignore events for
}

// AddListener registers an additional callback fired after each mount
// state change. Complements the primary Listener passed to NewManager
// so consumers (e.g. the SSE broadcaster) can subscribe without
// wrapping every other listener.
func (m *Manager) AddListener(l Listener) {
	m.mu.Lock()
	m.listeners = append(m.listeners, l)
	m.mu.Unlock()
}

// NewManager returns a Manager writing mount points under baseDir. baseDir is
// created (mode 0755) if it doesn't exist.
func NewManager(baseDir string, listener Listener) (*Manager, error) {
	if baseDir == "" {
		baseDir = DefaultBaseDir
	}
	if err := os.MkdirAll(baseDir, 0o755); err != nil {
		return nil, fmt.Errorf("mkdir base dir: %w", err)
	}
	return &Manager{
		baseDir:    baseDir,
		listener:   listener,
		drives:     make(map[string]*Drive),
		quarantine: make(map[string]bool),
	}, nil
}

// Quarantine marks a whole-disk kernel name (e.g. "sdb") as off-limits: the
// event handler will skip both the parent and any of its partitions until
// Unquarantine is called. Used during format so the daemon does not race to
// auto-mount the fresh partition before mkfs runs on it.
func (m *Manager) Quarantine(parent string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.quarantine[parent] = true
	slog.Info("device quarantined", "parent", parent)
}

// Unquarantine releases a Quarantine hold. Idempotent.
func (m *Manager) Unquarantine(parent string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.quarantine, parent)
	slog.Info("device unquarantined", "parent", parent)
}

// isQuarantinedLocked must be called with m.mu held.
func (m *Manager) isQuarantinedLocked(parent, kernel string) bool {
	if parent != "" && m.quarantine[parent] {
		return true
	}
	return m.quarantine[kernel]
}

// Recover cleans up any leftover mount points under baseDir from a previous
// daemon run. It force-unmounts (lazy) and removes each subdirectory. Call
// before subscribing to udev so we start from a known-empty state; then
// ReplayUdev to re-fire ADD events for currently-attached devices.
func (m *Manager) Recover() {
	entries, err := os.ReadDir(m.baseDir)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			slog.Warn("recover: read base dir", "err", err)
		}
		return
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		mp := filepath.Join(m.baseDir, e.Name())
		slog.Info("recover: unmounting stale mount", "mp", mp)
		if out, err := exec.Command("/bin/umount", "-l", mp).CombinedOutput(); err != nil {
			slog.Warn("recover: umount failed", "mp", mp,
				"err", err, "out", strings.TrimSpace(string(out)))
		}
		if err := os.Remove(mp); err != nil && !errors.Is(err, os.ErrNotExist) {
			slog.Warn("recover: rmdir failed", "mp", mp, "err", err)
		}
	}
}

// ReplayUdev asks the kernel to re-emit ADD events for all block devices, so
// the netlink watcher sees currently-attached drives after a daemon restart.
// Runs `udevadm trigger`; a failure is logged but not returned.
func (m *Manager) ReplayUdev() {
	cmd := exec.Command("udevadm", "trigger", "--action=add", "--subsystem-match=block")
	if out, err := cmd.CombinedOutput(); err != nil {
		slog.Warn("udevadm trigger failed", "err", err, "out", strings.TrimSpace(string(out)))
		return
	}
	slog.Info("udevadm trigger fired for block devices")
}

// Snapshot returns the current set of mounted drives.
func (m *Manager) Snapshot() Snapshot {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Drive, 0, len(m.drives))
	for _, d := range m.drives {
		out = append(out, *d)
	}
	return Snapshot{Drives: out}
}

// Run consumes udev events from events until ctx is done. On shutdown it does
// not automatically unmount drives — that is the caller's decision (via
// EjectAll) so a systemctl stop doesn't yank users' data mid-write.
func (m *Manager) Run(ctx context.Context, events <-chan UEvent) {
	for {
		select {
		case <-ctx.Done():
			return
		case ev, ok := <-events:
			if !ok {
				return
			}
			m.handle(ev)
		}
	}
}

func (m *Manager) handle(ev UEvent) {
	if ev.Subsystem != "block" || !ev.IsAirlockManaged() {
		return
	}
	switch ev.Action {
	case ActionAdd, ActionChange:
		// We mount a device only when it has a supported filesystem. A whole
		// disk with a partition table will emit change/add events for its
		// partitions separately; ignore the disk-level add unless the disk
		// itself carries a filesystem ("superfloppy" layout, no partition table).
		fs := ev.Env["ID_FS_TYPE"]
		usage := ev.Env["ID_FS_USAGE"]
		if fs == "" || (usage != "" && usage != "filesystem") {
			return
		}
		if !SupportedFilesystems[fs] {
			slog.Info("skipping unsupported filesystem", "dev", ev.DevNode(), "fs", fs)
			return
		}
		if err := m.mount(ev); err != nil {
			slog.Error("mount failed", "dev", ev.DevNode(), "err", err)
		}
	case ActionRemove:
		if err := m.unmount(ev.KernelName); err != nil && !errors.Is(err, errNotMounted) {
			slog.Error("unmount failed", "kernel", ev.KernelName, "err", err)
		}
	}
}

// ErrNotMounted is returned by Eject / EjectDevice when the target device is
// not currently mounted under airlock's tree.
var ErrNotMounted = errors.New("device not mounted by airlock")

// keep the old name for existing internal callers
var errNotMounted = ErrNotMounted

func (m *Manager) mount(ev UEvent) error {
	parent := parentKernel(ev.DevPath, ev.KernelName)
	devNode := ev.DevNode()

	// Belt-and-suspenders: never mount a block device that is already visible
	// to the kernel at some other mount point. This is the guard against
	// re-mounting the Pi's own boot media if the udev rule ever misfires,
	// and against fighting a user's manual mount.
	if isDeviceMounted(devNode) {
		slog.Info("skipping — device already mounted elsewhere",
			"dev", devNode, "kernel", ev.KernelName)
		return nil
	}

	m.mu.Lock()
	if _, already := m.drives[ev.KernelName]; already {
		m.mu.Unlock()
		return nil
	}
	// Skip devices under quarantine (e.g. mid-format).
	if m.isQuarantinedLocked(parent, ev.KernelName) {
		m.mu.Unlock()
		slog.Info("skipping — device is quarantined",
			"dev", devNode, "kernel", ev.KernelName, "parent", parent)
		return nil
	}
	// Hybrid ISO / superfloppy: if the parent whole-disk itself is mounted as
	// a filesystem, its partitions all point at overlapping storage the kernel
	// has open exclusively — trying to mount them here fails with EBUSY /
	// "Can't open blockdev". Skip.
	if parent != "" {
		if _, parentMounted := m.drives[parent]; parentMounted {
			m.mu.Unlock()
			slog.Info("skipping partition — parent whole-disk already mounted",
				"dev", devNode, "parent", parent)
			return nil
		}
	}
	m.mu.Unlock()

	fs := normalizeFS(ev.Env["ID_FS_TYPE"])
	label := ev.Env["ID_FS_LABEL"]
	if label == "" {
		label = ev.Env["ID_FS_LABEL_ENC"]
	}
	readOnly := isReadOnly(ev.KernelName)

	name := m.reserveName(label, ev.KernelName)
	mp := filepath.Join(m.baseDir, name)
	if err := os.MkdirAll(mp, 0o755); err != nil {
		return fmt.Errorf("mkdir mount point: %w", err)
	}

	opts := mountOptions(fs, readOnly)
	args := []string{"-t", fs, "-o", opts, ev.DevNode(), mp}
	slog.Info("mounting", "dev", ev.DevNode(), "fs", fs, "mp", mp, "ro", readOnly)
	if out, err := exec.Command("/bin/mount", args...).CombinedOutput(); err != nil {
		_ = os.Remove(mp)
		return fmt.Errorf("mount %s: %w: %s", ev.DevNode(), err, strings.TrimSpace(string(out)))
	}

	d := &Drive{
		Kernel:     ev.KernelName,
		Parent:     parent,
		DevNode:    ev.DevNode(),
		Label:      label,
		UUID:       ev.Env["ID_FS_UUID"],
		FSType:     fs,
		ReadOnly:   readOnly,
		MountPoint: mp,
		ShareName:  name,
		SizeBytes:  deviceSize(ev.KernelName),
	}

	m.mu.Lock()
	m.drives[ev.KernelName] = d
	snap := m.snapshotLocked()
	m.mu.Unlock()

	m.notify(snap)
	return nil
}

func (m *Manager) unmount(kernel string) error {
	m.mu.Lock()
	d, ok := m.drives[kernel]
	if !ok {
		m.mu.Unlock()
		return errNotMounted
	}
	delete(m.drives, kernel)
	snap := m.snapshotLocked()
	m.mu.Unlock()

	slog.Info("unmounting", "mp", d.MountPoint)
	// Try clean unmount first; if the device is already gone the kernel has
	// already torn down the mount and umount will fail — that's fine.
	if out, err := exec.Command("/bin/umount", d.MountPoint).CombinedOutput(); err != nil {
		// Fallback to lazy unmount so we at least release the mount table.
		if out2, err2 := exec.Command("/bin/umount", "-l", d.MountPoint).CombinedOutput(); err2 != nil {
			slog.Warn("umount failed", "mp", d.MountPoint,
				"err", err, "out", strings.TrimSpace(string(out)),
				"err_lazy", err2, "out_lazy", strings.TrimSpace(string(out2)))
		}
	}
	_ = os.Remove(d.MountPoint) // rmdir; ignore errors (busy, still mounted, etc)

	m.notify(snap)
	return nil
}

// Eject unmounts a whole disk and all its partition mounts. It is the safe
// action to take before a user physically removes a drive.
func (m *Manager) Eject(parent string) error {
	m.mu.Lock()
	var targets []string
	for k, d := range m.drives {
		if d.Kernel == parent || d.Parent == parent {
			targets = append(targets, k)
		}
	}
	m.mu.Unlock()

	if len(targets) == 0 {
		return errNotMounted
	}
	var firstErr error
	for _, k := range targets {
		if err := m.unmount(k); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

// EjectAll unmounts every currently-mounted drive.
func (m *Manager) EjectAll() {
	m.mu.Lock()
	kernels := make([]string, 0, len(m.drives))
	for k := range m.drives {
		kernels = append(kernels, k)
	}
	m.mu.Unlock()

	for _, k := range kernels {
		if err := m.unmount(k); err != nil {
			slog.Warn("unmount during eject-all", "kernel", k, "err", err)
		}
	}
}

func (m *Manager) snapshotLocked() Snapshot {
	out := make([]Drive, 0, len(m.drives))
	for _, d := range m.drives {
		out = append(out, *d)
	}
	return Snapshot{Drives: out}
}

func (m *Manager) notify(snap Snapshot) {
	if m.listener != nil {
		m.listener(snap)
	}
	// Copy the slice under lock so callback code doesn't hold the mutex.
	m.mu.Lock()
	extra := append([]Listener(nil), m.listeners...)
	m.mu.Unlock()
	for _, l := range extra {
		l(snap)
	}
}

// reserveName picks a mount-point directory name for a new drive, preferring
// a sanitized filesystem label and falling back to the kernel name. On
// collisions with an already-mounted drive, a -N suffix is appended.
func (m *Manager) reserveName(label, kernel string) string {
	base := sanitizeName(label)
	if base == "" {
		base = kernel
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	inUse := make(map[string]bool, len(m.drives))
	for _, d := range m.drives {
		inUse[d.ShareName] = true
	}
	if !inUse[base] {
		return base
	}
	for i := 2; ; i++ {
		candidate := fmt.Sprintf("%s-%d", base, i)
		if !inUse[candidate] {
			return candidate
		}
	}
}

var nameSanitizer = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

// sanitizeName reduces a filesystem label to something usable as a directory
// and Samba share name: lowercased, non-alnum collapsed to '-', trimmed.
func sanitizeName(label string) string {
	s := strings.ToLower(strings.TrimSpace(label))
	s = nameSanitizer.ReplaceAllString(s, "-")
	s = strings.Trim(s, "-._")
	if len(s) > 32 {
		s = s[:32]
	}
	return s
}

// normalizeFS maps udev-reported filesystem names to the mount(8) -t argument
// we actually want. The important case is NTFS: we prefer the in-kernel
// `ntfs3` driver over the userspace `ntfs-3g` FUSE mount.
func normalizeFS(fs string) string {
	switch fs {
	case "ntfs":
		return "ntfs3"
	default:
		return fs
	}
}

// mountOptions returns a comma-separated options string for the given fs.
// Safety options (nosuid,nodev,noexec) are applied uniformly — removable media
// should not be able to inject setuid binaries or device nodes.
func mountOptions(fs string, ro bool) string {
	base := []string{"nosuid", "nodev", "noexec"}
	if ro {
		base = append(base, "ro")
	}
	uid := strconv.Itoa(DefaultOwnerUID)
	gid := strconv.Itoa(DefaultOwnerGID)

	switch fs {
	case "vfat":
		base = append(base, "uid="+uid, "gid="+gid, "umask=0002", "iocharset=utf8", "shortname=mixed", "flush")
	case "exfat":
		base = append(base, "uid="+uid, "gid="+gid, "iocharset=utf8", "errors=remount-ro")
	case "ntfs3":
		base = append(base, "uid="+uid, "gid="+gid, "iocharset=utf8", "windows_names")
	case "hfsplus":
		// Kernel driver refuses RW when the HFS+ journal is enabled. Rather
		// than probe and pick, we always mount HFS+ read-only for MVP.
		if !ro {
			base = append(base, "ro")
		}
		base = append(base, "uid="+uid, "gid="+gid, "nls=utf8")
	case "iso9660", "udf":
		if !ro {
			base = append(base, "ro")
		}
	case "ext2", "ext3", "ext4":
		base = append(base, "acl", "user_xattr")
	}
	return strings.Join(base, ",")
}

// isDeviceMounted returns true if devNode is the source of any mount visible
// in /proc/self/mountinfo. Cheap linear scan; the file is a few KB.
func isDeviceMounted(devNode string) bool {
	data, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(data), "\n") {
		// Format: ... " - " fstype source super_options
		sep := strings.Index(line, " - ")
		if sep < 0 {
			continue
		}
		fields := strings.Fields(line[sep+3:])
		if len(fields) < 2 {
			continue
		}
		if fields[1] == devNode {
			return true
		}
	}
	return false
}

// isReadOnly consults /sys/block/.../ro to see whether the kernel has marked
// the block device read-only (e.g. because the SD card's WP switch tripped, or
// the reader reported RO at attach). Returns false on any error.
func isReadOnly(kernel string) bool {
	// Partition RO status lives under the parent disk's /sys tree.
	// /sys/class/block/<name>/ro exists for both disks and partitions.
	data, err := os.ReadFile(filepath.Join("/sys/class/block", kernel, "ro"))
	if err != nil {
		return false
	}
	return strings.TrimSpace(string(data)) == "1"
}

// deviceSize reads /sys/class/block/<name>/size (in 512-byte sectors) and
// returns the size in bytes. Returns 0 on error.
func deviceSize(kernel string) int64 {
	return DeviceSize(kernel)
}

// DeviceSize returns the size of a block device (whole disk or partition)
// in bytes, or 0 if the device isn't present or /sys can't be read.
func DeviceSize(kernel string) int64 {
	data, err := os.ReadFile(filepath.Join("/sys/class/block", kernel, "size"))
	if err != nil {
		return 0
	}
	sectors, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	if err != nil {
		return 0
	}
	return sectors * 512
}

// parentKernel infers the whole-disk kernel name for a partition. For sda1 the
// parent is sda; for mmcblk0p1 the parent is mmcblk0. Returns "" if the device
// is itself a whole disk.
func parentKernel(devPath, kernel string) string {
	// The udev DEVPATH ends in .../block/<parent>/<partition> for partitions.
	// Cheap approach: strip a trailing partition suffix from `kernel`.
	if strings.HasPrefix(kernel, "mmcblk") {
		if i := strings.Index(kernel, "p"); i > len("mmcblk") {
			return kernel[:i]
		}
		return ""
	}
	// sd*: strip trailing digits.
	i := len(kernel)
	for i > 0 && kernel[i-1] >= '0' && kernel[i-1] <= '9' {
		i--
	}
	if i == len(kernel) {
		return ""
	}
	// Guard: sanity check that the parent block device actually exists;
	// otherwise return "" so callers treat this device as its own disk.
	parent := kernel[:i]
	if _, err := os.Stat(filepath.Join("/sys/class/block", parent)); err != nil {
		return ""
	}
	_ = devPath
	return parent
}
