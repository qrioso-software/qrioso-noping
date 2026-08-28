package main

import (
	"fmt"
	"net/netip"
	"sync"
	"time"

	"github.com/qrioso/ridenow-noping/relay/internal/sessionstore"
)

type relaySession struct {
	id             [16]byte
	virtualAddress netip.Addr
	addressA       netip.Addr
	addressB       netip.Addr
	expiresAt      time.Time
}

type sessionIndex struct {
	mu        sync.RWMutex
	byID      map[[16]byte]relaySession
	byVirtual map[netip.Addr]relaySession
}

func newSessionIndex() *sessionIndex {
	return &sessionIndex{byID: make(map[[16]byte]relaySession), byVirtual: make(map[netip.Addr]relaySession)}
}

func (index *sessionIndex) replace(snapshot sessionstore.Snapshot) error {
	byID := make(map[[16]byte]relaySession, len(snapshot.Sessions))
	byVirtual := make(map[netip.Addr]relaySession, len(snapshot.Sessions))
	for _, stored := range snapshot.Sessions {
		id, err := sessionstore.DecodeSessionID(stored.ID)
		if err != nil {
			return err
		}
		addressA, err := netip.ParseAddr(stored.ClientAddressA)
		if err != nil {
			return fmt.Errorf("parse route A address: %w", err)
		}
		addressB, err := netip.ParseAddr(stored.ClientAddressB)
		if err != nil {
			return fmt.Errorf("parse route B address: %w", err)
		}
		virtualAddress, err := netip.ParseAddr(stored.VirtualAddress)
		if err != nil {
			return fmt.Errorf("parse virtual address: %w", err)
		}
		session := relaySession{id: id, addressA: addressA, addressB: addressB, virtualAddress: virtualAddress, expiresAt: stored.ExpiresAt}
		byID[id] = session
		byVirtual[virtualAddress] = session
	}
	index.mu.Lock()
	index.byID = byID
	index.byVirtual = byVirtual
	index.mu.Unlock()
	return nil
}

func (index *sessionIndex) clear() {
	index.mu.Lock()
	index.byID = make(map[[16]byte]relaySession)
	index.byVirtual = make(map[netip.Addr]relaySession)
	index.mu.Unlock()
}

func (index *sessionIndex) bySessionID(id [16]byte, now time.Time) (relaySession, bool) {
	index.mu.RLock()
	session, exists := index.byID[id]
	index.mu.RUnlock()
	return session, exists && session.expiresAt.After(now)
}

func (index *sessionIndex) byVirtualAddress(address netip.Addr, now time.Time) (relaySession, bool) {
	index.mu.RLock()
	session, exists := index.byVirtual[address]
	index.mu.RUnlock()
	return session, exists && session.expiresAt.After(now)
}
