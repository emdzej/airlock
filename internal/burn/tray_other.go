//go:build !linux

package burn

import (
	"errors"
	"os"
)

// Optical drive control is only implemented on Linux. These stubs keep
// the module building on other platforms for editor and CI use.

var errUnsupported = errors.New("optical drives are only supported on linux")

func EjectTray(string) error  { return errUnsupported }
func reloadTray(string) error { return errUnsupported }
func flushBuffers(*os.File)   {}
