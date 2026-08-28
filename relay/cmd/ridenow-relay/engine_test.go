package main

import (
	"encoding/base64"
	"encoding/binary"
	"io"
	"log/slog"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/qrioso/ridenow-noping/relay/internal/multipath"
	"github.com/qrioso/ridenow-noping/relay/internal/sessionstore"
)

type fakeTUN struct {
	mu     sync.Mutex
	writes [][]byte
}

func (tun *fakeTUN) Read([]byte) (int, error) { return 0, io.EOF }
func (tun *fakeTUN) Close() error             { return nil }
func (tun *fakeTUN) Write(packet []byte) (int, error) {
	tun.mu.Lock()
	tun.writes = append(tun.writes, append([]byte(nil), packet...))
	tun.mu.Unlock()
	return len(packet), nil
}

type fakeRoute struct {
	mu     sync.Mutex
	writes [][]byte
}

func (route *fakeRoute) ReadFromUDP([]byte) (int, *net.UDPAddr, error) { return 0, nil, net.ErrClosed }
func (route *fakeRoute) Close() error                                  { return nil }
func (route *fakeRoute) WriteToUDP(packet []byte, _ *net.UDPAddr) (int, error) {
	route.mu.Lock()
	route.writes = append(route.writes, append([]byte(nil), packet...))
	route.mu.Unlock()
	return len(packet), nil
}

func TestRelayFirstArrivalWinsAndDuplicatesDownlink(t *testing.T) {
	now := time.Unix(100, 0)
	sessionID := [16]byte{1, 2, 3}
	index := relayTestIndex(t, sessionID, now)
	tun := &fakeTUN{}
	routeA := &fakeRoute{}
	routeB := &fakeRoute{}
	engine := newRelayEngine(slog.New(slog.NewTextHandler(io.Discard, nil)), tun, routeA, routeB, index)
	uplink := relayTestIPv4UDP([4]byte{10, 80, 0, 2}, [4]byte{8, 8, 8, 8})
	for _, route := range []struct {
		id     uint8
		remote *net.UDPAddr
	}{{multipath.RouteA, &net.UDPAddr{IP: net.ParseIP("10.78.0.2"), Port: 40001}}, {multipath.RouteB, &net.UDPAddr{IP: net.ParseIP("10.79.0.2"), Port: 40002}}} {
		encoded, err := multipath.EncodeFrame(multipath.Frame{
			Flags: multipath.FlagUpstream, Route: route.id, SessionID: sessionID, Sequence: 7, Payload: uplink,
		})
		if err != nil {
			t.Fatal(err)
		}
		if err := engine.handleUplink(encoded, route.remote, route.id, now); err != nil {
			t.Fatal(err)
		}
	}
	if len(tun.writes) != 1 || engine.metrics.uplinkDuplicates.Load() != 1 {
		t.Fatalf("first-arrival-wins failed: writes=%d duplicates=%d", len(tun.writes), engine.metrics.uplinkDuplicates.Load())
	}
	downlink := relayTestIPv4UDP([4]byte{8, 8, 8, 8}, [4]byte{10, 80, 0, 2})
	if err := engine.handleDownlink(downlink, now); err != nil {
		t.Fatal(err)
	}
	if len(routeA.writes) != 1 || len(routeB.writes) != 1 {
		t.Fatalf("downlink was not duplicated: routeA=%d routeB=%d", len(routeA.writes), len(routeB.writes))
	}
	for _, encoded := range [][]byte{routeA.writes[0], routeB.writes[0]} {
		frame, err := multipath.DecodeFrame(encoded)
		if err != nil || frame.Flags != multipath.FlagDownstream {
			t.Fatalf("invalid downstream frame: frame=%+v err=%v", frame, err)
		}
	}
}

func TestRelayRejectsSpoofedSourceAndInternalDestination(t *testing.T) {
	now := time.Unix(100, 0)
	sessionID := [16]byte{1}
	index := relayTestIndex(t, sessionID, now)
	engine := newRelayEngine(slog.New(slog.NewTextHandler(io.Discard, nil)), &fakeTUN{}, &fakeRoute{}, &fakeRoute{}, index)
	for _, packet := range [][]byte{
		relayTestIPv4UDP([4]byte{10, 80, 0, 3}, [4]byte{8, 8, 8, 8}),
		relayTestIPv4UDP([4]byte{10, 80, 0, 2}, [4]byte{169, 254, 169, 254}),
	} {
		encoded, err := multipath.EncodeFrame(multipath.Frame{Flags: multipath.FlagUpstream, Route: multipath.RouteA, SessionID: sessionID, Sequence: 1, Payload: packet})
		if err != nil {
			t.Fatal(err)
		}
		if err := engine.handleUplink(encoded, &net.UDPAddr{IP: net.ParseIP("10.78.0.2"), Port: 40001}, multipath.RouteA, now); err == nil {
			t.Fatal("unsafe packet was accepted")
		}
	}
}

func TestRelayReturnsProbeOnTheSameAuthenticatedRoute(t *testing.T) {
	now := time.Unix(100, 0)
	sessionID := [16]byte{1, 2, 3}
	routeA := &fakeRoute{}
	engine := newRelayEngine(
		slog.New(slog.NewTextHandler(io.Discard, nil)),
		&fakeTUN{},
		routeA,
		&fakeRoute{},
		relayTestIndex(t, sessionID, now),
	)
	payload := []byte{0, 1, 2, 3, 4, 5, 6, 7}
	encoded, err := multipath.EncodeFrame(multipath.Frame{
		Flags: multipath.FlagProbeRequest, Route: multipath.RouteA, SessionID: sessionID, Sequence: 9, Payload: payload,
	})
	if err != nil {
		t.Fatal(err)
	}
	remote := &net.UDPAddr{IP: net.ParseIP("10.78.0.2"), Port: 40001}
	if err := engine.handleUplink(encoded, remote, multipath.RouteA, now); err != nil {
		t.Fatal(err)
	}
	if len(routeA.writes) != 1 {
		t.Fatalf("expected one probe reply, got %d", len(routeA.writes))
	}
	reply, err := multipath.DecodeFrame(routeA.writes[0])
	if err != nil || reply.Flags != multipath.FlagProbeReply || reply.Sequence != 9 || string(reply.Payload) != string(payload) {
		t.Fatalf("invalid probe reply: frame=%+v err=%v", reply, err)
	}
}

func TestRelayHonorsSinglePathModeForDownlink(t *testing.T) {
	now := time.Unix(100, 0)
	sessionID := [16]byte{7}
	routeA := &fakeRoute{}
	routeB := &fakeRoute{}
	engine := newRelayEngine(slog.New(slog.NewTextHandler(io.Discard, nil)), &fakeTUN{}, routeA, routeB, relayTestIndex(t, sessionID, now))
	uplink := relayTestIPv4UDP([4]byte{10, 80, 0, 2}, [4]byte{8, 8, 8, 8})
	encoded, err := multipath.EncodeFrame(multipath.Frame{
		Flags: multipath.FlagUpstream, Route: multipath.RouteA, Mode: multipath.ModeRouteA,
		SessionID: sessionID, Sequence: 1, Payload: uplink,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := engine.handleUplink(encoded, &net.UDPAddr{IP: net.ParseIP("10.78.0.2"), Port: 40001}, multipath.RouteA, now); err != nil {
		t.Fatal(err)
	}
	if err := engine.handleDownlink(relayTestIPv4UDP([4]byte{8, 8, 8, 8}, [4]byte{10, 80, 0, 2}), now); err != nil {
		t.Fatal(err)
	}
	if len(routeA.writes) != 1 || len(routeB.writes) != 0 {
		t.Fatalf("single-path downlink used unexpected routes: A=%d B=%d", len(routeA.writes), len(routeB.writes))
	}
}

func relayTestIndex(t *testing.T, sessionID [16]byte, now time.Time) *sessionIndex {
	t.Helper()
	index := newSessionIndex()
	err := index.replace(sessionstore.Snapshot{Version: 1, GeneratedAt: now, Sessions: []sessionstore.Session{{
		ID: base64.RawURLEncoding.EncodeToString(sessionID[:]), KeyID: "id", Fingerprint: "fp", PublicKeyA: "a", PublicKeyB: "b",
		ClientAddressA: "10.78.0.2", ClientAddressB: "10.79.0.2", VirtualAddress: "10.80.0.2", ExpiresAt: now.Add(time.Minute),
	}}})
	if err != nil {
		t.Fatal(err)
	}
	return index
}

func relayTestIPv4UDP(source, destination [4]byte) []byte {
	packet := make([]byte, 28)
	packet[0] = 0x45
	binary.BigEndian.PutUint16(packet[2:4], uint16(len(packet)))
	packet[8] = 64
	packet[9] = 17
	copy(packet[12:16], source[:])
	copy(packet[16:20], destination[:])
	binary.BigEndian.PutUint16(packet[24:26], 8)
	return packet
}
