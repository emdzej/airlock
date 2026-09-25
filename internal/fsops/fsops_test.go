package fsops

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func newTestRoot(t *testing.T) (*Root, string) {
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
	t.Cleanup(func() { _ = r.Close() })
	return r, tmp
}

func TestClean_Legal(t *testing.T) {
	cases := map[string]string{
		"": ".", "/": ".", "file.txt": "file.txt", "/file.txt": "file.txt",
		"sub": "sub", "sub/inner": "sub/inner", "./file.txt": "file.txt",
		"sub/../file.txt": "file.txt",
	}
	for in, want := range cases {
		got, err := clean(in)
		if err != nil || got != want {
			t.Errorf("clean(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
}

func TestClean_Traversal(t *testing.T) {
	for _, in := range []string{"..", "../../etc/passwd", "sub/../..", "/../", "a/../../b"} {
		if _, err := clean(in); !errors.Is(err, ErrTraversal) {
			t.Errorf("clean(%q) should have returned ErrTraversal, got %v", in, err)
		}
	}
}

func TestClean_RejectsNUL(t *testing.T) {
	if _, err := clean("bad\x00name"); !errors.Is(err, ErrInvalidName) {
		t.Errorf("expected ErrInvalidName for NUL, got %v", err)
	}
}

func TestList_SortsDirsFirst(t *testing.T) {
	r, _ := newTestRoot(t)
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
	r, _ := newTestRoot(t)
	if _, _, err := r.Open("sub"); !errors.Is(err, ErrIsDirectory) {
		t.Errorf("expected ErrIsDirectory, got %v", err)
	}
}

func TestOpen_RefusesFIFO(t *testing.T) {
	r, base := newTestRoot(t)
	if err := syscall.Mkfifo(filepath.Join(base, "pipe"), 0o644); err != nil {
		t.Skipf("mkfifo: %v", err)
	}
	if _, _, err := r.Open("pipe"); !errors.Is(err, ErrNotRegular) {
		t.Errorf("expected ErrNotRegular, got %v", err)
	}
}

// Every operation must refuse to follow a symlink that points outside the
// drive — the case of a plugged-in ext4 stick containing `x -> /etc`.
func TestSymlinkEscape_AllOps(t *testing.T) {
	r, base := newTestRoot(t)
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "secret"), []byte("s"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(base, "escape")); err != nil {
		t.Skipf("symlink not supported on this fs: %v", err)
	}

	if _, err := r.List("escape"); !errors.Is(err, ErrTraversal) {
		t.Errorf("List: expected ErrTraversal, got %v", err)
	}
	if _, _, err := r.Open("escape/secret"); !errors.Is(err, ErrTraversal) {
		t.Errorf("Open: expected ErrTraversal, got %v", err)
	}
	if _, err := r.WriteAtomic("escape/pwn", strings.NewReader("x")); !errors.Is(err, ErrTraversal) {
		t.Errorf("WriteAtomic: expected ErrTraversal, got %v", err)
	}
	if err := r.Mkdir("escape/newdir"); !errors.Is(err, ErrTraversal) {
		t.Errorf("Mkdir: expected ErrTraversal, got %v", err)
	}
	if err := r.Remove("escape/secret"); !errors.Is(err, ErrTraversal) {
		t.Errorf("Remove: expected ErrTraversal, got %v", err)
	}
	if err := r.Rename("escape/secret", "stolen"); !errors.Is(err, ErrTraversal) {
		t.Errorf("Rename (from): expected ErrTraversal, got %v", err)
	}
	if err := r.Rename("file.txt", "escape/planted"); !errors.Is(err, ErrTraversal) {
		t.Errorf("Rename (to): expected ErrTraversal, got %v", err)
	}

	// Nothing outside may have changed.
	ents, _ := os.ReadDir(outside)
	if len(ents) != 1 || ents[0].Name() != "secret" {
		t.Errorf("outside dir was modified: %v", ents)
	}

	// Removing the link itself is fine and must not touch the target.
	if err := r.Remove("escape"); err != nil {
		t.Errorf("Remove(link): %v", err)
	}
	if _, err := os.Stat(filepath.Join(outside, "secret")); err != nil {
		t.Errorf("link target was removed: %v", err)
	}
}

func TestWriteAtomic_FailureKeepsOriginal(t *testing.T) {
	r, base := newTestRoot(t)
	_, err := r.WriteAtomic("file.txt", io.MultiReader(strings.NewReader("partial"), errReader{}))
	if err == nil {
		t.Fatal("expected copy error")
	}
	got, _ := os.ReadFile(filepath.Join(base, "file.txt"))
	if string(got) != "hi" {
		t.Errorf("original clobbered: %q", got)
	}
	ents, _ := os.ReadDir(base)
	for _, e := range ents {
		if strings.HasPrefix(e.Name(), ".airlock-upload-") {
			t.Errorf("temp file left behind: %s", e.Name())
		}
	}
}

type errReader struct{}

func (errReader) Read([]byte) (int, error) { return 0, errors.New("client went away") }

func TestRoundTrip_CreateWriteReadDelete(t *testing.T) {
	r, _ := newTestRoot(t)
	if _, err := r.WriteAtomic("newdir/deep/hello.txt", strings.NewReader("world")); err != nil {
		t.Fatal(err)
	}
	f, _, err := r.Open("/newdir/deep/hello.txt")
	if err != nil {
		t.Fatal(err)
	}
	data, _ := io.ReadAll(f)
	f.Close()
	if string(data) != "world" {
		t.Errorf("read wrong bytes: %q", data)
	}
	if err := r.Rename("newdir/deep/hello.txt", "newdir/renamed.txt"); err != nil {
		t.Fatal(err)
	}
	if err := r.Remove("newdir"); err != nil {
		t.Fatal(err)
	}
	if err := r.Remove("newdir"); !errors.Is(err, ErrNotFound) {
		t.Errorf("second Remove: expected ErrNotFound, got %v", err)
	}
	if err := r.Remove("/"); !errors.Is(err, ErrTraversal) {
		t.Errorf("Remove(root): expected ErrTraversal, got %v", err)
	}
}
