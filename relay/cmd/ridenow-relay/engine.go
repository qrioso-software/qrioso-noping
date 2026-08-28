package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/netip"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/qrioso/ridenow-noping/relay/internal/multipath"
)

type packetDevice interface {
	Read([]byte) (int, error)
	Write([]byte) (int, error)
	Close() error
}

type routeTransport interface {
	ReadFromUDP([]byte) (int, *net.UDPAddr, error)
	WriteToUDP([]byte, *net.UDPAddr) (int, error)
	Close() error
}

type routeEndpoints struct {
	addressA *net.UDPAddr
	addressB *net.UDPAddr
	mode     uint8
	seenAt   time.Time
}

type relayMetrics struct {
	uplinkAccepted    atomic.Uint64
	uplinkDuplicates  atomic.Uint64
	uplinkRejected    atomic.Uint64
	downlinkPackets   atomic.Uint64
	downlinkCopies    atomic.Uint64
	downlinkNoSession atomic.Uint64
}

type relayEngine struct {
	logger    *slog.Logger
	tun       packetDevice
	routeA    routeTransport
	routeB    routeTransport
	sessions  *sessionIndex
	deduper   *multipath.Deduper
	endpoints map[[16]byte]routeEndpoints
	sequences map[[16]byte]uint64
	lastPrune time.Time
	mu        sync.Mutex
	metrics   relayMetrics
}

func newRelayEngine(logger *slog.Logger, tun packetDevice, routeA, routeB routeTransport, sessions *sessionIndex) *relayEngine {
	return &relayEngine{
		logger: logger, tun: tun, routeA: routeA, routeB: routeB, sessions: sessions,
		deduper: multipath.NewDeduper(30 * time.Second), endpoints: make(map[[16]byte]routeEndpoints),
		sequences: make(map[[16]byte]uint64),
	}
}

func (engine *relayEngine) run(ctx context.Context) error {
	errorsChannel := make(chan error, 3)
	go func() { errorsChannel <- engine.readRoute(ctx, engine.routeA, multipath.RouteA) }()
	go func() { errorsChannel <- engine.readRoute(ctx, engine.routeB, multipath.RouteB) }()
	go func() { errorsChannel <- engine.readTUN(ctx) }()
	select {
	case <-ctx.Done():
		_ = engine.routeA.Close()
		_ = engine.routeB.Close()
		_ = engine.tun.Close()
		return nil
	case err := <-errorsChannel:
		if ctx.Err() != nil || errors.Is(err, net.ErrClosed) || errors.Is(err, os.ErrClosed) {
			return nil
		}
		return err
	}
}

func (engine *relayEngine) readRoute(ctx context.Context, transport routeTransport, route uint8) error {
	buffer := make([]byte, multipath.HeaderLength+multipath.MaxPayload)
	for {
		count, remote, err := transport.ReadFromUDP(buffer)
		if err != nil {
			return fmt.Errorf("read route %d: %w", route, err)
		}
		if ctx.Err() != nil {
			return nil
		}
		if err := engine.handleUplink(buffer[:count], remote, route, time.Now()); err != nil {
			engine.metrics.uplinkRejected.Add(1)
			engine.logger.Debug("uplink packet rejected", "route", route, "remote", remote.IP.String(), "error", err)
		}
	}
}

func (engine *relayEngine) handleUplink(encoded []byte, remote *net.UDPAddr, route uint8, now time.Time) error {
	frame, err := multipath.DecodeFrame(encoded)
	if err != nil {
		return err
	}
	if (frame.Flags != multipath.FlagUpstream && frame.Flags != multipath.FlagProbeRequest) || frame.Route != route {
		return errors.New("frame direction or route does not match listener")
	}
	if (frame.Mode == multipath.ModeRouteA && route != multipath.RouteA) || (frame.Mode == multipath.ModeRouteB && route != multipath.RouteB) {
		return errors.New("frame route is disabled by its traffic mode")
	}
	session, ok := engine.sessions.bySessionID(frame.SessionID, now)
	if !ok {
		return errors.New("session is unknown or expired")
	}
	remoteAddress, ok := netip.AddrFromSlice(remote.IP)
	if !ok {
		return errors.New("remote route address is invalid")
	}
	remoteAddress = remoteAddress.Unmap()
	expectedAddress := session.addressA
	if route == multipath.RouteB {
		expectedAddress = session.addressB
	}
	if remoteAddress != expectedAddress {
		return errors.New("remote route address does not belong to the session")
	}
	engine.pruneInactiveSessions(now)
	engine.mu.Lock()
	endpoints := engine.endpoints[frame.SessionID]
	if route == multipath.RouteA {
		endpoints.addressA = cloneUDPAddress(remote)
	} else {
		endpoints.addressB = cloneUDPAddress(remote)
	}
	endpoints.seenAt = now
	endpoints.mode = frame.Mode
	engine.endpoints[frame.SessionID] = endpoints
	engine.mu.Unlock()
	if frame.Flags == multipath.FlagProbeRequest {
		if len(frame.Payload) != 8 {
			return errors.New("route probe payload must contain exactly 8 bytes")
		}
		encodedReply, err := multipath.EncodeFrame(multipath.Frame{
			Flags: multipath.FlagProbeReply, Route: route, Mode: frame.Mode, SessionID: frame.SessionID, Sequence: frame.Sequence, Payload: frame.Payload,
		})
		if err != nil {
			return err
		}
		transport := engine.routeA
		if route == multipath.RouteB {
			transport = engine.routeB
		}
		if _, err := transport.WriteToUDP(encodedReply, remote); err != nil {
			return fmt.Errorf("write route probe reply: %w", err)
		}
		return nil
	}

	packet, err := multipath.ParseIPv4Packet(frame.Payload)
	if err != nil {
		return err
	}
	if packet.Source != session.virtualAddress {
		return errors.New("packet source does not match the assigned virtual address")
	}
	if !multipath.IsPublicGameDestination(packet.Destination) {
		return errors.New("packet destination is not an allowed public game address")
	}

	if !engine.deduper.Accept(frame.SessionID, frame.Sequence) {
		engine.metrics.uplinkDuplicates.Add(1)
		return nil
	}
	if _, err := engine.tun.Write(frame.Payload); err != nil {
		return fmt.Errorf("write TUN packet: %w", err)
	}
	engine.metrics.uplinkAccepted.Add(1)
	return nil
}

func (engine *relayEngine) pruneInactiveSessions(now time.Time) {
	engine.mu.Lock()
	if !engine.lastPrune.IsZero() && now.Sub(engine.lastPrune) < 30*time.Second {
		engine.mu.Unlock()
		return
	}
	engine.lastPrune = now
	ids := make([][16]byte, 0, len(engine.endpoints))
	for id := range engine.endpoints {
		ids = append(ids, id)
	}
	engine.mu.Unlock()

	for _, id := range ids {
		if _, active := engine.sessions.bySessionID(id, now); active {
			continue
		}
		engine.mu.Lock()
		delete(engine.endpoints, id)
		delete(engine.sequences, id)
		engine.mu.Unlock()
	}
}

func (engine *relayEngine) readTUN(ctx context.Context) error {
	buffer := make([]byte, multipath.MaxPayload)
	for {
		count, err := engine.tun.Read(buffer)
		if err != nil {
			return fmt.Errorf("read TUN packet: %w", err)
		}
		if ctx.Err() != nil {
			return nil
		}
		if err := engine.handleDownlink(buffer[:count], time.Now()); err != nil {
			engine.logger.Debug("downlink packet rejected", "error", err)
		}
	}
}

func (engine *relayEngine) handleDownlink(payload []byte, now time.Time) error {
	packet, err := multipath.ParseIPv4Packet(payload)
	if err != nil {
		return err
	}
	if !multipath.IsPublicGameDestination(packet.Source) {
		return errors.New("response source is not a public game address")
	}
	session, ok := engine.sessions.byVirtualAddress(packet.Destination, now)
	if !ok {
		engine.metrics.downlinkNoSession.Add(1)
		return errors.New("response has no active session")
	}
	engine.mu.Lock()
	endpoints := engine.endpoints[session.id]
	sequence := engine.sequences[session.id] + 1
	engine.sequences[session.id] = sequence
	engine.mu.Unlock()
	if endpoints.addressA == nil && endpoints.addressB == nil {
		engine.metrics.downlinkNoSession.Add(1)
		return errors.New("session has no learned route endpoints")
	}

	engine.metrics.downlinkPackets.Add(1)
	var writeError error
	for _, route := range []struct {
		id        uint8
		transport routeTransport
		address   *net.UDPAddr
	}{{multipath.RouteA, engine.routeA, endpoints.addressA}, {multipath.RouteB, engine.routeB, endpoints.addressB}} {
		if route.address == nil {
			continue
		}
		if (endpoints.mode == multipath.ModeRouteA && route.id != multipath.RouteA) || (endpoints.mode == multipath.ModeRouteB && route.id != multipath.RouteB) {
			continue
		}
		encoded, err := multipath.EncodeFrame(multipath.Frame{
			Flags: multipath.FlagDownstream, Route: route.id, Mode: endpoints.mode, SessionID: session.id, Sequence: sequence, Payload: payload,
		})
		if err != nil {
			return err
		}
		if _, err := route.transport.WriteToUDP(encoded, route.address); err != nil {
			writeError = errors.Join(writeError, fmt.Errorf("write route %d: %w", route.id, err))
			continue
		}
		engine.metrics.downlinkCopies.Add(1)
	}
	return writeError
}

func cloneUDPAddress(address *net.UDPAddr) *net.UDPAddr {
	clonedIP := append(net.IP(nil), address.IP...)
	return &net.UDPAddr{IP: clonedIP, Port: address.Port, Zone: address.Zone}
}

var _ io.ReadWriteCloser = (*linuxTUN)(nil)
