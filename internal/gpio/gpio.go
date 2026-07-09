// Package gpio drives the physical button and status LED wired to the Pi's
// 40-pin header. The button triggers an eject; the LED reflects the current
// mount/eject state so users know when it is safe to yank a drive.
package gpio

// State describes what the status LED should be doing.
type State int

const (
	StateOff       State = iota // no drives mounted
	StateSolid                  // drives mounted, no pending I/O
	StateBlinkSlow              // drives mounted with pending writes (~1 Hz)
	StateBlinkFast              // eject in progress / busy (~4 Hz)
)

// Config picks the chip and pin numbers.
type Config struct {
	// ChipName is the basename under /dev, e.g. "gpiochip0" (Pi 4).
	// Pi 5 uses "gpiochip4" for the header pins — override there.
	ChipName string

	// ButtonPin is the BCM GPIO number wired to the eject button.
	// The button pulls the line to ground when pressed; internal pull-up is
	// enabled by the driver.
	ButtonPin int

	// LEDPin is the BCM GPIO number wired to the status LED (through a ~330Ω
	// resistor to ground).
	LEDPin int
}

// DefaultConfig returns the reference wiring documented in the hardware guide:
// button on physical pin 11 (GPIO 17), LED on physical pin 13 (GPIO 27).
func DefaultConfig() Config {
	return Config{
		ChipName:  "gpiochip0",
		ButtonPin: 17,
		LEDPin:    27,
	}
}
