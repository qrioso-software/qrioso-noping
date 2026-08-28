package sessionstore

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSnapshotRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sessions.json")
	snapshot := Snapshot{
		Version: CurrentVersion, GeneratedAt: time.Unix(100, 0).UTC(),
		Sessions: []Session{{
			ID: "AQEBAQEBAQEBAQEBAQEBAQ", KeyID: "cliente-001", Fingerprint: "abc",
			PublicKeyA: "key-a", PublicKeyB: "key-b", ClientAddressA: "10.78.0.2",
			ClientAddressB: "10.79.0.2", VirtualAddress: "10.80.0.2", ExpiresAt: time.Unix(110, 0).UTC(),
		}},
	}
	if err := WriteAtomic(path, snapshot); err != nil {
		t.Fatal(err)
	}
	loaded, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(loaded.Sessions) != 1 || loaded.Sessions[0].ID != snapshot.Sessions[0].ID {
		t.Fatalf("unexpected snapshot: %+v", loaded)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o640 {
		t.Fatalf("unexpected permissions: %o", info.Mode().Perm())
	}
}

func TestSnapshotRejectsTrailingJSONAndDuplicateVirtualAddress(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sessions.json")
	if err := os.WriteFile(path, []byte("{\"version\":1,\"generatedAt\":\"2026-01-01T00:00:00Z\",\"sessions\":[]} {}"), 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path); err == nil || !strings.Contains(err.Error(), "exactly one") {
		t.Fatalf("trailing JSON accepted: %v", err)
	}
}
