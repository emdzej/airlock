//go:build linux

package mount

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"syscall"
)

// WatchUEvents subscribes to udev-processed events on netlink group 2 and
// delivers them on the returned channel until ctx is cancelled. shutdown(2)
// doesn't unblock recvfrom on a netlink socket, so the socket has a 1 s
// receive timeout and the loop re-checks ctx on each timeout.
func WatchUEvents(ctx context.Context) (<-chan UEvent, error) {
	fd, err := syscall.Socket(syscall.AF_NETLINK, syscall.SOCK_RAW, syscall.NETLINK_KOBJECT_UEVENT)
	if err != nil {
		return nil, fmt.Errorf("netlink socket: %w", err)
	}
	// Group 2 = udev-processed events (ENV{...} assignments from rules are
	// applied). Group 1 would give raw kernel uevents without our rule's
	// AIRLOCK_MANAGED tag.
	sa := &syscall.SockaddrNetlink{Family: syscall.AF_NETLINK, Groups: 2}
	if err := syscall.Bind(fd, sa); err != nil {
		_ = syscall.Close(fd)
		return nil, fmt.Errorf("netlink bind: %w", err)
	}
	tv := syscall.Timeval{Sec: 1}
	if err := syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv); err != nil {
		_ = syscall.Close(fd)
		return nil, fmt.Errorf("netlink SO_RCVTIMEO: %w", err)
	}

	out := make(chan UEvent, 32)
	go func() {
		defer close(out)
		defer syscall.Close(fd)

		buf := make([]byte, 1<<16)
		for {
			if ctx.Err() != nil {
				return
			}
			n, _, err := syscall.Recvfrom(fd, buf, 0)
			if err != nil {
				if errors.Is(err, syscall.EAGAIN) || errors.Is(err, syscall.EINTR) {
					continue // receive timeout: re-check ctx
				}
				if errors.Is(err, syscall.EBADF) || errors.Is(err, syscall.EINVAL) {
					return
				}
				slog.Warn("netlink recv error", "err", err)
				continue
			}
			ev, ok := parseUEvent(buf[:n])
			if !ok {
				continue
			}
			select {
			case out <- ev:
			case <-ctx.Done():
				return
			}
		}
	}()
	return out, nil
}

// parseUEvent parses one netlink datagram. Group-2 messages carry libudev's
// monitor header; group-1 (kernel) messages start with "ACTION@DEVPATH\0".
// We handle both defensively even though we only bind to group 2.
func parseUEvent(msg []byte) (UEvent, bool) {
	var payload []byte
	if len(msg) >= 40 && string(msg[:8]) == "libudev\x00" {
		// struct udev_monitor_netlink_header:
		//   [0..8)   "libudev\0"
		//   [8..12)  magic (network byte order, unused here)
		//   [12..16) header_size
		//   [16..20) properties_off
		//   [20..24) properties_len
		//   ... filter fields ...
		off := binary.LittleEndian.Uint32(msg[16:20])
		if int(off) > len(msg) {
			return UEvent{}, false
		}
		payload = msg[off:]
	} else {
		nul := -1
		for i, c := range msg {
			if c == 0 {
				nul = i
				break
			}
		}
		if nul < 0 {
			return UEvent{}, false
		}
		payload = msg[nul+1:]
	}

	ev := UEvent{Env: make(map[string]string)}
	for _, part := range strings.Split(strings.TrimRight(string(payload), "\x00"), "\x00") {
		if part == "" {
			continue
		}
		eq := strings.IndexByte(part, '=')
		if eq < 0 {
			continue
		}
		k, v := part[:eq], part[eq+1:]
		ev.Env[k] = v
		switch k {
		case "ACTION":
			ev.Action = Action(v)
		case "DEVPATH":
			ev.DevPath = v
		case "SUBSYSTEM":
			ev.Subsystem = v
		case "DEVTYPE":
			ev.DevType = v
		case "KERNEL":
			ev.KernelName = v
		}
	}
	if ev.KernelName == "" && ev.DevPath != "" {
		if slash := strings.LastIndexByte(ev.DevPath, '/'); slash >= 0 {
			ev.KernelName = ev.DevPath[slash+1:]
		}
	}
	return ev, true
}
