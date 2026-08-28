package multipath

import (
	"bytes"
	"encoding/hex"
	"testing"
)

func TestFrameRoundTrip(t *testing.T) {
	want := Frame{
		Flags: FlagUpstream, Route: RouteB, SessionID: [16]byte{1, 2, 3}, Sequence: 42,
		Payload: []byte{0x45, 0, 0, 20},
	}
	encoded, err := EncodeFrame(want)
	if err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(encoded) != "514e50310101020301020300000000000000000000000000000000000000002a0004000045000014" {
		t.Fatalf("unexpected wire vector: %x", encoded)
	}
	got, err := DecodeFrame(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if got.Flags != want.Flags || got.Route != want.Route || got.Mode != ModeDuplicate || got.SessionID != want.SessionID || got.Sequence != want.Sequence || !bytes.Equal(got.Payload, want.Payload) {
		t.Fatalf("frame mismatch: got=%+v want=%+v", got, want)
	}
}

func TestFrameRejectsMalformedInput(t *testing.T) {
	valid, err := EncodeFrame(Frame{Flags: FlagUpstream, Route: RouteA, SessionID: [16]byte{1}, Payload: []byte{1}})
	if err != nil {
		t.Fatal(err)
	}
	tests := [][]byte{
		nil,
		valid[:HeaderLength-1],
		append([]byte("NOPE"), valid[4:]...),
		append(append([]byte(nil), valid...), 0),
	}
	reserved := append([]byte(nil), valid...)
	reserved[7] = 4
	tests = append(tests, reserved)
	for index, encoded := range tests {
		if _, err := DecodeFrame(encoded); err == nil {
			t.Fatalf("malformed frame %d was accepted", index)
		}
	}
}
