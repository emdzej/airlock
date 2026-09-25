// Package api serves the airlockd HTTP interface: the web UI pages and the
// JSON / SSE API for drives, files, and whole-device operations.
package api

import (
	"context"
	"embed"
	"errors"
	"fmt"
	"html/template"
	"log/slog"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/emdzej/airlock/internal/flash"
	"github.com/emdzej/airlock/internal/format"
	"github.com/emdzej/airlock/internal/fsck"
	"github.com/emdzej/airlock/internal/mount"
)

//go:embed templates/*.html
var templateFS embed.FS

// BusyFunc is called with true when a long-running (destructive) operation
// begins and false when it ends. Used to drive the LED into "fast blink"
// during eject/format operations.
type BusyFunc func(bool)

// RepoURL is the canonical link back to the airlock source. Rendered in the
// footer of every page.
const RepoURL = "https://github.com/emdzej/airlock"

// Server is the HTTP layer around the mount Manager.
type Server struct {
	mgr     *mount.Manager
	fmtr    *format.Formatter
	flsh    *flash.Flasher
	fsck    *fsck.Checker
	tmpl    *template.Template
	onBusy  BusyFunc
	version string
	events  *broadcaster

	allowedHosts []string       // extra Host names for the rebinding guard
	ops          sync.WaitGroup // in-flight device operations
	closing      chan struct{}  // closed when the HTTP server shuts down
}

// New parses templates and returns a Server. onBusy may be nil.
func New(mgr *mount.Manager, onBusy BusyFunc, version string) (*Server, error) {
	if onBusy == nil {
		onBusy = func(bool) {}
	}
	if version == "" {
		version = "dev"
	}
	tmpl, err := template.ParseFS(templateFS, "templates/*.html")
	if err != nil {
		return nil, fmt.Errorf("parse templates: %w", err)
	}
	return &Server{
		mgr:     mgr,
		fmtr:    format.New(mgr),
		flsh:    flash.New(mgr),
		fsck:    fsck.New(mgr),
		tmpl:    tmpl,
		onBusy:  onBusy,
		version: version,
		events:  newBroadcaster(),
		closing: make(chan struct{}),
	}, nil
}

// commonData holds the fields every page template expects: host, active nav
// tab, version, and repo URL. Embedded by page-specific data structs.
type commonData struct {
	Host    string
	Active  string
	Version string
	RepoURL string
}

func (s *Server) common(active string) commonData {
	return commonData{
		Host:    serverHostname(),
		Active:  active,
		Version: s.version,
		RepoURL: RepoURL,
	}
}

// Handler returns the HTTP handler tree, wrapped in the cross-origin and
// Host guards.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	// Pages
	mux.HandleFunc("GET /{$}", s.handleIndex)
	mux.HandleFunc("GET /drives/{share}/", s.handleBrowse)
	// Drive-level JSON API
	mux.HandleFunc("GET /api/drives", s.handleListDrives)
	mux.HandleFunc("POST /api/drives/{name}/eject", s.handleEject)
	mux.HandleFunc("POST /api/eject-all", s.handleEjectAll)
	// File-level JSON API
	mux.HandleFunc("GET /api/drives/{share}/ls", s.handleLs)
	mux.HandleFunc("GET /api/drives/{share}/dl", s.handleDownload)
	mux.HandleFunc("POST /api/drives/{share}/upload", s.handleUpload)
	mux.HandleFunc("DELETE /api/drives/{share}/rm", s.handleRm)
	mux.HandleFunc("POST /api/drives/{share}/mv", s.handleMv)
	mux.HandleFunc("POST /api/drives/{share}/mkdir", s.handleMkdir)
	// Device-level (whole-disk) API
	mux.HandleFunc("GET /api/devices", s.handleListDevices)
	mux.HandleFunc("GET /api/devices/{parent}", s.handleDeviceInfo)
	mux.HandleFunc("POST /api/devices/{parent}/eject", s.handleDeviceEject)
	mux.HandleFunc("POST /api/devices/{parent}/format", s.handleFormat)
	mux.HandleFunc("POST /api/devices/{parent}/flash", s.handleFlash)
	mux.HandleFunc("GET /api/devices/{parent}/dump", s.handleDump)
	// Partition-level operations
	mux.HandleFunc("POST /api/partitions/{name}/label", s.handleSetLabel)
	mux.HandleFunc("POST /api/partitions/{name}/mount", s.handleMountPartition)
	mux.HandleFunc("POST /api/partitions/{name}/fsck", s.handleFsck)
	// Devices HTML page
	mux.HandleFunc("GET /devices", s.handleDevicesPage)
	// Event stream (SSE)
	mux.HandleFunc("GET /api/events", s.handleEvents)
	return s.guard(mux)
}

// Run starts the HTTP server and blocks until ctx is done, then shuts down
// gracefully: open event streams are closed right away, idle connections
// get a 10-second deadline, and any running format / flash / fsck is
// waited for rather than killed mid-write.
func (s *Server) Run(ctx context.Context, addr string) error {
	srv := &http.Server{
		Addr:              addr,
		Handler:           s.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	srv.RegisterOnShutdown(func() { close(s.closing) })
	errCh := make(chan error, 1)
	go func() {
		slog.Info("http server listening", "addr", addr)
		errCh <- srv.ListenAndServe()
	}()
	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		err := srv.Shutdown(shutdownCtx)
		done := make(chan struct{})
		go func() { s.ops.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(250 * time.Millisecond):
			slog.Warn("waiting for running device operations to finish")
			<-done
		}
		if errors.Is(err, context.DeadlineExceeded) {
			return nil // long-running handlers finished above
		}
		return err
	case err := <-errCh:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}

// drivePayload is the wire representation of a mounted drive.
type drivePayload struct {
	ShareName   string `json:"share_name"`
	Label       string `json:"label"`
	DisplayName string `json:"display_name"`
	FSType      string `json:"fs_type"`
	SizeBytes   int64  `json:"size_bytes"`
	SizeHuman   string `json:"size_human"`
	ReadOnly    bool   `json:"read_only"`
	MountPoint  string `json:"mount_point"`
	Kernel      string `json:"kernel"`
	Parent      string `json:"parent"`
	Ejecting    bool   `json:"ejecting"`
}

func payloadFor(d mount.Drive) drivePayload {
	return drivePayload{
		ShareName:   d.ShareName,
		Label:       d.Label,
		DisplayName: displayLabel(d),
		FSType:      d.FSType,
		SizeBytes:   d.SizeBytes,
		SizeHuman:   humanBytes(d.SizeBytes),
		ReadOnly:    d.ReadOnly,
		MountPoint:  d.MountPoint,
		Kernel:      d.Kernel,
		Parent:      d.Parent,
		Ejecting:    d.Ejecting,
	}
}

// displayLabel returns the label to show in UI: the filesystem label if any,
// else the kernel device name.
func displayLabel(d mount.Drive) string {
	if d.Label != "" {
		return d.Label
	}
	return d.Kernel
}

// serverHostname returns the machine hostname, falling back to "airlock" if
// the lookup fails.
func serverHostname() string {
	h, _ := os.Hostname()
	if h == "" {
		return "airlock"
	}
	return h
}

func (s *Server) handleIndex(w http.ResponseWriter, _ *http.Request) {
	snap := s.mgr.Snapshot()
	data := struct {
		commonData
		Drives []drivePayload
	}{
		commonData: s.common("mounts"),
		Drives:     make([]drivePayload, 0, len(snap.Drives)),
	}
	for _, d := range snap.Drives {
		data.Drives = append(data.Drives, payloadFor(d))
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := s.tmpl.ExecuteTemplate(w, "index.html", data); err != nil {
		slog.Error("render index", "err", err)
	}
}

func (s *Server) handleListDrives(w http.ResponseWriter, _ *http.Request) {
	snap := s.mgr.Snapshot()
	out := make([]drivePayload, 0, len(snap.Drives))
	for _, d := range snap.Drives {
		out = append(out, payloadFor(d))
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleEject(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	drive, ok := s.findByShare(name)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "drive not found"})
		return
	}
	parent := drive.Parent
	if parent == "" {
		parent = drive.Kernel
	}
	s.onBusy(true)
	defer s.onBusy(false)
	if err := s.mgr.Eject(parent); err != nil && !errors.Is(err, mount.ErrNotMounted) {
		writeJSON(w, ejectStatus(err), map[string]string{"error": err.Error()})
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleEjectAll(w http.ResponseWriter, _ *http.Request) {
	s.onBusy(true)
	defer s.onBusy(false)
	if err := s.mgr.EjectAll(); err != nil {
		writeJSON(w, ejectStatus(err), map[string]string{"error": err.Error()})
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ejectStatus maps an unmount error to an HTTP status: a busy filesystem
// is a 409 the user can resolve (close files, retry).
func ejectStatus(err error) int {
	if errors.Is(err, mount.ErrBusy) {
		return http.StatusConflict
	}
	return http.StatusInternalServerError
}

func (s *Server) findByShare(name string) (mount.Drive, bool) {
	for _, d := range s.mgr.Snapshot().Drives {
		if d.ShareName == name {
			return d, true
		}
	}
	return mount.Drive{}, false
}

// humanBytes formats a byte count with SI (decimal) units — "16.0 GB" reads
// more naturally on a card reader than "14.9 GiB".
func humanBytes(b int64) string {
	const unit = 1000
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(b)/float64(div), "kMGTPE"[exp])
}
