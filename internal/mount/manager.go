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
	"time"

	"github.com/emdzej/airlock/internal/devices"
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
	"vfat":    true,
	"exfat":   true,
	"ntfs":    true, // kernel ntfs3 driver on 5.15+
	"ntfs3":   true,
	"ext2":    true,
	"ext3":    true,
	"ext4":    true,
	"hfsplus": true, // mounted read-only regardless of the journal state
	"iso9660": true,
	"udf":     true,
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
	Ejecting   bool   // unmount in progress: share withdrawn from Samba

	removed bool // device vanished (udev remove) while an eject was retrying
}

// Snapshot is a point-in-time list of mounted drives.
type Snapshot struct {
	Drives []Drive
}

// Listener is invoked whenever the set of mounted drives changes. Calls are
// serialized and always carry the latest state, so listeners never see an
// older snapshot after a newer one.
type Listener func(Snapshot)

// UnmountHook runs just before a drive is unmounted. main wires it to
// `smbcontrol close-share` so Samba releases its file handles first.
type UnmountHook func(Drive)

// Manager owns the set of currently-mounted airlock drives and drives the
// mount/unmount lifecycle in response to udev events.
type Manager struct {
	baseDir   string
	listener  Listener
	listeners []Listener

	beforeUnmount UnmountHook

	mu       sync.Mutex
	cond     *sync.Cond        // signalled when inflight drops
	drives   map[string]*Drive // key: kernel name
	ops      map[string]string // disk kernel name → running operation
	inflight map[string]int    // disk kernel name → mounts in progress

	notifyMu sync.Mutex // serializes listener calls
}

// ErrBusy is returned when a device already has an operation running, or
// when a filesystem can't be unmounted because something still holds it.
var ErrBusy = errors.New("device busy")

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
	m := &Manager{
		baseDir:  baseDir,
		listener: listener,
		drives:   make(map[string]*Drive),
		ops:      make(map[string]string),
		inflight: make(map[string]int),
	}
	m.cond = sync.NewCond(&m.mu)
	return m, nil
}

// SetUnmountHook installs a callback run before every unmount.
func (m *Manager) SetUnmountHook(h UnmountHook) {
	m.mu.Lock()
	m.beforeUnmount = h
	m.mu.Unlock()
}

// BeginOp claims exclusive use of a whole disk (e.g. "sdb") for a
// long-running operation (format, flash, fsck, relabel, dump). While held,
// the disk is quarantined: udev events for it and its partitions are
// ignored, so the daemon doesn't race to auto-mount a fresh partition
// mid-mkfs. A second BeginOp on the same disk fails with ErrBusy.
//
// BeginOp waits for any mount of the disk that was already in progress, so
// a following Eject is guaranteed to see it. The returned release function
// lifts the quarantine; it is idempotent, so callers can release early
// (before a final udev re-trigger) and still defer it.
func (m *Manager) BeginOp(disk, op string) (release func(), err error) {
	m.mu.Lock()
	if cur, busy := m.ops[disk]; busy {
		m.mu.Unlock()
		return nil, fmt.Errorf("%w: %s in progress on %s", ErrBusy, cur, disk)
	}
	m.ops[disk] = op
	for m.inflight[disk] > 0 {
		m.cond.Wait()
	}
	m.mu.Unlock()
	slog.Info("device quarantined", "disk", disk, "op", op)

	var once sync.Once
	return func() {
		once.Do(func() {
			m.mu.Lock()
			delete(m.ops, disk)
			m.mu.Unlock()
			slog.Info("device unquarantined", "disk", disk, "op", op)
		})
	}, nil
}

// isQuarantinedLocked must be called with m.mu held.
func (m *Manager) isQuarantinedLocked(disk string) bool {
	_, busy := m.ops[disk]
	return busy
}

// IsMounted reports whether airlock currently owns a mount for the given
// kernel name.
func (m *Manager) IsMounted(kernel string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	_, ok := m.drives[kernel]
	return ok
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
		// The device is already gone, so there's nothing left to protect:
		// allow a lazy unmount to release the mount table.
		if err := m.unmount(ev.KernelName, true); err != nil && !errors.Is(err, ErrNotMounted) {
			slog.Error("unmount failed", "kernel", ev.KernelName, "err", err)
		}
	}
}

// ErrNotMounted is returned by Eject / EjectDevice when the target device is
// not currently mounted under airlock's tree.
var ErrNotMounted = errors.New("device not mounted by airlock")

func (m *Manager) mount(ev UEvent) error {
	parent := parentKernel(ev.KernelName)
	devNode := ev.DevNode()
	disk := parent
	if disk == "" {
		disk = ev.KernelName
	}

	// Never touch a disk the running system depends on (a USB-booted Pi's
	// root disk may carry extra, unmounted partitions).
	if devices.SystemDisks()[disk] {
		slog.Info("skipping — disk backs the running system", "dev", devNode, "disk", disk)
		return nil
	}

	// Our own mount generates a follow-up change event; ignore it quietly.
	if m.IsMounted(ev.KernelName) {
		return nil
	}
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
	if m.isQuarantinedLocked(disk) {
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
	// Register the in-flight mount so a concurrent BeginOp waits for it to
	// land in m.drives (and thus be ejected) before touching the disk.
	m.inflight[disk]++
	m.mu.Unlock()
	defer func() {
		m.mu.Lock()
		if m.inflight[disk]--; m.inflight[disk] <= 0 {
			delete(m.inflight, disk)
		}
		m.cond.Broadcast()
		m.mu.Unlock()
	}()

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
		SizeBytes:  DeviceSize(ev.KernelName),
	}

	m.mu.Lock()
	m.drives[ev.KernelName] = d
	m.mu.Unlock()

	m.notify()
	return nil
}

// unmountRetries × unmountDelay bounds how long we wait for a filesystem
// to become idle (e.g. smbd releasing handles after close-share).
const (
	unmountRetries = 10
	unmountDelay   = 300 * time.Millisecond
)

// unmount releases the airlock mount for kernel. The drive stays in the
// published state until the unmount has actually succeeded, so the UI and
// LED never claim "safe to remove" while data may still be in flight.
//
// A busy filesystem returns ErrBusy after a few retries. Only when the
// device has already been physically removed (lazy=true) do we fall back
// to `umount -l` — then there's nothing left to flush.
func (m *Manager) unmount(kernel string, lazy bool) error {
	m.mu.Lock()
	d, ok := m.drives[kernel]
	if ok && d.Ejecting && lazy {
		// A busy eject is still retrying and the user pulled the drive.
		// Tell that loop to give up and lazily release the mount;
		// otherwise the entry would linger and block the next insert.
		d.removed = true
		m.mu.Unlock()
		return nil
	}
	if !ok || d.Ejecting {
		m.mu.Unlock()
		return ErrNotMounted
	}
	d.Ejecting = true
	drive := *d
	hook := m.beforeUnmount
	m.mu.Unlock()

	// Publish the Ejecting state first: the Samba writer drops the share
	// from its config, so clients (macOS auto-reconnects eagerly) can't
	// re-open it between close-share and umount.
	m.notify()
	if hook != nil && !lazy {
		hook(drive)
	}

	slog.Info("unmounting", "mp", drive.MountPoint)
	var lastErr error
	for i := 0; i < unmountRetries; i++ {
		out, err := exec.Command("/bin/umount", drive.MountPoint).CombinedOutput()
		if err == nil || !isDeviceMountedAt(drive.MountPoint) {
			lastErr = nil
			break
		}
		lastErr = fmt.Errorf("umount %s: %w: %s", drive.MountPoint, err, strings.TrimSpace(string(out)))
		if lazy || m.wasRemoved(kernel) {
			lazy = true
			break
		}
		time.Sleep(unmountDelay)
	}
	if lastErr != nil && lazy {
		if out, err := exec.Command("/bin/umount", "-l", drive.MountPoint).CombinedOutput(); err != nil {
			slog.Warn("lazy umount failed", "mp", drive.MountPoint,
				"err", err, "out", strings.TrimSpace(string(out)))
		}
		lastErr = nil
	}
	if lastErr != nil {
		slog.Warn("unmount refused — filesystem busy", "mp", drive.MountPoint, "err", lastErr)
		m.mu.Lock()
		if d, ok := m.drives[kernel]; ok {
			d.Ejecting = false
		}
		m.mu.Unlock()
		m.notify()
		return fmt.Errorf("%w: %s is still in use (close open files and retry)", ErrBusy, drive.ShareName)
	}
	_ = os.Remove(drive.MountPoint) // rmdir; ignore errors

	m.mu.Lock()
	delete(m.drives, kernel)
	m.mu.Unlock()
	m.notify()
	return nil
}

// wasRemoved reports whether a udev remove arrived for kernel while its
// eject was in progress.
func (m *Manager) wasRemoved(kernel string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	d, ok := m.drives[kernel]
	return ok && d.removed
}

// UnmountPartition safely unmounts a single airlock-owned partition,
// leaving its siblings on the same disk mounted.
func (m *Manager) UnmountPartition(kernel string) error {
	return m.unmount(kernel, false)
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
		return ErrNotMounted
	}
	var errs []error
	for _, k := range targets {
		if err := m.unmount(k, false); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

// EjectAll unmounts every currently-mounted drive. Drives that are still
// busy stay mounted; their errors are joined into the result.
func (m *Manager) EjectAll() error {
	m.mu.Lock()
	kernels := make([]string, 0, len(m.drives))
	for k := range m.drives {
		kernels = append(kernels, k)
	}
	m.mu.Unlock()

	var errs []error
	for _, k := range kernels {
		if err := m.unmount(k, false); err != nil && !errors.Is(err, ErrNotMounted) {
			slog.Warn("unmount during eject-all", "kernel", k, "err", err)
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

// notify delivers the current state to every listener. The snapshot is
// taken inside the serialized section, so concurrent changes (udev loop,
// HTTP handlers, the GPIO button) can't deliver snapshots out of order —
// the last call always publishes the latest state.
func (m *Manager) notify() {
	m.notifyMu.Lock()
	defer m.notifyMu.Unlock()
	snap := m.Snapshot()
	m.mu.Lock()
	listeners := append([]Listener(nil), m.listeners...)
	m.mu.Unlock()
	if m.listener != nil {
		m.listener(snap)
	}
	for _, l := range listeners {
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
	// A drive labelled "GLOBAL" must not become Samba's [global] section
	// (or any other reserved one) in the include file.
	if reservedShareNames[base] {
		base += "-" + kernel
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

// reservedShareNames are smb.conf section names with special meaning.
var reservedShareNames = map[string]bool{
	"global": true, "homes": true, "printers": true, "print": true, "ipc": true,
}

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

// normalizeFS maps udev/blkid-reported filesystem names to the mount(8) -t
// argument we actually want. The important case is NTFS: we prefer the
// in-kernel `ntfs3` driver over the userspace `ntfs-3g` FUSE mount.
func normalizeFS(fs string) string {
	switch fs {
	case "ntfs":
		return "ntfs3"
	case "fat", "fat16", "fat32":
		return "vfat"
	default:
		return fs
	}
}

// IsSupported reports whether airlockd will mount a filesystem type as
// reported by udev or lsblk (accepts aliases like "fat32" and "ntfs3").
func IsSupported(fs string) bool {
	return fs != "" && SupportedFilesystems[normalizeFS(fs)]
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

// isDeviceMountedAt reports whether mp is still a mount point.
func isDeviceMountedAt(mp string) bool {
	data, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if len(f) >= 5 && f[4] == mp {
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
func parentKernel(kernel string) string {
	// Strip a trailing partition suffix from `kernel`.
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
	return parent
}
