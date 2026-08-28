package multipath

import (
	"encoding/binary"
	"errors"
	"net/netip"
)

type IPv4Packet struct {
	Source      netip.Addr
	Destination netip.Addr
	Protocol    uint8
}

func ParseIPv4Packet(packet []byte) (IPv4Packet, error) {
	if len(packet) < 20 || packet[0]>>4 != 4 {
		return IPv4Packet{}, errors.New("payload is not an IPv4 packet")
	}
	headerLength := int(packet[0]&0x0f) * 4
	if headerLength < 20 || headerLength > len(packet) {
		return IPv4Packet{}, errors.New("IPv4 header length is invalid")
	}
	totalLength := int(binary.BigEndian.Uint16(packet[2:4]))
	if totalLength != len(packet) || totalLength < headerLength+8 {
		return IPv4Packet{}, errors.New("IPv4 total length is invalid")
	}
	fragment := binary.BigEndian.Uint16(packet[6:8])
	if fragment&0x3fff != 0 {
		return IPv4Packet{}, errors.New("fragmented IPv4 packets are not supported")
	}
	if packet[9] != 17 {
		return IPv4Packet{}, errors.New("only UDP game traffic is supported")
	}
	udpLength := int(binary.BigEndian.Uint16(packet[headerLength+4 : headerLength+6]))
	if udpLength < 8 || udpLength != totalLength-headerLength {
		return IPv4Packet{}, errors.New("UDP length is invalid")
	}
	source, ok := netip.AddrFromSlice(packet[12:16])
	if !ok {
		return IPv4Packet{}, errors.New("IPv4 source is invalid")
	}
	destination, ok := netip.AddrFromSlice(packet[16:20])
	if !ok {
		return IPv4Packet{}, errors.New("IPv4 destination is invalid")
	}
	return IPv4Packet{Source: source.Unmap(), Destination: destination.Unmap(), Protocol: packet[9]}, nil
}

func IsPublicGameDestination(address netip.Addr) bool {
	if !address.Is4() || !address.IsGlobalUnicast() || address.IsPrivate() || address.IsLoopback() || address.IsLinkLocalUnicast() || address.IsMulticast() || address.IsUnspecified() {
		return false
	}
	blocked := []netip.Prefix{
		netip.MustParsePrefix("0.0.0.0/8"),
		netip.MustParsePrefix("100.64.0.0/10"),
		netip.MustParsePrefix("169.254.0.0/16"),
		netip.MustParsePrefix("192.0.0.0/24"),
		netip.MustParsePrefix("192.0.2.0/24"),
		netip.MustParsePrefix("198.18.0.0/15"),
		netip.MustParsePrefix("198.51.100.0/24"),
		netip.MustParsePrefix("203.0.113.0/24"),
		netip.MustParsePrefix("240.0.0.0/4"),
	}
	for _, prefix := range blocked {
		if prefix.Contains(address) {
			return false
		}
	}
	return true
}
