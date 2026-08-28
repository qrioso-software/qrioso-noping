//go:build windows

package access

import "os"

func preserveOwnership(_ *os.File, _, _ string) error {
	return nil
}
