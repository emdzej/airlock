package api

import "testing"

func TestBroadcaster_DropsOldestWhenFull(t *testing.T) {
	b := newBroadcaster()
	ch, cancel := b.Subscribe()
	defer cancel()
	for i := 0; i < cap(ch)+5; i++ {
		b.Publish([]byte{byte(i)})
	}
	var last byte
	for len(ch) > 0 {
		last = (<-ch)[0]
	}
	if want := byte(cap(ch) + 4); last != want {
		t.Errorf("newest event lost: last=%d want %d", last, want)
	}
}
