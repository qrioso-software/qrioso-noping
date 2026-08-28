package main

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/qrioso/ridenow-noping/relay/internal/access"
	"github.com/qrioso/ridenow-noping/relay/internal/sessionstore"
)

type sessionCoordinator struct {
	mu              sync.Mutex
	registry        *leaseRegistry
	peers           peerController
	snapshotPath    string
	pendingRemovals map[string]deviceLease
	lastError       error
}

func newSessionCoordinator(registry *leaseRegistry, peers peerController, snapshotPath string) *sessionCoordinator {
	return &sessionCoordinator{
		registry: registry, peers: peers, snapshotPath: snapshotPath,
		pendingRemovals: make(map[string]deviceLease),
	}
}

func (coordinator *sessionCoordinator) initialize(ctx context.Context, now time.Time) error {
	coordinator.mu.Lock()
	defer coordinator.mu.Unlock()
	if err := coordinator.peers.Reset(ctx); err != nil {
		coordinator.lastError = err
		return fmt.Errorf("reset stale WireGuard peers: %w", err)
	}
	if err := coordinator.writeSnapshotLocked(now); err != nil {
		coordinator.lastError = err
		return err
	}
	coordinator.lastError = nil
	return nil
}

func (coordinator *sessionCoordinator) grant(ctx context.Context, keyID, deviceID, fingerprint, publicKeyA, publicKeyB string, maxDevices int, now time.Time) (deviceLease, bool, error) {
	coordinator.mu.Lock()
	defer coordinator.mu.Unlock()
	lease, granted, err := coordinator.registry.grantLease(keyID, deviceID, fingerprint, publicKeyA, publicKeyB, maxDevices, now)
	if err != nil || !granted {
		return lease, granted, err
	}
	if err := coordinator.peers.Apply(ctx, lease); err != nil {
		coordinator.registry.release(keyID, fingerprint)
		_ = coordinator.peers.Remove(ctx, lease)
		coordinator.lastError = err
		return deviceLease{}, false, fmt.Errorf("configure WireGuard peers: %w", err)
	}
	if err := coordinator.writeSnapshotLocked(now); err != nil {
		coordinator.registry.release(keyID, fingerprint)
		_ = coordinator.peers.Remove(ctx, lease)
		coordinator.lastError = err
		return deviceLease{}, false, err
	}
	coordinator.lastError = nil
	return lease, true, nil
}

func (coordinator *sessionCoordinator) reconcile(ctx context.Context, document access.Document, now time.Time) error {
	coordinator.mu.Lock()
	defer coordinator.mu.Unlock()
	allowed := make(map[string]int)
	for keyID, entry := range document.Keys {
		if entry.Enabled {
			allowed[keyID] = entry.MaxDevices
		}
	}
	coordinator.queueRemovalsLocked(coordinator.registry.reconcile(allowed, now))
	return coordinator.finishReconcileLocked(ctx, now)
}

func (coordinator *sessionCoordinator) expireOnly(ctx context.Context, now time.Time) error {
	coordinator.mu.Lock()
	defer coordinator.mu.Unlock()
	coordinator.queueRemovalsLocked(coordinator.registry.expire(now))
	return coordinator.finishReconcileLocked(ctx, now)
}

func (coordinator *sessionCoordinator) queueRemovalsLocked(leases []deviceLease) {
	for _, lease := range leases {
		coordinator.pendingRemovals[lease.sessionID] = lease
	}
}

func (coordinator *sessionCoordinator) finishReconcileLocked(ctx context.Context, now time.Time) error {
	var result error
	for sessionID, lease := range coordinator.pendingRemovals {
		if err := coordinator.peers.Remove(ctx, lease); err != nil {
			result = errors.Join(result, err)
			continue
		}
		delete(coordinator.pendingRemovals, sessionID)
	}
	if err := coordinator.writeSnapshotLocked(now); err != nil {
		result = errors.Join(result, err)
	}
	coordinator.lastError = result
	return result
}

func (coordinator *sessionCoordinator) writeSnapshotLocked(now time.Time) error {
	return sessionstore.WriteAtomic(coordinator.snapshotPath, sessionstore.Snapshot{
		Version: sessionstore.CurrentVersion, GeneratedAt: now.UTC(), Sessions: coordinator.registry.snapshot(now),
	})
}

func (coordinator *sessionCoordinator) healthy() error {
	coordinator.mu.Lock()
	defer coordinator.mu.Unlock()
	if coordinator.lastError != nil {
		return coordinator.lastError
	}
	if len(coordinator.pendingRemovals) > 0 {
		return errors.New("WireGuard peer removals are pending")
	}
	return nil
}
