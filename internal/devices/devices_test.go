package devices

import (
	"reflect"
	"testing"
)

func TestSystemMountDevs(t *testing.T) {
	mountinfo := `22 1 179:2 / / rw,noatime shared:1 - ext4 /dev/root rw
23 22 179:1 / /boot/firmware rw,relatime shared:2 - vfat /dev/mmcblk0p1 rw
24 22 0:21 / /proc rw - proc proc rw
30 22 8:1 / /mnt/airlock/kingston rw,nosuid - vfat /dev/sda1 rw
31 22 8:17 / /media/my\040stick rw - exfat /dev/sdb1 rw
32 22 0:40 / /media/root-ro-overlay rw - overlay overlay rw
`
	got := systemMountDevs(mountinfo)
	want := []string{"179:2", "179:1", "8:17"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("systemMountDevs = %v, want %v", got, want)
	}
}

func TestSwapDevs(t *testing.T) {
	swaps := `Filename				Type		Size		Used		Priority
/dev/zram0                              partition	2097148		0		100
/var/swap                               file		2097148		0		-2
/dev/sda2                               partition	1048572		0		-3
`
	if got, want := swapDevs(swaps), []string{"zram0", "sda2"}; !reflect.DeepEqual(got, want) {
		t.Errorf("swapDevs = %v, want %v", got, want)
	}
}

func TestValidKernelName(t *testing.T) {
	for _, ok := range []string{"sda", "sdb1", "mmcblk0", "nvme0n1"} {
		if !ValidKernelName(ok) {
			t.Errorf("ValidKernelName(%q) = false", ok)
		}
	}
	for _, bad := range []string{"", "../sda", "sda/1", "SDA", "sda;rm", "a-very-long-name-that-exceeds-thirty-two"} {
		if ValidKernelName(bad) {
			t.Errorf("ValidKernelName(%q) = true", bad)
		}
	}
}

func TestConvertNodeOptical(t *testing.T) {
	disc := convertNode(lsblkNode{
		Name: "sr0", Type: "rom", Tran: "usb", Size: 4_700_000_000,
		FSType: "iso9660", Label: "DEBIAN", MountPoint: "/mnt/airlock/DEBIAN",
	})
	if !disc.Optical || len(disc.Partitions) != 1 {
		t.Fatalf("got %+v", disc)
	}
	if p := disc.Partitions[0]; p.Name != "sr0" || p.FSType != "iso9660" || p.Label != "DEBIAN" || !p.IsAirlock {
		t.Errorf("disc partition = %+v", p)
	}

	empty := convertNode(lsblkNode{Name: "sr0", Type: "rom", Tran: "usb"})
	if !empty.Optical || len(empty.Partitions) != 0 {
		t.Errorf("empty drive = %+v", empty)
	}
	// A superfloppy USB stick keeps its existing shape.
	if d := convertNode(lsblkNode{Name: "sda", Type: "disk", FSType: "vfat"}); d.Optical || len(d.Partitions) != 0 {
		t.Errorf("disk = %+v", d)
	}
}
