package burn

import (
	"fmt"
	"os"
	"syscall"
	"time"
)

// ioctls from <linux/cdrom.h> and <linux/fs.h>.
const (
	cdromEject     = 0x5309
	cdromCloseTray = 0x5319
	blkFlsBuf      = 0x1261
)

// EjectTray opens the drive's tray (the kernel unlocks the door first).
func EjectTray(dev string) error {
	return trayIoctl(dev, cdromEject)
}

// reloadTray ejects and closes the tray, so the kernel re-reads the disc:
// its size and contents after a burn.
func reloadTray(dev string) error {
	if err := trayIoctl(dev, cdromEject); err != nil {
		return err
	}
	time.Sleep(2 * time.Second)
	return trayIoctl(dev, cdromCloseTray)
}

func trayIoctl(dev string, req uintptr) error {
	// O_NONBLOCK: open the drive even with no disc (or a blank one) in it.
	f, err := os.OpenFile(dev, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), req, 0); errno != 0 {
		return fmt.Errorf("ioctl %#x on %s: %w", req, dev, errno)
	}
	return nil
}

// flushBuffers drops the kernel's cached blocks of the device, so a read
// after the burn sees the disc, not what was cached before it.
func flushBuffers(f *os.File) {
	_, _, _ = syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), blkFlsBuf, 0)
}
