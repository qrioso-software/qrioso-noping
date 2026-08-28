//go:build !linux

package access

import (
	"errors"
	"os"
)

func preserveOwnership(_ *os.File, _, _ string) error {
	return errors.New("access file writes are supported only on the Linux relay")
}
