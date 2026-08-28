package multipath

import (
	"testing"
	"time"
)

func TestFirstArrivalWins(t *testing.T) {
	deduper := NewDeduper(100 * time.Millisecond)
	now := time.Unix(100, 0)
	deduper.clock = func() time.Time { return now }

	if !deduper.Accept(7, 42) {
		t.Fatal("first copy must be accepted")
	}
	if deduper.Accept(7, 42) {
		t.Fatal("duplicate copy must be rejected")
	}
	if !deduper.Accept(7, 43) {
		t.Fatal("next sequence must be accepted")
	}

	now = now.Add(101 * time.Millisecond)
	if !deduper.Accept(7, 42) {
		t.Fatal("expired sequence must leave the deduplication window")
	}
}
