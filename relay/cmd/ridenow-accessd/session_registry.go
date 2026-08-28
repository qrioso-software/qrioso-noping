package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"sort"
	"sync"
	"time"

	"github.com/qrioso/ridenow-noping/relay/internal/sessionstore"
)

type deviceLease struct {
	keyID          string
	fingerprint    string
	deviceID       string
	sessionID      string
	publicKeyA     string
	publicKeyB     string
	clientAddressA string
	clientAddressB string
	virtualAddress string
	createdAt      time.Time
	expiresAt      time.Time
}

type leaseRegistry struct {
	mu         sync.Mutex
	duration   time.Duration
	maxClients int
	byKeyID    map[string]map[string]deviceLease
}

func newLeaseRegistry(duration time.Duration, maxClients int) *leaseRegistry {
	return &leaseRegistry{
		duration:   duration,
		maxClients: maxClients,
		byKeyID:    make(map[string]map[string]deviceLease),
	}
}

// grant uses the two WireGuard public keys as the stable device slot. A
// caller-controlled display name cannot be reused to bypass MaxDevices.
func (registry *leaseRegistry) grant(keyID, deviceID, fingerprint string, maxDevices int, now time.Time) bool {
	_, granted, err := registry.grantLease(keyID, deviceID, fingerprint, "test-key-a", "test-key-b", maxDevices, now)
	return err == nil && granted
}

func (registry *leaseRegistry) grantLease(keyID, deviceID, fingerprint, publicKeyA, publicKeyB string, maxDevices int, now time.Time) (deviceLease, bool, error) {
	registry.mu.Lock()
	defer registry.mu.Unlock()

	registry.purgeExpiredLocked(now)
	activeClients := registry.activeCountLocked()

	if maxDevices < 1 || registry.maxClients < 1 {
		return deviceLease{}, false, nil
	}
	devices := registry.byKeyID[keyID]
	lease, exists := devices[fingerprint]
	if exists {
		// If an operator lowers either limit, do not extend excess leases. They
		// expire within the short lease window and the registry converges closed.
		if len(devices) > maxDevices || activeClients > registry.maxClients {
			return deviceLease{}, false, nil
		}
		lease.deviceID = deviceID
		lease.expiresAt = now.Add(registry.duration)
		devices[fingerprint] = lease
		return lease, true, nil
	}
	if len(devices) >= maxDevices || activeClients >= registry.maxClients {
		return deviceLease{}, false, nil
	}
	if devices == nil {
		devices = make(map[string]deviceLease)
		registry.byKeyID[keyID] = devices
	}
	slot, ok := registry.availableSlotLocked()
	if !ok {
		return deviceLease{}, false, nil
	}
	randomID := make([]byte, 16)
	if _, err := rand.Read(randomID); err != nil {
		return deviceLease{}, false, fmt.Errorf("generate session id: %w", err)
	}
	lease = deviceLease{
		keyID: keyID, fingerprint: fingerprint, deviceID: deviceID,
		sessionID: base64.RawURLEncoding.EncodeToString(randomID), publicKeyA: publicKeyA, publicKeyB: publicKeyB,
		clientAddressA: fmt.Sprintf("10.78.0.%d", slot), clientAddressB: fmt.Sprintf("10.79.0.%d", slot),
		virtualAddress: fmt.Sprintf("10.80.0.%d", slot), createdAt: now, expiresAt: now.Add(registry.duration),
	}
	devices[fingerprint] = lease
	return lease, true, nil
}

func (registry *leaseRegistry) release(keyID, fingerprint string) (deviceLease, bool) {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	devices := registry.byKeyID[keyID]
	lease, exists := devices[fingerprint]
	if exists {
		delete(devices, fingerprint)
		if len(devices) == 0 {
			delete(registry.byKeyID, keyID)
		}
	}
	return lease, exists
}

func (registry *leaseRegistry) reconcile(allowed map[string]int, now time.Time) []deviceLease {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	removed := registry.purgeExpiredLocked(now)
	for keyID, devices := range registry.byKeyID {
		limit, authorized := allowed[keyID]
		if !authorized || limit < 1 {
			for fingerprint, lease := range devices {
				removed = append(removed, lease)
				delete(devices, fingerprint)
			}
			delete(registry.byKeyID, keyID)
			continue
		}
		if len(devices) <= limit {
			continue
		}
		ordered := make([]deviceLease, 0, len(devices))
		for _, lease := range devices {
			ordered = append(ordered, lease)
		}
		sort.Slice(ordered, func(left, right int) bool {
			if ordered[left].createdAt.Equal(ordered[right].createdAt) {
				return ordered[left].fingerprint < ordered[right].fingerprint
			}
			return ordered[left].createdAt.Before(ordered[right].createdAt)
		})
		for _, lease := range ordered[limit:] {
			delete(devices, lease.fingerprint)
			removed = append(removed, lease)
		}
	}
	return removed
}

func (registry *leaseRegistry) snapshot(now time.Time) []sessionstore.Session {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	registry.purgeExpiredLocked(now)
	sessions := make([]sessionstore.Session, 0, registry.activeCountLocked())
	for _, devices := range registry.byKeyID {
		for _, lease := range devices {
			sessions = append(sessions, lease.stored())
		}
	}
	return sessions
}

func (registry *leaseRegistry) expire(now time.Time) []deviceLease {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	return registry.purgeExpiredLocked(now)
}

func (registry *leaseRegistry) purgeExpiredLocked(now time.Time) []deviceLease {
	var removed []deviceLease
	for keyID, devices := range registry.byKeyID {
		for fingerprint, lease := range devices {
			if !lease.expiresAt.After(now) {
				removed = append(removed, lease)
				delete(devices, fingerprint)
			}
		}
		if len(devices) == 0 {
			delete(registry.byKeyID, keyID)
		}
	}
	return removed
}

func (registry *leaseRegistry) activeCountLocked() int {
	count := 0
	for _, devices := range registry.byKeyID {
		count += len(devices)
	}
	return count
}

func (registry *leaseRegistry) availableSlotLocked() (int, bool) {
	used := make(map[int]struct{}, registry.maxClients)
	for _, devices := range registry.byKeyID {
		for _, lease := range devices {
			var slot int
			if _, err := fmt.Sscanf(lease.virtualAddress, "10.80.0.%d", &slot); err == nil {
				used[slot] = struct{}{}
			}
		}
	}
	for slot := 2; slot < 2+registry.maxClients; slot++ {
		if _, exists := used[slot]; !exists {
			return slot, true
		}
	}
	return 0, false
}

func (lease deviceLease) stored() sessionstore.Session {
	return sessionstore.Session{
		ID: lease.sessionID, KeyID: lease.keyID, Fingerprint: lease.fingerprint,
		PublicKeyA: lease.publicKeyA, PublicKeyB: lease.publicKeyB,
		ClientAddressA: lease.clientAddressA, ClientAddressB: lease.clientAddressB,
		VirtualAddress: lease.virtualAddress, ExpiresAt: lease.expiresAt.UTC(),
	}
}

func peerFingerprint(publicKeyA, publicKeyB string) (string, error) {
	keyA, err := decodeWireGuardPublicKey(publicKeyA)
	if err != nil {
		return "", err
	}
	keyB, err := decodeWireGuardPublicKey(publicKeyB)
	if err != nil {
		return "", err
	}
	if publicKeyA == publicKeyB {
		return "", errors.New("route peers must use distinct keys")
	}
	combined := make([]byte, 0, len(keyA)+len(keyB))
	combined = append(combined, keyA...)
	combined = append(combined, keyB...)
	sum := sha256.Sum256(combined)
	return hex.EncodeToString(sum[:]), nil
}

func decodeWireGuardPublicKey(value string) ([]byte, error) {
	decoded, err := base64.StdEncoding.Strict().DecodeString(value)
	if err != nil || len(decoded) != 32 || base64.StdEncoding.EncodeToString(decoded) != value {
		return nil, errors.New("WireGuard public key must be canonical base64 for exactly 32 bytes")
	}
	allZero := true
	for _, value := range decoded {
		if value != 0 {
			allZero = false
			break
		}
	}
	if allZero {
		return nil, errors.New("WireGuard public key must not be all-zero")
	}
	return decoded, nil
}
