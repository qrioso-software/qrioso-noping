//go:build !linux

package access

import "errors"

func acquireExclusiveLock(_ string) (func(), error) {
	return nil, errors.New("access file updates are supported only on the Linux relay")
}
