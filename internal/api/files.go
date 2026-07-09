package api

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"path"
	"path/filepath"
	"strings"

	"github.com/emdzej/airlock/internal/fsops"
	"github.com/emdzej/airlock/internal/mount"
)

// rootFor resolves the share name to a mounted Drive and its fsops.Root.
// Returns nil, empty, false if no matching drive is mounted right now.
func (s *Server) rootFor(share string) (*fsops.Root, mount.Drive, bool) {
	d, ok := s.findByShare(share)
	if !ok {
		return nil, mount.Drive{}, false
	}
	root, err := fsops.NewRoot(d.MountPoint)
	if err != nil {
		slog.Warn("fsops NewRoot", "share", share, "err", err)
		return nil, mount.Drive{}, false
	}
	return root, d, true
}

// writeJSON writes v as JSON with the given HTTP status.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// writeError translates an fsops error into a JSON error response with a
// sensible HTTP status code.
func writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, fsops.ErrNotFound):
		writeJSON(w, http.StatusNotFound, map[string]string{"error": err.Error()})
	case errors.Is(err, fsops.ErrTraversal), errors.Is(err, fsops.ErrInvalidName):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
	case errors.Is(err, fsops.ErrIsDirectory):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
	default:
		slog.Error("file op", "err", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}
}

// requireWritable returns true if the drive accepts writes. Otherwise it
// writes a 403 and returns false, and the caller should stop processing.
func requireWritable(w http.ResponseWriter, d mount.Drive) bool {
	if d.ReadOnly {
		writeJSON(w, http.StatusForbidden, map[string]string{
			"error": "drive is read-only (write-protected media)",
		})
		return false
	}
	return true
}

// GET /api/drives/{share}/ls?path=...
func (s *Server) handleLs(w http.ResponseWriter, r *http.Request) {
	root, _, ok := s.rootFor(r.PathValue("share"))
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "drive not found"})
		return
	}
	rel := r.URL.Query().Get("path")
	entries, err := root.List(rel)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"path":    "/" + strings.TrimPrefix(rel, "/"),
		"entries": entries,
	})
}

// GET /api/drives/{share}/dl?path=...
// Streams a file to the client with a Content-Disposition header so browsers
// treat it as a download.
func (s *Server) handleDownload(w http.ResponseWriter, r *http.Request) {
	root, _, ok := s.rootFor(r.PathValue("share"))
	if !ok {
		http.Error(w, "drive not found", http.StatusNotFound)
		return
	}
	rel := r.URL.Query().Get("path")
	f, info, err := root.Open(rel)
	if err != nil {
		writeError(w, err)
		return
	}
	defer f.Close()

	name := filepath.Base(info.Name())
	if ct := mime.TypeByExtension(filepath.Ext(name)); ct != "" {
		w.Header().Set("Content-Type", ct)
	} else {
		w.Header().Set("Content-Type", "application/octet-stream")
	}
	w.Header().Set("Content-Disposition", `attachment; filename="`+strings.ReplaceAll(name, `"`, `\"`)+`"`)
	http.ServeContent(w, r, name, info.ModTime(), f)
}

// POST /api/drives/{share}/upload?path=<full-target-path>
// The request body IS the file bytes (raw). This keeps upload semantics
// dead simple and avoids the "browsers may strip slashes from multipart
// filenames" hazard — the target path is fully client-controlled via the
// query parameter. Parent directories are mkdir-p'd. Existing files are
// overwritten.
func (s *Server) handleUpload(w http.ResponseWriter, r *http.Request) {
	root, d, ok := s.rootFor(r.PathValue("share"))
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "drive not found"})
		return
	}
	if !requireWritable(w, d) {
		return
	}
	dst := r.URL.Query().Get("path")
	if dst == "" || dst == "/" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "path is required"})
		return
	}
	if strings.Contains(dst, "..") {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid path"})
		return
	}

	if parent := path.Dir(dst); parent != "" && parent != "." && parent != "/" {
		if err := root.Mkdir(parent); err != nil {
			writeError(w, err)
			return
		}
	}
	f, err := root.Create(dst)
	if err != nil {
		writeError(w, err)
		return
	}
	n, copyErr := io.Copy(f, r.Body)
	closeErr := f.Close()
	if copyErr != nil {
		// Best-effort partial cleanup so the browser doesn't see a
		// half-written file sitting on the drive.
		_ = root.Remove(dst)
		writeError(w, copyErr)
		return
	}
	if closeErr != nil {
		_ = root.Remove(dst)
		writeError(w, closeErr)
		return
	}
	slog.Info("uploaded", "share", d.ShareName, "path", dst, "bytes", n)
	w.WriteHeader(http.StatusNoContent)
}

// DELETE /api/drives/{share}/rm?path=...
func (s *Server) handleRm(w http.ResponseWriter, r *http.Request) {
	root, d, ok := s.rootFor(r.PathValue("share"))
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "drive not found"})
		return
	}
	if !requireWritable(w, d) {
		return
	}
	rel := r.URL.Query().Get("path")
	if rel == "" || rel == "/" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "refuse to delete drive root"})
		return
	}
	if err := root.Remove(rel); err != nil {
		writeError(w, err)
		return
	}
	slog.Info("deleted", "share", d.ShareName, "path", rel)
	w.WriteHeader(http.StatusNoContent)
}

// POST /api/drives/{share}/mv  body: {"from": "...", "to": "..."}
func (s *Server) handleMv(w http.ResponseWriter, r *http.Request) {
	root, d, ok := s.rootFor(r.PathValue("share"))
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "drive not found"})
		return
	}
	if !requireWritable(w, d) {
		return
	}
	var body struct {
		From string `json:"from"`
		To   string `json:"to"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON body"})
		return
	}
	if body.From == "" || body.To == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "from and to are required"})
		return
	}
	if err := root.Rename(body.From, body.To); err != nil {
		writeError(w, err)
		return
	}
	slog.Info("renamed", "share", d.ShareName, "from", body.From, "to", body.To)
	w.WriteHeader(http.StatusNoContent)
}

// POST /api/drives/{share}/mkdir  body: {"path": "..."}
func (s *Server) handleMkdir(w http.ResponseWriter, r *http.Request) {
	root, d, ok := s.rootFor(r.PathValue("share"))
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "drive not found"})
		return
	}
	if !requireWritable(w, d) {
		return
	}
	var body struct {
		Path string `json:"path"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON body"})
		return
	}
	if body.Path == "" || body.Path == "/" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "path is required"})
		return
	}
	if err := root.Mkdir(body.Path); err != nil {
		writeError(w, err)
		return
	}
	slog.Info("mkdir", "share", d.ShareName, "path", body.Path)
	w.WriteHeader(http.StatusNoContent)
}

// GET /devices — HTML page listing all USB block devices for management.
func (s *Server) handleDevicesPage(w http.ResponseWriter, _ *http.Request) {
	data := s.common("devices")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := s.tmpl.ExecuteTemplate(w, "devices.html", data); err != nil {
		slog.Error("render devices", "err", err)
	}
}

// GET /drives/{share}/  — file browser HTML page.
func (s *Server) handleBrowse(w http.ResponseWriter, r *http.Request) {
	share := r.PathValue("share")
	d, ok := s.findByShare(share)
	if !ok {
		http.NotFound(w, r)
		return
	}
	parent := d.Parent
	if parent == "" {
		parent = d.Kernel
	}
	data := struct {
		commonData
		Share     string
		Label     string
		FSType    string
		ReadOnly  bool
		SizeHuman string
		Parent    string
	}{
		commonData: s.common("mounts"),
		Share:      d.ShareName,
		Label:      displayLabel(d),
		FSType:     d.FSType,
		ReadOnly:   d.ReadOnly,
		SizeHuman:  humanBytes(d.SizeBytes),
		Parent:     parent,
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := s.tmpl.ExecuteTemplate(w, "browse.html", data); err != nil {
		slog.Error("render browse", "err", err)
	}
}
