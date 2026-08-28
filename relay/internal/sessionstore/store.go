package sessionstore

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"sort"
	"time"
)

const CurrentVersion = 1

type Session struct {
	ID             string    `json:"id"`
	KeyID          string    `json:"keyId"`
	Fingerprint    string    `json:"fingerprint"`
	PublicKeyA     string    `json:"publicKeyA"`
	PublicKeyB     string    `json:"publicKeyB"`
	ClientAddressA string    `json:"clientAddressA"`
	ClientAddressB string    `json:"clientAddressB"`
	VirtualAddress string    `json:"virtualAddress"`
	ExpiresAt      time.Time `json:"expiresAt"`
}

type Snapshot struct {
	Version     int       `json:"version"`
	GeneratedAt time.Time `json:"generatedAt"`
	Sessions    []Session `json:"sessions"`
}

func Empty() Snapshot {
	return Snapshot{Version: CurrentVersion, GeneratedAt: time.Now().UTC(), Sessions: []Session{}}
}

func DecodeSessionID(value string) ([16]byte, error) {
	decoded, err := base64.RawURLEncoding.Strict().DecodeString(value)
	if err != nil || len(decoded) != 16 || base64.RawURLEncoding.EncodeToString(decoded) != value {
		return [16]byte{}, errors.New("session id must be canonical base64url for 16 bytes")
	}
	var id [16]byte
	copy(id[:], decoded)
	return id, nil
}

func Validate(snapshot Snapshot) error {
	if snapshot.Version != CurrentVersion {
		return fmt.Errorf("unsupported session snapshot version %d", snapshot.Version)
	}
	if snapshot.Sessions == nil {
		return errors.New("sessions must be an array")
	}
	if snapshot.GeneratedAt.IsZero() {
		return errors.New("generatedAt is required")
	}
	ids := make(map[string]struct{}, len(snapshot.Sessions))
	virtualAddresses := make(map[netip.Addr]struct{}, len(snapshot.Sessions))
	for index, session := range snapshot.Sessions {
		if _, err := DecodeSessionID(session.ID); err != nil {
			return fmt.Errorf("session %d: %w", index, err)
		}
		if _, exists := ids[session.ID]; exists {
			return fmt.Errorf("session %d duplicates id", index)
		}
		ids[session.ID] = struct{}{}
		if session.KeyID == "" || session.Fingerprint == "" || session.PublicKeyA == "" || session.PublicKeyB == "" {
			return fmt.Errorf("session %d has missing identity fields", index)
		}
		addressA, err := netip.ParseAddr(session.ClientAddressA)
		if err != nil || !addressA.Is4() || !netip.MustParsePrefix("10.78.0.0/24").Contains(addressA) {
			return fmt.Errorf("session %d has invalid route A address", index)
		}
		addressB, err := netip.ParseAddr(session.ClientAddressB)
		if err != nil || !addressB.Is4() || !netip.MustParsePrefix("10.79.0.0/24").Contains(addressB) {
			return fmt.Errorf("session %d has invalid route B address", index)
		}
		virtualAddress, err := netip.ParseAddr(session.VirtualAddress)
		if err != nil || !virtualAddress.Is4() || !netip.MustParsePrefix("10.80.0.0/24").Contains(virtualAddress) {
			return fmt.Errorf("session %d has invalid virtual address", index)
		}
		if _, exists := virtualAddresses[virtualAddress]; exists {
			return fmt.Errorf("session %d duplicates virtual address", index)
		}
		virtualAddresses[virtualAddress] = struct{}{}
		if session.ExpiresAt.IsZero() {
			return fmt.Errorf("session %d has no expiry", index)
		}
	}
	return nil
}

func Load(path string) (Snapshot, error) {
	file, err := os.Open(path)
	if err != nil {
		return Snapshot{}, fmt.Errorf("open session snapshot: %w", err)
	}
	defer file.Close()

	decoder := json.NewDecoder(io.LimitReader(file, 1024*1024))
	decoder.DisallowUnknownFields()
	var snapshot Snapshot
	if err := decoder.Decode(&snapshot); err != nil {
		return Snapshot{}, fmt.Errorf("decode session snapshot: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return Snapshot{}, errors.New("session snapshot must contain exactly one JSON document")
	}
	if err := Validate(snapshot); err != nil {
		return Snapshot{}, err
	}
	return snapshot, nil
}

func WriteAtomic(path string, snapshot Snapshot) error {
	if snapshot.GeneratedAt.IsZero() {
		snapshot.GeneratedAt = time.Now().UTC()
	}
	sort.Slice(snapshot.Sessions, func(left, right int) bool { return snapshot.Sessions[left].ID < snapshot.Sessions[right].ID })
	if err := Validate(snapshot); err != nil {
		return err
	}
	encoded, err := json.Marshal(snapshot)
	if err != nil {
		return fmt.Errorf("encode session snapshot: %w", err)
	}
	encoded = append(encoded, '\n')

	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o750); err != nil {
		return fmt.Errorf("create session directory: %w", err)
	}
	temporary, err := os.CreateTemp(directory, ".sessions-*")
	if err != nil {
		return fmt.Errorf("create session snapshot: %w", err)
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)
	if err := temporary.Chmod(0o640); err != nil {
		temporary.Close()
		return fmt.Errorf("chmod session snapshot: %w", err)
	}
	if _, err := temporary.Write(encoded); err != nil {
		temporary.Close()
		return fmt.Errorf("write session snapshot: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return fmt.Errorf("sync session snapshot: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close session snapshot: %w", err)
	}
	if err := os.Rename(temporaryName, path); err != nil {
		return fmt.Errorf("replace session snapshot: %w", err)
	}
	return nil
}
