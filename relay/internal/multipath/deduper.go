package multipath

import (
	"sync"
	"time"
)

type packetKey struct {
	sessionID uint64
	sequence  uint64
}

// Deduper implements the first-arrival-wins primitive used by the future data plane.
type Deduper struct {
	mu      sync.Mutex
	window  time.Duration
	clock   func() time.Time
	entries map[packetKey]time.Time
}

func NewDeduper(window time.Duration) *Deduper {
	return &Deduper{
		window:  window,
		clock:   time.Now,
		entries: make(map[packetKey]time.Time),
	}
}

// Accept returns true only for the first copy observed inside the configured window.
func (d *Deduper) Accept(sessionID, sequence uint64) bool {
	d.mu.Lock()
	defer d.mu.Unlock()

	now := d.clock()
	for key, seenAt := range d.entries {
		if now.Sub(seenAt) > d.window {
			delete(d.entries, key)
		}
	}

	key := packetKey{sessionID: sessionID, sequence: sequence}
	if _, exists := d.entries[key]; exists {
		return false
	}
	d.entries[key] = now
	return true
}
