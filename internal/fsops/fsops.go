// Package fsops implements the file-system operations exposed over HTTP:
// list, download, upload, delete, rename, mkdir. Every operation is scoped
// to one drive's mount point (a Root) and all paths are kept under that
// root — no `..` escapes, no absolute paths, no symlinks that would land
// the request outside the intended drive.
//
// Containment is enforced by os.Root (openat-based, resolved by the
// kernel one component at a time), so a plugged-in ext4 drive containing
// `x -> /etc` can't be used to list, read, write, rename or delete
// anything outside the drive — and there's no check-then-open window for
// a symlink swap to exploit. A cheap syntactic check runs first so
// obvious `..` escapes get a clean ErrTraversal.
package fsops

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"io/fs"
	"os"
	"path"
	"sort"
	"strings"
	"syscall"
	"time"
)

var (
	ErrNotFound    = errors.New("path not found")
	ErrTraversal   = errors.New("path escapes drive root")
	ErrIsDirectory = errors.New("path is a directory")
	ErrNotRegular  = errors.New("not a regular file")
	ErrInvalidName = errors.New("invalid file name")
)

// Root binds an fsops instance to one drive's mount point. Callers must
// Close it when done.
type Root struct {
	root *os.Root
}

// NewRoot opens the mount point as an os.Root.
func NewRoot(mountPoint string) (*Root, error) {
	r, err := os.OpenRoot(mountPoint)
	if err != nil {
		return nil, err
	}
	return &Root{root: r}, nil
}

// Close releases the directory handle.
func (r *Root) Close() error { return r.root.Close() }

// clean normalizes a request path into a root-relative name. Leading '/'
// is stripped so callers can pass "/foo/bar" or "foo/bar" interchangeably.
// Empty rel (or "/") resolves to "." — the root itself.
func clean(rel string) (string, error) {
	if strings.ContainsRune(rel, 0) {
		return "", ErrInvalidName
	}
	name := path.Clean("/" + rel)
	// path.Clean on an absolute path can't climb above "/", so detect
	// escapes on the raw input instead.
	if escapes(rel) {
		return "", ErrTraversal
	}
	if name == "/" {
		return ".", nil
	}
	return strings.TrimPrefix(name, "/"), nil
}

// escapes reports whether rel climbs above its starting directory at any
// point, e.g. "..", "a/../..", "/../etc".
func escapes(rel string) bool {
	depth := 0
	for _, seg := range strings.Split(rel, "/") {
		switch seg {
		case "", ".":
		case "..":
			depth--
			if depth < 0 {
				return true
			}
		default:
			depth++
		}
	}
	return false
}

// mapErr translates os/os.Root errors into package sentinels.
func mapErr(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, fs.ErrNotExist) {
		return ErrNotFound
	}
	var pe *fs.PathError
	if errors.As(err, &pe) && pe.Err != nil && strings.Contains(pe.Err.Error(), "escapes") {
		return ErrTraversal
	}
	var le *os.LinkError
	if errors.As(err, &le) && le.Err != nil && strings.Contains(le.Err.Error(), "escapes") {
		return ErrTraversal
	}
	return err
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
	name, err := clean(rel)
	if err != nil {
		return nil, err
	}
	dir, err := r.root.Open(name)
	if err != nil {
		return nil, mapErr(err)
	}
	defer dir.Close()
	dirents, err := dir.ReadDir(-1)
	if err != nil {
		return nil, mapErr(err)
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
// directories and anything that isn't a regular file. O_NONBLOCK keeps a
// FIFO planted on the drive from blocking the open forever; it has no
// effect on reads from regular files.
func (r *Root) Open(rel string) (*os.File, os.FileInfo, error) {
	name, err := clean(rel)
	if err != nil {
		return nil, nil, err
	}
	f, err := r.root.OpenFile(name, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, nil, mapErr(err)
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
	if !info.Mode().IsRegular() {
		_ = f.Close()
		return nil, nil, ErrNotRegular
	}
	return f, info, nil
}

// WriteAtomic streams src into a temp file next to rel and renames it into
// place once fully written, so a dropped upload never destroys an
// existing file of the same name. Parent directories are created as
// needed.
func (r *Root) WriteAtomic(rel string, src io.Reader) (int64, error) {
	name, err := clean(rel)
	if err != nil {
		return 0, err
	}
	if name == "." || !isValidFilename(path.Base(name)) {
		return 0, ErrInvalidName
	}
	if dir := path.Dir(name); dir != "." {
		if err := r.root.MkdirAll(dir, 0o775); err != nil {
			return 0, mapErr(err)
		}
	}
	var rnd [6]byte
	_, _ = rand.Read(rnd[:])
	tmp := path.Join(path.Dir(name), ".airlock-upload-"+hex.EncodeToString(rnd[:]))
	f, err := r.root.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o664)
	if err != nil {
		return 0, mapErr(err)
	}
	n, err := io.Copy(f, src)
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = mapErr(r.root.Rename(tmp, name))
	}
	if err != nil {
		_ = r.root.Remove(tmp)
		return n, err
	}
	return n, nil
}

// Remove deletes a file or directory tree. It refuses to delete the root
// itself.
func (r *Root) Remove(rel string) error {
	name, err := clean(rel)
	if err != nil {
		return err
	}
	if name == "." {
		return ErrTraversal
	}
	if _, err := r.root.Lstat(name); err != nil {
		return mapErr(err)
	}
	return mapErr(r.root.RemoveAll(name))
}

// Rename moves/renames a path. Both endpoints must be within the root and
// neither may be the root itself.
func (r *Root) Rename(from, to string) error {
	src, err := clean(from)
	if err != nil {
		return err
	}
	dst, err := clean(to)
	if err != nil {
		return err
	}
	if src == "." || dst == "." {
		return ErrTraversal
	}
	if !isValidFilename(path.Base(dst)) {
		return ErrInvalidName
	}
	return mapErr(r.root.Rename(src, dst))
}

// Mkdir creates a directory, and any missing parents.
func (r *Root) Mkdir(rel string) error {
	name, err := clean(rel)
	if err != nil {
		return err
	}
	if name == "." {
		return nil
	}
	return mapErr(r.root.MkdirAll(name, 0o775))
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
