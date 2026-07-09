//go:build !linux

package gpio

import (
	"context"
	"errors"
)

// Controller is a no-op stub on non-Linux platforms.
type Controller struct{}

// ErrUnavailable indicates GPIO isn't supported on this platform.
var ErrUnavailable = errors.New("gpio not supported on this platform")

// New returns ErrUnavailable on non-Linux. Callers should log a warning and
// continue — a dev machine has no button/LED.
func New(_ Config, _ func()) (*Controller, error) { return nil, ErrUnavailable }

// SetState is a no-op.
func (c *Controller) SetState(State) {}

// Run blocks until ctx is done.
func (c *Controller) Run(ctx context.Context) { <-ctx.Done() }
