// Package devices enumerates USB-attached block devices — everything airlock
// might want to manage — via `lsblk -bJ`. Unlike internal/mount which only
// tracks currently-mounted shares, this package sees every partition on
// every USB disk, including unmounted ones (unsupported filesystems, blank
// drives, junk sitting between the partitions we do mount).
package devices

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// ErrNotFound is returned by Get / FindPartition when the requested device
// isn't present, isn't USB-attached, or backs the running system.
var ErrNotFound = errors.New("device not found")

// Device is a whole-disk USB block device.
type Device struct {
	Name       string      `json:"name"`  // kernel name, e.g. "sdb"
	Path       string      `json:"path"`  // /dev path, e.g. "/dev/sdb"
	Model      string      `json:"model"` // "DataTraveler 2.0"
	Vendor     string      `json:"vendor"`
	Serial     string      `json:"serial"`
	SizeBytes  int64       `json:"size_bytes"`
	Transport  string      `json:"transport"` // "usb"
	PTType     string      `json:"pt_type"`   // "dos" (MBR), "gpt", "" (none)
	ReadOnly   bool        `json:"read_only"`
	Partitions []Partition `json:"partitions"`
}

// Partition is a single partition on a Device.
type Partition struct {
	Name       string `json:"name"` // e.g. "sdb1"
	SizeBytes  int64  `json:"size_bytes"`
	FSType     string `json:"fs_type"` // "vfat", "ntfs", "iso9660", "" (unformatted)
	Label      string `json:"label"`
	UUID       string `json:"uuid"`
	MountPoint string `json:"mount_point"` // where the kernel has it mounted (empty if not)
	IsAirlock  bool   `json:"is_airlock"`  // true if mounted under /mnt/airlock/
}

// List returns every USB-attached whole-disk device currently visible.
// Non-USB devices (the Pi's own boot media, virtual loop devices) are
// filtered out, and so is any USB disk the running system depends on —
// on a Pi booted from a USB SSD that's the root disk, which must never be
// offered for format / flash / dump.
func List() ([]Device, error) {
	nodes, err := runLsblk()
	if err != nil {
		return nil, err
	}
	system := SystemDisks()
	var out []Device
	for _, n := range nodes {
		if n.Type != "disk" || n.Tran != "usb" || system[n.Name] {
			continue
		}
		out = append(out, convertNode(n))
	}
	return out, nil
}

// Get returns extended info for a single device by kernel name. Returns an
// error if the device isn't present or isn't a USB-attached disk.
func Get(name string) (Device, error) {
	devs, err := List()
	if err != nil {
		return Device{}, err
	}
	for _, d := range devs {
		if d.Name == name {
			return d, nil
		}
	}
	return Device{}, fmt.Errorf("%w: %q (not present, not USB-attached, or in use by the system)", ErrNotFound, name)
}

// FindPartition looks up a partition by kernel name and returns it along
// with its parent device.
func FindPartition(name string) (Device, Partition, error) {
	devs, err := List()
	if err != nil {
		return Device{}, Partition{}, err
	}
	for _, d := range devs {
		for _, p := range d.Partitions {
			if p.Name == name {
				return d, p, nil
			}
		}
	}
	return Device{}, Partition{}, fmt.Errorf("%w: partition %q", ErrNotFound, name)
}

// ValidKernelName defends against a user-supplied device name pointing at
// something unexpected: only lowercase letters + digits (matches "sda",
// "sdb1", "mmcblk0", "nvme0n1", …), so it can't carry a path.
func ValidKernelName(name string) bool {
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

// airlockMountPrefix is where airlockd mounts shares; mounts under it don't
// make a disk a "system" disk.
const airlockMountPrefix = "/mnt/airlock/"

// SystemDisks returns the set of whole-disk kernel names that back a mount
// outside /mnt/airlock (/, /boot/firmware, overlayroot's lower dir, a manual
// mount) or active swap. Those disks are off-limits to every airlock
// operation.
func SystemDisks() map[string]bool {
	out := make(map[string]bool)
	if data, err := os.ReadFile("/proc/self/mountinfo"); err == nil {
		for _, dev := range systemMountDevs(string(data)) {
			for _, d := range diskOf(dev) {
				out[d] = true
			}
		}
	}
	if data, err := os.ReadFile("/proc/swaps"); err == nil {
		for _, name := range swapDevs(string(data)) {
			for _, d := range diskOf(name) {
				out[d] = true
			}
		}
	}
	return out
}

// systemMountDevs parses /proc/self/mountinfo and returns the "major:minor"
// of every block-backed mount outside the airlock tree. The major:minor
// field is used instead of the source column because the latter can be
// "/dev/root" or a label rather than a real device path.
func systemMountDevs(mountinfo string) []string {
	var out []string
	for _, line := range strings.Split(mountinfo, "\n") {
		f := strings.Fields(line)
		if len(f) < 5 {
			continue
		}
		devNum, mp := f[2], unescapeMountinfo(f[4])
		if strings.HasPrefix(devNum, "0:") || strings.HasPrefix(mp+"/", airlockMountPrefix) {
			continue // anonymous (tmpfs, overlay, proc…) or ours
		}
		out = append(out, devNum)
	}
	return out
}

// swapDevs returns the kernel names of block devices in /proc/swaps.
func swapDevs(swaps string) []string {
	var out []string
	for _, line := range strings.Split(swaps, "\n") {
		f := strings.Fields(line)
		if len(f) < 2 || f[1] != "partition" || !strings.HasPrefix(f[0], "/dev/") {
			continue
		}
		out = append(out, strings.TrimPrefix(f[0], "/dev/"))
	}
	return out
}

func unescapeMountinfo(s string) string {
	return strings.NewReplacer(`\040`, " ", `\011`, "\t", `\012`, "\n", `\134`, `\`).Replace(s)
}

// diskOf maps a "major:minor" or kernel name to the whole-disk kernel
// name(s) it lives on, following device-mapper slaves (LVM, dm-crypt).
func diskOf(dev string) []string {
	sysPath := filepath.Join("/sys/class/block", dev)
	if strings.Contains(dev, ":") {
		sysPath = filepath.Join("/sys/dev/block", dev)
	}
	real, err := filepath.EvalSymlinks(sysPath)
	if err != nil {
		return nil
	}
	if slaves, err := os.ReadDir(filepath.Join(real, "slaves")); err == nil && len(slaves) > 0 {
		var out []string
		for _, sl := range slaves {
			out = append(out, diskOf(sl.Name())...)
		}
		return out
	}
	// Partitions live at .../block/<disk>/<part>; disks at .../block/<disk>.
	if _, err := os.Stat(filepath.Join(real, "partition")); err == nil {
		return []string{filepath.Base(filepath.Dir(real))}
	}
	return []string{filepath.Base(real)}
}

// lsblkNode mirrors the JSON output of `lsblk -bJ -o <fields>`. Fields we
// don't consume are omitted; unknown fields are ignored by encoding/json.
type lsblkNode struct {
	Name       string      `json:"name"`
	Path       string      `json:"path"`
	Size       int64       `json:"size"`
	Model      string      `json:"model"`
	Vendor     string      `json:"vendor"`
	Serial     string      `json:"serial"`
	Tran       string      `json:"tran"`
	PTType     string      `json:"pttype"`
	Type       string      `json:"type"`
	FSType     string      `json:"fstype"`
	Label      string      `json:"label"`
	UUID       string      `json:"uuid"`
	MountPoint string      `json:"mountpoint"`
	RO         bool        `json:"ro"`
	Children   []lsblkNode `json:"children"`
}

func runLsblk() ([]lsblkNode, error) {
	// -b: sizes in bytes (numeric JSON, not "16G" strings)
	// -J: JSON output
	// -o: explicit column list (stable across lsblk versions)
	// -e 7,1: exclude loop (major 7) and ram (major 1) devices
	cmd := exec.Command("lsblk",
		"-bJ",
		"-o", "NAME,PATH,SIZE,MODEL,VENDOR,SERIAL,TRAN,PTTYPE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINT,RO",
		"-e", "7,1",
	)
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("lsblk: %w", err)
	}
	var parsed struct {
		BlockDevices []lsblkNode `json:"blockdevices"`
	}
	if err := json.Unmarshal(out, &parsed); err != nil {
		return nil, fmt.Errorf("lsblk parse: %w", err)
	}
	return parsed.BlockDevices, nil
}

func convertNode(n lsblkNode) Device {
	d := Device{
		Name:      n.Name,
		Path:      n.Path,
		Model:     strings.TrimSpace(n.Model),
		Vendor:    strings.TrimSpace(n.Vendor),
		Serial:    strings.TrimSpace(n.Serial),
		SizeBytes: n.Size,
		Transport: n.Tran,
		PTType:    n.PTType,
		ReadOnly:  n.RO,
	}
	for _, c := range n.Children {
		d.Partitions = append(d.Partitions, Partition{
			Name:       c.Name,
			SizeBytes:  c.Size,
			FSType:     c.FSType,
			Label:      c.Label,
			UUID:       c.UUID,
			MountPoint: c.MountPoint,
			IsAirlock:  strings.HasPrefix(c.MountPoint, "/mnt/airlock/"),
		})
	}
	return d
}
