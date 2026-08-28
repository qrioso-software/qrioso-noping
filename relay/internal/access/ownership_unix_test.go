//go:build linux

package access

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestWriteAtomicPreservesExistingOwnershipAndMode(t *testing.T) {
	path := filepath.Join(t.TempDir(), "access-keys.yaml")
	if err := os.WriteFile(path, []byte("version: 1\nkeys: {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if os.Geteuid() == 0 {
		if err := os.Chown(path, 0, 12345); err != nil {
			t.Fatal(err)
		}
	}
	before, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	beforeOwnership := before.Sys().(*syscall.Stat_t)

	if err := WriteAtomic(path, EmptyDocument()); err != nil {
		t.Fatal(err)
	}
	after, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	afterOwnership := after.Sys().(*syscall.Stat_t)
	if beforeOwnership.Uid != afterOwnership.Uid || beforeOwnership.Gid != afterOwnership.Gid {
		t.Fatalf("ownership changed from %d:%d to %d:%d", beforeOwnership.Uid, beforeOwnership.Gid, afterOwnership.Uid, afterOwnership.Gid)
	}
	if after.Mode().Perm() != 0o640 {
		t.Fatalf("mode is %o, expected 640", after.Mode().Perm())
	}
}

func TestWriteAtomicInheritsDirectoryGroupOnFirstWrite(t *testing.T) {
	directory := t.TempDir()
	if os.Geteuid() == 0 {
		if err := os.Chown(directory, 0, 12345); err != nil {
			t.Fatal(err)
		}
	}
	directoryInfo, err := os.Stat(directory)
	if err != nil {
		t.Fatal(err)
	}
	expectedGroup := directoryInfo.Sys().(*syscall.Stat_t).Gid
	path := filepath.Join(directory, "access-keys.yaml")
	if err := WriteAtomic(path, EmptyDocument()); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	ownership := info.Sys().(*syscall.Stat_t)
	if ownership.Gid != expectedGroup {
		t.Fatalf("first write group is %d, expected directory group %d", ownership.Gid, expectedGroup)
	}
	if info.Mode().Perm() != 0o640 {
		t.Fatalf("mode is %o, expected 640", info.Mode().Perm())
	}
}

func TestUpdateAtomicSerializesConcurrentMutations(t *testing.T) {
	path := filepath.Join(t.TempDir(), "access-keys.yaml")
	const writers = 20
	errorsChannel := make(chan error, writers)
	for index := 0; index < writers; index++ {
		go func(index int) {
			id := fmt.Sprintf("cliente-%03d", index)
			token, err := GenerateToken(id)
			if err != nil {
				errorsChannel <- err
				return
			}
			errorsChannel <- UpdateAtomic(path, func(document *Document) error {
				return Add(document, id, token, 1, "concurrent test")
			})
		}(index)
	}
	for index := 0; index < writers; index++ {
		if err := <-errorsChannel; err != nil {
			t.Fatal(err)
		}
	}
	document, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(document.Keys) != writers {
		t.Fatalf("lost concurrent updates: got %d keys, expected %d", len(document.Keys), writers)
	}
}

func TestUpdateAtomicDoesNotReintroduceConcurrentRevocation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "access-keys.yaml")
	revokedToken, err := GenerateToken("cliente-old")
	if err != nil {
		t.Fatal(err)
	}
	if err := UpdateAtomic(path, func(document *Document) error {
		return Add(document, "cliente-old", revokedToken, 1, "will be revoked")
	}); err != nil {
		t.Fatal(err)
	}

	revokeHoldingLock := make(chan struct{})
	releaseRevoke := make(chan struct{})
	revokeDone := make(chan error, 1)
	go func() {
		revokeDone <- UpdateAtomic(path, func(document *Document) error {
			if err := Revoke(document, "cliente-old"); err != nil {
				return err
			}
			close(revokeHoldingLock)
			<-releaseRevoke
			return nil
		})
	}()
	<-revokeHoldingLock

	newToken, err := GenerateToken("cliente-new")
	if err != nil {
		t.Fatal(err)
	}
	addDone := make(chan error, 1)
	go func() {
		addDone <- UpdateAtomic(path, func(document *Document) error {
			return Add(document, "cliente-new", newToken, 1, "concurrent add")
		})
	}()
	close(releaseRevoke)
	if err := <-revokeDone; err != nil {
		t.Fatal(err)
	}
	if err := <-addDone; err != nil {
		t.Fatal(err)
	}

	document, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, exists := document.Keys["cliente-old"]; exists {
		t.Fatal("concurrent add reintroduced a revoked key")
	}
	if _, exists := document.Keys["cliente-new"]; !exists {
		t.Fatal("concurrent add was lost")
	}
}
