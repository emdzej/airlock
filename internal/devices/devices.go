// Package devices enumerates USB-attached block devices — everything airlock
// might want to manage — via `lsblk -bJ`. Unlike internal/mount which only
// tracks currently-mounted shares, this package sees every partition on
// every USB disk, including unmounted ones (unsupported filesystems, blank
// drives, junk sitting between the partitions we do mount).
package devices

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
)

// Device is a whole-disk USB block device.
type Device struct {
	Name       string      `json:"name"`        // kernel name, e.g. "sdb"
	Path       string      `json:"path"`        // /dev path, e.g. "/dev/sdb"
	Model      string      `json:"model"`       // "DataTraveler 2.0"
	Vendor     string      `json:"vendor"`
	Serial     string      `json:"serial"`
	SizeBytes  int64       `json:"size_bytes"`
	Transport  string      `json:"transport"`   // "usb"
	PTType     string      `json:"pt_type"`     // "dos" (MBR), "gpt", "" (none)
	ReadOnly   bool        `json:"read_only"`
	Partitions []Partition `json:"partitions"`
}

// Partition is a single partition on a Device.
type Partition struct {
	Name       string `json:"name"`        // e.g. "sdb1"
	SizeBytes  int64  `json:"size_bytes"`
	FSType     string `json:"fs_type"`     // "vfat", "ntfs", "iso9660", "" (unformatted)
	Label      string `json:"label"`
	UUID       string `json:"uuid"`
	MountPoint string `json:"mount_point"` // where the kernel has it mounted (empty if not)
	IsAirlock  bool   `json:"is_airlock"`  // true if mounted under /mnt/airlock/
}

// List returns every USB-attached whole-disk device currently visible.
// Non-USB devices (the Pi's own boot media, virtual loop devices) are
// filtered out.
func List() ([]Device, error) {
	nodes, err := runLsblk()
	if err != nil {
		return nil, err
	}
	var out []Device
	for _, n := range nodes {
		if n.Type != "disk" || n.Tran != "usb" {
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
	return Device{}, fmt.Errorf("device %q not found (not present or not USB-attached)", name)
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
