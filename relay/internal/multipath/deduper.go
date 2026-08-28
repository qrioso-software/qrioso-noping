package multipath

import (
	"sync"
	"time"
)

const maxDedupEntriesPerSession = 65536

type seenPacket struct {
	sequence uint64
	seenAt   time.Time
}

type sessionWindow struct {
	entries map[uint64]time.Time
	queue   []seenPacket
	head    int
	lastAt  time.Time
}

// Deduper implements a bounded first-arrival-wins window per session. Cleanup
// is amortized O(1); an abusive session is dropped closed at the capacity limit
// instead of growing memory without bound.
type Deduper struct {
	mu       sync.Mutex
	window   time.Duration
	clock    func() time.Time
	sessions map[[16]byte]*sessionWindow
	lastGC   time.Time
}

func NewDeduper(window time.Duration) *Deduper {
	return &Deduper{window: window, clock: time.Now, sessions: make(map[[16]byte]*sessionWindow)}
}

// Accept returns true only for the first copy observed inside the configured window.
func (deduper *Deduper) Accept(sessionID [16]byte, sequence uint64) bool {
	deduper.mu.Lock()
	defer deduper.mu.Unlock()

	now := deduper.clock()
	if deduper.lastGC.IsZero() || now.Sub(deduper.lastGC) > deduper.window {
		for id, candidate := range deduper.sessions {
			if now.Sub(candidate.lastAt) > deduper.window {
				delete(deduper.sessions, id)
			}
		}
		deduper.lastGC = now
	}
	state := deduper.sessions[sessionID]
	if state == nil || now.Sub(state.lastAt) > deduper.window {
		state = &sessionWindow{entries: make(map[uint64]time.Time)}
		deduper.sessions[sessionID] = state
	}
	state.lastAt = now
	cutoff := now.Add(-deduper.window)
	for state.head < len(state.queue) && state.queue[state.head].seenAt.Before(cutoff) {
		expired := state.queue[state.head]
		state.head++
		if current, exists := state.entries[expired.sequence]; exists && current.Equal(expired.seenAt) {
			delete(state.entries, expired.sequence)
		}
	}
	if state.head > 4096 && state.head*2 >= len(state.queue) {
		state.queue = append([]seenPacket(nil), state.queue[state.head:]...)
		state.head = 0
	}

	if _, exists := state.entries[sequence]; exists {
		return false
	}
	if len(state.entries) >= maxDedupEntriesPerSession {
		return false
	}
	state.entries[sequence] = now
	state.queue = append(state.queue, seenPacket{sequence: sequence, seenAt: now})
	return true
}
