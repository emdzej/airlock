package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"os/user"
	"strconv"
	"sync"
	"syscall"

	"github.com/emdzej/airlock/internal/api"
	"github.com/emdzej/airlock/internal/gpio"
	"github.com/emdzej/airlock/internal/mount"
	"github.com/emdzej/airlock/internal/samba"
)

// version is the compile-time version string shown in the web-UI footer.
// The release workflow overrides it via -ldflags "-X main.version=<tag>";
// local `make` builds pick up the default below. Bump this in lock-step
// with CHANGELOG.md when tagging a new release.
var version = "0.2.0"

func main() {
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(log)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if err := run(ctx); err != nil {
		log.Error("airlockd exited with error", "err", err)
		os.Exit(1)
	}
}

func run(ctx context.Context) error {
	slog.Info("airlockd starting")

	owner, err := resolveOwner(mount.DefaultOwnerUID, mount.DefaultOwnerGID)
	if err != nil {
		return fmt.Errorf("resolve owner: %w", err)
	}
	slog.Info("share owner resolved", "user", owner.User, "group", owner.Group)

	sw := samba.New("", owner)
	orch := &orchestrator{}

	mgr, err := mount.NewManager(mount.DefaultBaseDir, func(snap mount.Snapshot) {
		names := make([]string, 0, len(snap.Drives))
		for _, d := range snap.Drives {
			names = append(names, d.ShareName)
		}
		slog.Info("drives changed", "count", len(snap.Drives), "shares", names)
		if err := sw.Apply(snap); err != nil {
			slog.Error("samba apply", "err", err)
		}
		orch.setDrives(len(snap.Drives))
	})
	if err != nil {
		return err
	}

	apiSrv, err := api.New(mgr, orch.setBusy, version)
	if err != nil {
		return err
	}

	// GPIO is best-effort. If /dev/gpiochip0 isn't reachable (dev machine, no
	// wiring, kernel not surfacing the chip) we log and continue — the
	// appliance is still usable via the web UI.
	ledCtrl, err := gpio.New(gpio.DefaultConfig(), func() {
		slog.Info("eject button pressed")
		go func() {
			orch.setBusy(true)
			defer orch.setBusy(false)
			mgr.EjectAll()
		}()
	})
	switch {
	case err == nil:
		orch.attachLED(ledCtrl)
		slog.Info("gpio ready",
			"chip", gpio.DefaultConfig().ChipName,
			"button_pin", gpio.DefaultConfig().ButtonPin,
			"led_pin", gpio.DefaultConfig().LEDPin,
		)
	case errors.Is(err, gpio.ErrUnavailable):
		slog.Warn("gpio unavailable — running without button/LED", "err", err)
	default:
		slog.Warn("gpio init failed — running without button/LED", "err", err)
	}

	// Recover: any /mnt/airlock/* leftover from a previous daemon run is
	// force-unmounted here so we start from an empty state. The Samba config
	// is wiped for the same reason — otherwise it would still list shares
	// from before the restart until the first drive change.
	mgr.Recover()
	if err := sw.Apply(mgr.Snapshot()); err != nil {
		slog.Warn("samba apply (initial wipe)", "err", err)
	}

	events, err := mount.WatchUEvents(ctx)
	if err != nil {
		return err
	}
	// Once the netlink watcher is subscribed, ask udev to re-emit ADD events
	// for currently-attached block devices so we pick them up.
	mgr.ReplayUdev()

	var wg sync.WaitGroup
	if ledCtrl != nil {
		wg.Add(1)
		go func() { defer wg.Done(); ledCtrl.Run(ctx) }()
	}
	wg.Add(1)
	go func() { defer wg.Done(); mgr.Run(ctx, events) }()
	wg.Add(1)
	go func() {
		defer wg.Done()
		if err := apiSrv.Run(ctx, ":80"); err != nil {
			slog.Error("http server", "err", err)
		}
	}()

	<-ctx.Done()
	slog.Info("airlockd shutting down")
	// Flush any pending writes to mounted filesystems. We deliberately do NOT
	// unmount — the user is expected to hit the eject button. sync() at least
	// gives cleanly-committed data on the way out.
	syscall.Sync()
	wg.Wait()
	return nil
}

// orchestrator drives the LED state from two independent inputs: the number
// of currently-mounted drives, and a "busy" reference count that goes up
// while eject operations are in flight. Busy state takes precedence — the
// LED blinks fast during eject regardless of how many drives are (still)
// mounted.
type orchestrator struct {
	mu     sync.Mutex
	busy   int
	drives int
	led    *gpio.Controller
}

func (o *orchestrator) attachLED(led *gpio.Controller) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.led = led
	o.applyLocked()
}

func (o *orchestrator) setDrives(n int) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.drives = n
	o.applyLocked()
}

func (o *orchestrator) setBusy(busy bool) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if busy {
		o.busy++
	} else if o.busy > 0 {
		o.busy--
	}
	o.applyLocked()
}

// resolveOwner looks up the Unix user and group whose numeric IDs match the
// mount pkg's DefaultOwnerUID/GID. On a pi-gen-built image this yields
// "airlock"; on this developer Pi it yields "emdzej"; both are valid as long
// as the name matches whatever local account owns UID 1000.
func resolveOwner(uid, gid int) (samba.Owner, error) {
	u, err := user.LookupId(strconv.Itoa(uid))
	if err != nil {
		return samba.Owner{}, fmt.Errorf("lookup uid %d: %w", uid, err)
	}
	g, err := user.LookupGroupId(strconv.Itoa(gid))
	if err != nil {
		return samba.Owner{}, fmt.Errorf("lookup gid %d: %w", gid, err)
	}
	return samba.Owner{User: u.Username, Group: g.Name}, nil
}

func (o *orchestrator) applyLocked() {
	if o.led == nil {
		return
	}
	switch {
	case o.busy > 0:
		o.led.SetState(gpio.StateBlinkFast)
	case o.drives > 0:
		o.led.SetState(gpio.StateSolid)
	default:
		o.led.SetState(gpio.StateOff)
	}
}
