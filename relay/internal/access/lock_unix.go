//go:build linux

package access

import (
	"fmt"
	"os"
	"syscall"
)

func acquireExclusiveLock(path string) (func(), error) {
	lockFile, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o640)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX); err != nil {
		lockFile.Close()
		return nil, err
	}
	return func() {
		if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN); err != nil {
			fmt.Fprintf(os.Stderr, "unlock access file: %v\n", err)
		}
		if err := lockFile.Close(); err != nil {
			fmt.Fprintf(os.Stderr, "close access lock: %v\n", err)
		}
	}, nil
}
