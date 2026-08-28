package multipath

import (
	"testing"
	"time"
)

func TestFirstArrivalWins(t *testing.T) {
	deduper := NewDeduper(100 * time.Millisecond)
	now := time.Unix(100, 0)
	deduper.clock = func() time.Time { return now }
	sessionID := [16]byte{7}

	if !deduper.Accept(sessionID, 42) {
		t.Fatal("first copy must be accepted")
	}
	if deduper.Accept(sessionID, 42) {
		t.Fatal("duplicate copy must be rejected")
	}
	if !deduper.Accept(sessionID, 43) {
		t.Fatal("next sequence must be accepted")
	}

	now = now.Add(101 * time.Millisecond)
	if !deduper.Accept(sessionID, 42) {
		t.Fatal("expired sequence must leave the deduplication window")
	}
}

func TestDeduperFailsClosedAtPerSessionCapacity(t *testing.T) {
	deduper := NewDeduper(time.Minute)
	now := time.Unix(100, 0)
	deduper.clock = func() time.Time { return now }
	sessionID := [16]byte{9}
	for sequence := uint64(0); sequence < maxDedupEntriesPerSession; sequence++ {
		if !deduper.Accept(sessionID, sequence) {
			t.Fatalf("sequence %d was rejected before the capacity limit", sequence)
		}
	}
	if deduper.Accept(sessionID, maxDedupEntriesPerSession) {
		t.Fatal("deduper accepted traffic beyond its bounded capacity")
	}
}
