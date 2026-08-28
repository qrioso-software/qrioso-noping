//go:build linux

package access

import (
	"errors"
	"fmt"
	"os"
	"syscall"
)

// preserveOwnership keeps the authorization file readable by the service
// account after the atomic rename. For a first write, it inherits the access
// directory group instead of silently creating a root:root file.
func preserveOwnership(temporary *os.File, targetPath, directory string) error {
	ownerID := os.Geteuid()
	groupID, err := fileGroupID(directory)
	if err != nil {
		return fmt.Errorf("inspect access directory: %w", err)
	}

	info, err := os.Stat(targetPath)
	if err == nil {
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			return errors.New("target ownership is unavailable")
		}
		ownerID = int(stat.Uid)
		groupID = int(stat.Gid)
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("inspect current access file: %w", err)
	}

	if err := temporary.Chown(ownerID, groupID); err != nil {
		return fmt.Errorf("chown temporary access file to %d:%d: %w", ownerID, groupID, err)
	}
	return nil
}

func fileGroupID(path string) (int, error) {
	info, err := os.Stat(path)
	if err != nil {
		return 0, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, errors.New("directory ownership is unavailable")
	}
	return int(stat.Gid), nil
}
