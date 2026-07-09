// Package mount contains the drive lifecycle: udev event subscription,
// partition enumeration, mounting, and unmounting.
package mount

import "strings"

// Action is the udev action string ("add", "remove", "change", "move", "online",
// "offline", "bind", "unbind").
type Action string

const (
	ActionAdd    Action = "add"
	ActionRemove Action = "remove"
	ActionChange Action = "change"
)

// UEvent is a parsed udev event delivered over NETLINK_KOBJECT_UEVENT.
type UEvent struct {
	Action     Action
	DevPath    string // sysfs path relative to /sys, e.g. /devices/.../block/sda/sda1
	Subsystem  string // e.g. "block", "usb"
	DevType    string // "disk" or "partition" for block devices
	KernelName string // e.g. "sda", "sda1"
	Env        map[string]string
}

// DevNode returns the /dev path for the device, honoring the DEVNAME set by udev.
func (e UEvent) DevNode() string {
	if name := e.Env["DEVNAME"]; name != "" {
		if strings.HasPrefix(name, "/dev/") {
			return name
		}
		return "/dev/" + name
	}
	return "/dev/" + e.KernelName
}

// IsAirlockManaged reports whether this device carries the AIRLOCK_MANAGED
// marker set by our udev rule.
func (e UEvent) IsAirlockManaged() bool { return e.Env["AIRLOCK_MANAGED"] == "1" }
