//go:build aix || darwin || dragonfly || freebsd || linux || netbsd || openbsd || solaris

package access

import (
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
