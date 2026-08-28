//go:build linux

package main

import (
	"encoding/binary"
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

const (
	tunSetIFF = 0x400454ca
	iffTun    = 0x0001
	iffNoPI   = 0x1000
)

type linuxTUN struct {
	file *os.File
}

func openTUN(name string) (*linuxTUN, error) {
	if len(name) == 0 || len(name) >= 16 {
		return nil, fmt.Errorf("invalid TUN interface name %q", name)
	}
	file, err := os.OpenFile("/dev/net/tun", os.O_RDWR|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, fmt.Errorf("open /dev/net/tun: %w", err)
	}
	request := make([]byte, 40)
	copy(request[:16], name)
	binary.NativeEndian.PutUint16(request[16:18], iffTun|iffNoPI)
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, file.Fd(), tunSetIFF, uintptr(unsafe.Pointer(&request[0])))
	if errno != 0 {
		file.Close()
		return nil, fmt.Errorf("attach TUN %s: %w", name, errno)
	}
	return &linuxTUN{file: file}, nil
}

func (tun *linuxTUN) Read(buffer []byte) (int, error)  { return tun.file.Read(buffer) }
func (tun *linuxTUN) Write(packet []byte) (int, error) { return tun.file.Write(packet) }
func (tun *linuxTUN) Close() error                     { return tun.file.Close() }
