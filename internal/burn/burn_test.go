package burn

import (
	"bytes"
	"compress/gzip"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/emdzej/airlock/internal/flash"
)

func TestParseTOC(t *testing.T) {
	cases := []struct {
		name   string
		out    string
		want   Disc
		wantOK bool
	}{
		{
			name: "blank DVD-R",
			out: `Drive current: -outdev '/dev/sr0'
Media current: DVD-R sequential recording
Media status : is blank
Media blocks : 0 readable , 2298496 writable , 2298496 overall
Media summary: 0 sessions, 0 data blocks, 0 data, 4489m free`,
			want:   Disc{Present: true, Media: "DVD-R sequential recording", Status: "blank", Writable: true, CapacityBytes: 2298496 * 2048},
			wantOK: true,
		},
		{
			name: "written DVD+RW is overwritten",
			out: `Media current: DVD+RW
Media status : is written , is appendable
Media blocks : 1150816 readable , 1147648 writable , 2295104 overall`,
			want:   Disc{Present: true, Media: "DVD+RW", Status: "appendable", Rewritable: true, Writable: true, Erases: true, CapacityBytes: 2295104 * 2048},
			wantOK: true,
		},
		{
			name: "closed CD-R",
			out: `Media current: CD-R
Media status : is written , is closed
Media blocks : 359844 readable , 0 writable , 359844 overall`,
			want:   Disc{Present: true, Media: "CD-R", Status: "closed", Reason: "the disc has already been written; insert a blank or rewritable disc"},
			wantOK: true,
		},
		{
			name: "appendable BD-R",
			out: `Media current: BD-R sequential recording
Media status : is written , is appendable
Media blocks : 14720 readable , 12000000 writable , 12219392 overall`,
			want:   Disc{Present: true, Media: "BD-R sequential recording", Status: "appendable", Reason: "the disc has already been written; insert a blank or rewritable disc"},
			wantOK: true,
		},
		{
			name: "pressed DVD",
			out: `Media current: DVD-ROM
Media status : is written , is closed`,
			want:   Disc{Present: true, Media: "DVD-ROM", Status: "closed", Reason: "this is a pressed (read-only) disc"},
			wantOK: true,
		},
		{
			name: "empty drive",
			out: `Drive current: -outdev '/dev/sr0'
Media current: is not present
Media status : is not present`,
			want:   Disc{Reason: "no disc in the drive"},
			wantOK: true,
		},
		{
			name: "BD-RE",
			out: `Media current: BD-RE
Media status : is blank
Media blocks : 0 readable , 11826176 writable , 11826176 overall`,
			want:   Disc{Present: true, Media: "BD-RE", Status: "blank", Rewritable: true, Writable: true, CapacityBytes: 11826176 * 2048},
			wantOK: true,
		},
		{
			name:   "no drive",
			out:    "xorriso : FAILURE : No input drive acquired on attempt to print Table Of Content",
			wantOK: false,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := parseTOC(c.out)
			if ok != c.wantOK {
				t.Fatalf("ok = %v, want %v", ok, c.wantOK)
			}
			if !reflect.DeepEqual(got, c.want) {
				t.Errorf("got  %+v\nwant %+v", got, c.want)
			}
		})
	}
}

func TestParseSpeeds(t *testing.T) {
	out := `Media current: DVD-R sequential recording
Write speed  :  4234k ,  3.0xD
Write speed  : 22160k , 16.0xD
Write speed  : 11080k ,  8.0xD
Write speed  : 11080k ,  8.0xD
Write speed L:  4234k ,  3.0xD
Write speed H: 22160k , 16.0xD
Read speed L : 11080k ,  8.0xD`
	want := []Speed{{4234, "3x"}, {11080, "8x"}, {22160, "16x"}}
	if got := parseSpeeds(out); !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
	// No list: the best guesses stand in.
	out = "Write speed L :  1764k , 10.0xC\nWrite speed H :  8467k , 48.0xC"
	if got := parseSpeeds(out); !reflect.DeepEqual(got, []Speed{{1764, "10x"}, {8467, "48x"}}) {
		t.Errorf("guesses: got %v", got)
	}
	if got := parseSpeeds("xorriso : NOTE : Output device is not an MMC drive."); got != nil {
		t.Errorf("no speeds: got %v", got)
	}
}

func TestIsRewritable(t *testing.T) {
	for media, want := range map[string]bool{
		"CD-RW": true, "DVD-RW restricted overwrite": true, "DVD+RW": true, "DVD-RAM": true, "BD-RE": true,
		"CD-R": false, "DVD+R/DL": false, "BD-R sequential recording": false, "stdio file, overwriteable": false,
	} {
		if got := isRewritable(media); got != want {
			t.Errorf("isRewritable(%q) = %v", media, got)
		}
	}
}

func TestProgressRE(t *testing.T) {
	m := progressRE.FindStringSubmatch("xorriso : UPDATE :  1234 of  4400 MB written (fifo 95%) [buf 100%]   4.0x.")
	if m == nil || m[1] != "1234" || m[2] != "4400" {
		t.Fatalf("got %q", m)
	}
}

func TestCacheDecodesAndChecksLength(t *testing.T) {
	b := &Burner{dir: t.TempDir()}
	data := bytes.Repeat([]byte("airlock!"), 100000)
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	zw.Write(data)
	zw.Close()

	path, err := b.cache(context.Background(), Request{
		Compression: flash.CompressionGZ, Source: &gz, Size: int64(gz.Len()),
	}, 1<<30, func(string, string) {})
	if err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(path)
	if !bytes.Equal(got, data) {
		t.Fatalf("cached %d bytes, want %d", len(got), len(data))
	}

	// A cut-off upload fails and leaves no file behind.
	_, err = b.cache(context.Background(), Request{
		Compression: flash.CompressionNone, Source: bytes.NewReader(data[:100]), Size: int64(len(data)),
	}, 1<<30, func(string, string) {})
	if err == nil || !strings.Contains(err.Error(), "ended early") {
		t.Fatalf("err = %v, want an early-end error", err)
	}
	// An image larger than the free space is refused.
	_, err = b.cache(context.Background(), Request{
		Compression: flash.CompressionNone, Source: bytes.NewReader(data), Size: -1,
	}, 1000, func(string, string) {})
	if err == nil || !strings.Contains(err.Error(), "not enough room") {
		t.Fatalf("err = %v, want a no-room error", err)
	}
	left, _ := filepath.Glob(filepath.Join(b.dir, "*"))
	if len(left) != 1 { // only the first, successful one
		t.Fatalf("cache holds %v", left)
	}
}

func TestCompareImage(t *testing.T) {
	img := filepath.Join(t.TempDir(), "a.iso")
	data := bytes.Repeat([]byte{1, 2, 3, 4}, 3<<20) // more than one chunk
	os.WriteFile(img, data, 0o600)

	// The disc may carry more than the image (padding, run-out blocks).
	disc := append(append([]byte{}, data...), 0, 0, 0)
	if err := compareImage(context.Background(), bytes.NewReader(disc), img, int64(len(data)), func(Event) {}); err != nil {
		t.Fatal(err)
	}
	disc[5<<20] ^= 0xff
	err := compareImage(context.Background(), bytes.NewReader(disc), img, int64(len(data)), func(Event) {})
	if err == nil || !strings.Contains(err.Error(), "at byte 5242880") {
		t.Fatalf("err = %v", err)
	}
	err = compareImage(context.Background(), bytes.NewReader(data[:1000]), img, int64(len(data)), func(Event) {})
	if err == nil || !strings.Contains(err.Error(), "read disc") {
		t.Fatalf("err = %v", err)
	}
}

// TestBurnImageStdio burns into a file with xorriso's stdio: pseudo-drive,
// when xorriso is installed.
func TestBurnImageStdio(t *testing.T) {
	if _, err := exec.LookPath("xorriso"); err != nil {
		t.Skip("xorriso not installed")
	}
	dir := t.TempDir()
	img := filepath.Join(dir, "a.iso")
	data := bytes.Repeat([]byte("0123456789abcdef"), 3<<16) // 3 MiB
	os.WriteFile(img, data, 0o600)
	target := filepath.Join(dir, "disc.img")
	os.WriteFile(target, nil, 0o600)

	var events []Event
	err := burnImage(context.Background(), "stdio:"+target, img, int64(len(data)), true, 1385, func(e Event) { events = append(events, e) })
	if err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(target)
	if !bytes.HasPrefix(got, data) {
		t.Fatalf("target holds %d bytes not starting with the image", len(got))
	}
	var lines int
	for _, e := range events {
		if e.Stage == "line" {
			lines++
		}
	}
	if lines == 0 {
		t.Error("no xorriso output relayed")
	}

	disc, err := Inspect(context.Background(), "stdio:"+target)
	if err != nil {
		t.Fatal(err)
	}
	// Disc-at-once closes the disc.
	if !disc.Present || disc.Status != "closed" || disc.Writable {
		t.Errorf("after burn: %+v", disc)
	}
}
