package api

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/emdzej/airlock/internal/mount"
)

// broadcaster fans a drive-list snapshot out to every currently-
// subscribed SSE client. Subscribers get a buffered channel; slow
// consumers lose their *oldest* queued event rather than back-pressuring
// the producer. Every event is a full snapshot, so the newest one is the
// one that must get through.
type broadcaster struct {
	mu   sync.Mutex
	subs map[chan []byte]struct{}
}

func newBroadcaster() *broadcaster {
	return &broadcaster{subs: make(map[chan []byte]struct{})}
}

// Subscribe registers a new listener. The returned channel receives
// serialized event payloads; the cancel function must be called to
// drop the subscription and free resources.
func (b *broadcaster) Subscribe() (<-chan []byte, func()) {
	ch := make(chan []byte, 16)
	b.mu.Lock()
	b.subs[ch] = struct{}{}
	b.mu.Unlock()
	return ch, func() {
		b.mu.Lock()
		if _, ok := b.subs[ch]; ok {
			delete(b.subs, ch)
			close(ch)
		}
		b.mu.Unlock()
	}
}

// Publish delivers msg to every current subscriber without blocking. A
// full subscriber buffer has its oldest entry discarded to make room.
func (b *broadcaster) Publish(msg []byte) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for ch := range b.subs {
		for {
			select {
			case ch <- msg:
			default:
				select {
				case <-ch: // discard oldest, retry
				default:
				}
				continue
			}
			break
		}
	}
}

// PublishDrives is a convenience: JSON-marshals the current drive
// snapshot and broadcasts. Called from main.go's mount listener.
func (s *Server) PublishDrives(snap mount.Snapshot) {
	payload := s.drivesEventPayload(snap)
	buf, err := json.Marshal(payload)
	if err != nil {
		slog.Warn("sse: marshal drives", "err", err)
		return
	}
	s.events.Publish(buf)
}

// drivesEventPayload wraps the current drive list in an event
// envelope so the client can distinguish event types in the future
// (e.g. later: format-progress, flash-progress) without reshaping
// the top level.
func (s *Server) drivesEventPayload(snap mount.Snapshot) map[string]any {
	out := make([]drivePayload, 0, len(snap.Drives))
	for _, d := range snap.Drives {
		out = append(out, payloadFor(d))
	}
	return map[string]any{
		"type":   "drives",
		"drives": out,
	}
}

// GET /api/events
// Streams drive-list changes as Server-Sent Events. First event is the
// current snapshot; subsequent events are broadcast when the daemon's
// mount listener fires.
//
// Format per SSE spec: `data: <json>\n\n`. A comment line `: heartbeat\n\n`
// goes out every 30 s to keep NATs / proxies from silently timing out
// the connection.
func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	flusher, ok := w.(http.Flusher)
	if !ok {
		return
	}

	sub, cancel := s.events.Subscribe()
	defer cancel()

	// Prime the connection with the current snapshot so freshly-
	// connected clients don't need to also do a REST call.
	initial, _ := json.Marshal(s.drivesEventPayload(s.mgr.Snapshot()))
	if _, err := fmt.Fprintf(w, "data: %s\n\n", initial); err != nil {
		return
	}
	flusher.Flush()

	heartbeat := time.NewTicker(30 * time.Second)
	defer heartbeat.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-s.closing:
			return
		case <-heartbeat.C:
			if _, err := fmt.Fprint(w, ": heartbeat\n\n"); err != nil {
				return
			}
			flusher.Flush()
		case msg, open := <-sub:
			if !open {
				return
			}
			if _, err := fmt.Fprintf(w, "data: %s\n\n", msg); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}
