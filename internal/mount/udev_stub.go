//go:build !linux

package mount

import (
	"context"
	"errors"
)

// WatchUEvents is only implemented on Linux. This stub exists so the module
// builds on other platforms (macOS/Windows) for editor and CI use.
func WatchUEvents(ctx context.Context) (<-chan UEvent, error) {
	return nil, errors.New("udev is only supported on linux")
}
