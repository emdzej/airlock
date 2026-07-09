//go:build linux

package gpio

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/warthog618/go-gpiocdev"
)

// Controller owns the button + LED lines and drives the LED state machine.
type Controller struct {
	button  *gpiocdev.Line
	led     *gpiocdev.Line
	state   chan State
	current State
}

// New requests the button and LED lines from the kernel. onPress is invoked
// (in a gpiocdev worker goroutine — do not block or reach out to slow
// dependencies from inside it) on each falling edge of the button.
func New(cfg Config, onPress func()) (*Controller, error) {
	if cfg.ChipName == "" {
		cfg = DefaultConfig()
	}
	if onPress == nil {
		onPress = func() {}
	}

	button, err := gpiocdev.RequestLine(cfg.ChipName, cfg.ButtonPin,
		gpiocdev.AsInput,
		gpiocdev.WithPullUp,
		gpiocdev.WithFallingEdge,
		gpiocdev.WithDebounce(50*time.Millisecond),
		gpiocdev.WithEventHandler(func(evt gpiocdev.LineEvent) {
			if evt.Type == gpiocdev.LineEventFallingEdge {
				onPress()
			}
		}),
	)
	if err != nil {
		return nil, fmt.Errorf("request button line %d: %w", cfg.ButtonPin, err)
	}

	led, err := gpiocdev.RequestLine(cfg.ChipName, cfg.LEDPin, gpiocdev.AsOutput(0))
	if err != nil {
		_ = button.Close()
		return nil, fmt.Errorf("request led line %d: %w", cfg.LEDPin, err)
	}

	return &Controller{
		button: button,
		led:    led,
		state:  make(chan State, 4),
	}, nil
}

// SetState changes the LED behavior. It is safe to call from any goroutine
// and never blocks — the channel has a small buffer and if it is full the
// latest state is queued in place of an older one.
func (c *Controller) SetState(s State) {
	// Drain the buffer of any older pending states so we always converge on
	// the most recently requested one.
	for {
		select {
		case c.state <- s:
			return
		case <-c.state:
			// dropped an older state; retry the send
		}
	}
}

// Run drives the LED state machine until ctx is done. On shutdown the LED is
// turned off and both lines are released.
func (c *Controller) Run(ctx context.Context) {
	defer c.close()

	// Ticker cadence is a small fraction of the fastest blink period so we
	// stay responsive without burning CPU.
	tick := time.NewTicker(30 * time.Millisecond)
	defer tick.Stop()

	var (
		lit      bool
		lastFlip time.Time
	)
	apply := func(on bool) {
		lit = on
		v := 0
		if on {
			v = 1
		}
		if err := c.led.SetValue(v); err != nil {
			slog.Warn("led set", "err", err)
		}
	}
	apply(false)

	for {
		select {
		case <-ctx.Done():
			return
		case s := <-c.state:
			c.current = s
			lastFlip = time.Time{}
			switch s {
			case StateOff:
				apply(false)
			case StateSolid:
				apply(true)
			case StateBlinkSlow, StateBlinkFast:
				apply(true)
				lastFlip = time.Now()
			}
		case now := <-tick.C:
			var period time.Duration
			switch c.current {
			case StateBlinkSlow:
				period = 500 * time.Millisecond
			case StateBlinkFast:
				period = 125 * time.Millisecond
			default:
				continue
			}
			if now.Sub(lastFlip) >= period {
				apply(!lit)
				lastFlip = now
			}
		}
	}
}

func (c *Controller) close() {
	if c.led != nil {
		_ = c.led.SetValue(0)
		_ = c.led.Close()
	}
	if c.button != nil {
		_ = c.button.Close()
	}
}

// ErrUnavailable is returned by New when the gpio chip cannot be opened. It
// is exported so callers (main.go) can decide to continue without GPIO on a
// dev machine while still bailing on unexpected errors.
var ErrUnavailable = errors.New("gpio chip unavailable")
