package burn

import (
	"context"
	"fmt"
	"os/exec"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

// Disc describes the medium in an optical drive, as far as burning an
// image onto it goes.
type Disc struct {
	Present    bool   `json:"present"`
	Media      string `json:"media,omitempty"`  // "DVD+RW", "CD-R", "BD-R", ...
	Status     string `json:"status,omitempty"` // "blank", "appendable", "closed", "unknown"
	Rewritable bool   `json:"rewritable"`
	// CapacityBytes is the room an image gets: the free space of a blank
	// disc, or the whole of a rewritable one (it is overwritten).
	CapacityBytes int64 `json:"capacity_bytes"`
	// Writable reports whether an image can be burned onto this disc;
	// Reason says why not.
	Writable bool   `json:"writable"`
	Reason   string `json:"reason,omitempty"`
	// Erases is set when burning overwrites what's on the disc now.
	Erases bool `json:"erases"`
	// Speeds are the write speeds the drive offers for this disc, slowest
	// first; empty when it reports none (burn at the drive's maximum).
	Speeds []Speed `json:"speeds,omitempty"`
}

// Speed is one write speed a drive offers.
type Speed struct {
	KBps  int    `json:"kbps"`  // MMC kB/s (1000 bytes), what xorriso's speed= takes with a "k"
	Label string `json:"label"` // "8x", "16x"
}

// sectorSize is the size of an optical data block; xorriso counts in them.
const sectorSize = 2048

// Inspect asks xorriso what's in the drive. Shared, read-only access
// works while the disc is mounted and can't change the medium.
func Inspect(ctx context.Context, dev string) (Disc, error) {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "xorriso",
		"-abort_on", "NEVER",
		"-drive_access", "shared:readonly",
		"-outdev", dev,
		"-toc",
		"-list_speeds")
	out, err := cmd.CombinedOutput()
	disc, ok := parseTOC(string(out))
	if !ok {
		if err != nil {
			return Disc{}, fmt.Errorf("xorriso: %w: %s", err, lastLines(string(out), 3))
		}
		return Disc{}, fmt.Errorf("xorriso reported no drive status: %s", lastLines(string(out), 3))
	}
	if disc.Writable {
		// An empty drive or a pressed disc lists speeds for other media.
		disc.Speeds = parseSpeeds(string(out))
	}
	return disc, nil
}

// parseTOC reads the "Media ..." lines of `xorriso -toc`:
//
//	Media current: DVD+RW
//	Media status : is written , is appendable
//	Media blocks : 1150816 readable , 1147648 writable , 2295104 overall
//
// ok is false when the output carries no media status at all (no drive).
func parseTOC(out string) (d Disc, ok bool) {
	var writable, overall int64
	for _, line := range strings.Split(out, "\n") {
		key, val, found := strings.Cut(line, ":")
		if !found {
			continue
		}
		val = strings.TrimSpace(val)
		switch strings.TrimSpace(key) {
		case "Media current":
			d.Media = val
		case "Media status":
			ok = true
			switch {
			case strings.Contains(val, "not present"):
				d.Status = ""
			case strings.Contains(val, "is blank"):
				d.Status = "blank"
			case strings.Contains(val, "is appendable"):
				d.Status = "appendable"
			case strings.Contains(val, "is closed"):
				d.Status = "closed"
			default:
				d.Status = "unknown"
			}
		case "Media blocks":
			// "<n> readable , <n> writable , <n> overall"
			for _, part := range strings.Split(val, ",") {
				f := strings.Fields(part)
				if len(f) != 2 {
					continue
				}
				n, err := strconv.ParseInt(f[0], 10, 64)
				if err != nil {
					continue
				}
				switch f[1] {
				case "writable":
					writable = n
				case "overall":
					overall = n
				}
			}
		}
	}
	if !ok {
		return Disc{}, false
	}
	if strings.Contains(d.Media, "not present") || d.Status == "" {
		return Disc{Reason: "no disc in the drive"}, true
	}
	if strings.Contains(d.Media, "not recognizable") || d.Media == "" {
		d.Present = true
		d.Status = "unknown"
		d.Reason = "the drive can't identify this disc"
		return d, true
	}
	d.Present = true
	d.Rewritable = isRewritable(d.Media)
	switch {
	case strings.HasSuffix(d.Media, "-ROM"):
		d.Reason = "this is a pressed (read-only) disc"
	case d.Status == "blank":
		d.Writable = true
		d.CapacityBytes = writable * sectorSize
	case d.Rewritable:
		// Rewritable media get blanked or overwritten from the start.
		d.Writable = true
		d.Erases = true
		d.CapacityBytes = overall * sectorSize
	default:
		// An image must start at the beginning of the disc: appending it
		// as a later session leaves a disc nothing can read.
		d.Reason = "the disc has already been written; insert a blank or rewritable disc"
	}
	return d, true
}

// speedRE matches xorriso's -list_speeds write lines, e.g.
// "Write speed  : 11080k ,  8.0xD" or "Write speed H: 22160k , 16.0xD".
var speedRE = regexp.MustCompile(`^Write speed\s*([LHlh]?)\s*:\s*(\d+)k\s*,\s*([\d.]+)x`)

// parseSpeeds collects the drive's write speeds, slowest first. The
// plain "Write speed" lines are the drive's list; when there are none,
// the L / H best guesses stand in.
func parseSpeeds(out string) []Speed {
	var listed, guessed []Speed
	for _, line := range strings.Split(out, "\n") {
		m := speedRE.FindStringSubmatch(strings.TrimSpace(line))
		if m == nil {
			continue
		}
		kbps, err := strconv.Atoi(m[2])
		if err != nil || kbps <= 0 {
			continue
		}
		x, _ := strconv.ParseFloat(m[3], 64)
		sp := Speed{KBps: kbps, Label: strconv.FormatFloat(x, 'f', -1, 64) + "x"}
		if m[1] == "" {
			listed = append(listed, sp)
		} else {
			guessed = append(guessed, sp)
		}
	}
	if len(listed) == 0 {
		listed = guessed
	}
	slices.SortFunc(listed, func(a, b Speed) int { return a.KBps - b.KBps })
	return slices.CompactFunc(listed, func(a, b Speed) bool { return a.KBps == b.KBps })
}

// isRewritable reports whether a media name from xorriso is erasable:
// CD-RW, DVD-RW, DVD+RW, DVD-RAM, BD-RE.
func isRewritable(media string) bool {
	// The type is the first word: "DVD-RW sequential recording".
	f := strings.Fields(strings.ToUpper(media))
	if len(f) == 0 {
		return false
	}
	for _, suf := range []string{"-RW", "+RW", "-RE", "-RAM"} {
		if strings.HasSuffix(f[0], suf) {
			return true
		}
	}
	return false
}

// lastLines returns up to n trailing non-empty lines of s, joined by "; ".
func lastLines(s string, n int) string {
	var keep []string
	for _, l := range strings.Split(s, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			keep = append(keep, l)
		}
	}
	if len(keep) > n {
		keep = keep[len(keep)-n:]
	}
	return strings.Join(keep, "; ")
}
