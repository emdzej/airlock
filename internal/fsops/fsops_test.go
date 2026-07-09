package fsops

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func newTestRoot(t *testing.T) *Root {
	t.Helper()
	tmp := t.TempDir()
	if err := os.MkdirAll(filepath.Join(tmp, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tmp, "file.txt"), []byte("hi"), 0o644); err != nil {
		t.Fatal(err)
	}
	r, err := NewRoot(tmp)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestResolve_Legal(t *testing.T) {
	r := newTestRoot(t)
	cases := []string{"", "/", "file.txt", "/file.txt", "sub", "sub/inner", "./file.txt"}
	for _, in := range cases {
		abs, err := r.Resolve(in)
		if err != nil {
			t.Errorf("Resolve(%q): unexpected error %v", in, err)
			continue
		}
		if abs != r.Base && !hasParent(abs, r.Base) {
			t.Errorf("Resolve(%q) = %q escaped base %q", in, abs, r.Base)
		}
	}
}

func TestResolve_Traversal(t *testing.T) {
	r := newTestRoot(t)
	cases := []string{"..", "../../etc/passwd", "sub/../..", "/../"}
	for _, in := range cases {
		_, err := r.Resolve(in)
		if !errors.Is(err, ErrTraversal) {
			t.Errorf("Resolve(%q) should have returned ErrTraversal, got %v", in, err)
		}
	}
}

func TestResolve_RejectsNUL(t *testing.T) {
	r := newTestRoot(t)
	if _, err := r.Resolve("bad\x00name"); !errors.Is(err, ErrInvalidName) {
		t.Errorf("expected ErrInvalidName for NUL, got %v", err)
	}
}

func TestList_SortsDirsFirst(t *testing.T) {
	r := newTestRoot(t)
	entries, err := r.List("")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 {
		t.Fatalf("expected 2 entries, got %d", len(entries))
	}
	if !entries[0].IsDir || entries[0].Name != "sub" {
		t.Errorf("first entry should be dir 'sub', got %+v", entries[0])
	}
	if entries[1].IsDir || entries[1].Name != "file.txt" {
		t.Errorf("second entry should be file 'file.txt', got %+v", entries[1])
	}
}

func TestOpen_RefusesDirectory(t *testing.T) {
	r := newTestRoot(t)
	_, _, err := r.Open("sub")
	if !errors.Is(err, ErrIsDirectory) {
		t.Errorf("expected ErrIsDirectory, got %v", err)
	}
}

func TestSymlinkEscape(t *testing.T) {
	r := newTestRoot(t)
	// Point a symlink inside the drive to /etc.
	link := filepath.Join(r.Base, "escape")
	if err := os.Symlink("/etc", link); err != nil {
		t.Skipf("symlink not supported on this fs: %v", err)
	}
	// Resolve() is happy because the syntactic path is under base.
	// Open() through resolveNoSymlinkEscape should reject.
	_, _, err := r.Open("escape")
	if !errors.Is(err, ErrTraversal) && !errors.Is(err, ErrIsDirectory) {
		t.Errorf("expected traversal or is-directory error, got %v", err)
	}
}

func TestRoundTrip_CreateWriteReadDelete(t *testing.T) {
	r := newTestRoot(t)
	if err := r.Mkdir("newdir"); err != nil {
		t.Fatal(err)
	}
	f, err := r.Create("newdir/hello.txt")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString("world"); err != nil {
		t.Fatal(err)
	}
	f.Close()

	f, _, err = r.Open("newdir/hello.txt")
	if err != nil {
		t.Fatal(err)
	}
	data := make([]byte, 5)
	if _, err := f.Read(data); err != nil {
		t.Fatal(err)
	}
	f.Close()
	if string(data) != "world" {
		t.Errorf("read wrong bytes: %q", data)
	}

	if err := r.Rename("newdir/hello.txt", "newdir/renamed.txt"); err != nil {
		t.Fatal(err)
	}
	if err := r.Remove("newdir"); err != nil {
		t.Fatal(err)
	}
}

func hasParent(path, parent string) bool {
	rel, err := filepath.Rel(parent, path)
	if err != nil {
		return false
	}
	return rel != ".." && rel[:2] != ".."
}
