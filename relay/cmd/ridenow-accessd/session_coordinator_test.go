package main

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/qrioso/ridenow-noping/relay/internal/access"
	"github.com/qrioso/ridenow-noping/relay/internal/sessionstore"
)

func TestCoordinatorPublishesSessionAndRemovesBothPeersOnRevoke(t *testing.T) {
	now := time.Unix(100, 0)
	peers := &fakePeerController{}
	snapshotPath := filepath.Join(t.TempDir(), "sessions.json")
	coordinator := newSessionCoordinator(newLeaseRegistry(10*time.Second, 10), peers, snapshotPath)
	if err := coordinator.initialize(context.Background(), now); err != nil {
		t.Fatal(err)
	}
	lease, granted, err := coordinator.grant(
		context.Background(), "cliente-001", "pc-uno", "fingerprint", testPublicKey(1), testPublicKey(2), 1, now,
	)
	if err != nil || !granted {
		t.Fatalf("grant failed: granted=%t err=%v", granted, err)
	}
	snapshot, err := sessionstore.Load(snapshotPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Sessions) != 1 || snapshot.Sessions[0].ID != lease.sessionID || len(peers.applied) != 1 {
		t.Fatalf("session was not provisioned atomically: snapshot=%+v applied=%d", snapshot, len(peers.applied))
	}
	if err := coordinator.reconcile(context.Background(), access.EmptyDocument(), now.Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	snapshot, err = sessionstore.Load(snapshotPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Sessions) != 0 || len(peers.removed) != 1 || peers.removed[0].publicKeyA != testPublicKey(1) || peers.removed[0].publicKeyB != testPublicKey(2) {
		t.Fatalf("revocation did not remove the complete session: snapshot=%+v removed=%+v", snapshot, peers.removed)
	}
}

func TestCoordinatorRollsBackWhenPeerProvisioningFails(t *testing.T) {
	peers := &fakePeerController{err: context.DeadlineExceeded}
	coordinator := newSessionCoordinator(newLeaseRegistry(10*time.Second, 10), peers, filepath.Join(t.TempDir(), "sessions.json"))
	if _, granted, err := coordinator.grant(
		context.Background(), "cliente-001", "pc-uno", "fingerprint", testPublicKey(1), testPublicKey(2), 1, time.Now(),
	); err == nil || granted {
		t.Fatalf("peer failure did not roll back: granted=%t err=%v", granted, err)
	}
	if sessions := coordinator.registry.snapshot(time.Now()); len(sessions) != 0 {
		t.Fatalf("failed provisioning leaked an active session: %+v", sessions)
	}
}
