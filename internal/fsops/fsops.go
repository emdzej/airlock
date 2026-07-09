// Package fsops implements the file-system operations exposed over HTTP:
// list, download, upload, delete, rename, mkdir. Every operation is scoped
// to one drive's mount point (a Root) and all paths are checked to keep
// them under that root — no `..` escapes, no absolute paths, no symlinks
// that would land the request outside the intended drive.
//
// The check strategy is:
//
//   1. Normalize the requested rel path (strip leading '/', reject NUL).
//   2. filepath.Join(Root, rel) then filepath.Clean the result.
//   3. Require the cleaned path == Root or starts with Root + separator.
//   4. For read operations that will open() the file, also EvalSymlinks
//      and re-verify the resolved target is still under Root — this blocks
//      the case where a plugged-in ext4 drive contains a symlink to /etc.
//
// TODA (M4 hardening): move to openat2(RESOLVE_BENEATH) for kernel-enforced
// containment. Requires refactoring os.Open / os.ReadDir call sites.
package fsops

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

var (
	ErrNotFound    = errors.New("path not found")
	ErrTraversal   = errors.New("path escapes drive root")
	ErrIsDirectory = errors.New("path is a directory")
	ErrInvalidName = errors.New("invalid file name")
)

// Root binds an fsops instance to one drive's mount point. All paths are
// resolved relative to Base.
type Root struct {
	Base string // absolute, canonical path to the mount point
}

// NewRoot returns a Root for the given mount point. The path is made
// absolute and symlinks in the mount-point path are resolved once, so
// subsequent Resolve calls can compare against a canonical Base.
func NewRoot(mountPoint string) (*Root, error) {
	abs, err := filepath.Abs(mountPoint)
	if err != nil {
		return nil, err
	}
	canon, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return nil, err
	}
	return &Root{Base: canon}, nil
}

// Resolve returns the absolute filesystem path for a rel request path,
// guaranteed to remain under r.Base. Leading '/' is stripped so callers can
// pass "/foo/bar" or "foo/bar" interchangeably. Empty rel resolves to the
// root itself.
func (r *Root) Resolve(rel string) (string, error) {
	if strings.ContainsRune(rel, 0) {
		return "", ErrInvalidName
	}
	rel = strings.TrimPrefix(rel, "/")
	joined := filepath.Join(r.Base, rel)
	cleaned := filepath.Clean(joined)
	if cleaned != r.Base && !strings.HasPrefix(cleaned, r.Base+string(os.PathSeparator)) {
		return "", ErrTraversal
	}
	return cleaned, nil
}

// resolveNoSymlinkEscape resolves like Resolve, then walks any existing
// symlinks and re-verifies the target is still under Base. Used before
// opening files for read. On non-existent paths (needed for Create/Mkdir)
// callers should use Resolve directly.
func (r *Root) resolveNoSymlinkEscape(rel string) (string, error) {
	abs, err := r.Resolve(rel)
	if err != nil {
		return "", err
	}
	real, err := filepath.EvalSymlinks(abs)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return "", ErrNotFound
		}
		return "", err
	}
	if real != r.Base && !strings.HasPrefix(real, r.Base+string(os.PathSeparator)) {
		return "", ErrTraversal
	}
	return real, nil
}

// Entry is one directory listing item.
type Entry struct {
	Name     string    `json:"name"`
	IsDir    bool      `json:"is_dir"`
	Size     int64     `json:"size"`
	Modified time.Time `json:"modified"`
}

// List returns the entries of a directory. Symlinks are reported by their
// link name; we do not follow them for listing purposes.
func (r *Root) List(rel string) ([]Entry, error) {
	abs, err := r.Resolve(rel)
	if err != nil {
		return nil, err
	}
	dirents, err := os.ReadDir(abs)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	out := make([]Entry, 0, len(dirents))
	for _, d := range dirents {
		info, err := d.Info()
		if err != nil {
			continue
		}
		out = append(out, Entry{
			Name:     d.Name(),
			IsDir:    d.IsDir(),
			Size:     info.Size(),
			Modified: info.ModTime(),
		})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].IsDir != out[j].IsDir {
			return out[i].IsDir
		}
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	return out, nil
}

// Open returns an *os.File for reading, with its FileInfo. Refuses
// directories and follows symlinks only within the drive.
func (r *Root) Open(rel string) (*os.File, os.FileInfo, error) {
	abs, err := r.resolveNoSymlinkEscape(rel)
	if err != nil {
		return nil, nil, err
	}
	f, err := os.Open(abs)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, nil, ErrNotFound
		}
		return nil, nil, err
	}
	info, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return nil, nil, err
	}
	if info.IsDir() {
		_ = f.Close()
		return nil, nil, ErrIsDirectory
	}
	return f, info, nil
}

// Create opens a file for writing, truncating any existing file. The parent
// directory must already exist — callers should Mkdir first for new
// directory trees.
func (r *Root) Create(rel string) (*os.File, error) {
	abs, err := r.Resolve(rel)
	if err != nil {
		return nil, err
	}
	if abs == r.Base {
		return nil, ErrInvalidName
	}
	if !isValidFilename(filepath.Base(abs)) {
		return nil, ErrInvalidName
	}
	return os.OpenFile(abs, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o664)
}

// Remove deletes a file or directory tree. It refuses to delete the root
// itself.
func (r *Root) Remove(rel string) error {
	abs, err := r.Resolve(rel)
	if err != nil {
		return err
	}
	if abs == r.Base {
		return ErrTraversal
	}
	if err := os.RemoveAll(abs); err != nil {
		return err
	}
	return nil
}

// Rename moves/renames a path. Both endpoints must be within r.Base and
// neither may equal Base itself.
func (r *Root) Rename(from, to string) error {
	src, err := r.Resolve(from)
	if err != nil {
		return err
	}
	dst, err := r.Resolve(to)
	if err != nil {
		return err
	}
	if src == r.Base || dst == r.Base {
		return ErrTraversal
	}
	if !isValidFilename(filepath.Base(dst)) {
		return ErrInvalidName
	}
	if err := os.Rename(src, dst); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return ErrNotFound
		}
		return err
	}
	return nil
}

// Mkdir creates a directory, and any missing parents.
func (r *Root) Mkdir(rel string) error {
	abs, err := r.Resolve(rel)
	if err != nil {
		return err
	}
	if abs == r.Base {
		return nil
	}
	return os.MkdirAll(abs, 0o775)
}

// isValidFilename does light validation to avoid the most obvious footguns
// — path separators, NUL, empty, dot names. Filesystem-specific rules
// (FAT reserved chars, case sensitivity) are deferred to the kernel.
func isValidFilename(name string) bool {
	if name == "" || name == "." || name == ".." {
		return false
	}
	if len(name) > 255 {
		return false
	}
	if strings.ContainsAny(name, "/\x00") {
		return false
	}
	return true
}
