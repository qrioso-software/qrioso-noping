package multipath

import (
	"encoding/binary"
	"net/netip"
	"testing"
)

func TestParseIPv4PacketAcceptsUnfragmentedUDP(t *testing.T) {
	packet := testIPv4UDP(netip.MustParseAddr("10.80.0.2"), netip.MustParseAddr("8.8.8.8"))
	parsed, err := ParseIPv4Packet(packet)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Source.String() != "10.80.0.2" || parsed.Destination.String() != "8.8.8.8" {
		t.Fatalf("unexpected packet: %+v", parsed)
	}
}

func TestParseIPv4PacketRejectsInconsistentUDPLength(t *testing.T) {
	packet := testIPv4UDP(netip.MustParseAddr("10.80.0.2"), netip.MustParseAddr("8.8.8.8"))
	binary.BigEndian.PutUint16(packet[24:26], 9)
	if _, err := ParseIPv4Packet(packet); err == nil {
		t.Fatal("packet with inconsistent UDP length was accepted")
	}
}

func TestPublicGameDestinationRejectsInternalAndSpecialAddresses(t *testing.T) {
	for _, value := range []string{"10.77.0.1", "100.64.0.1", "127.0.0.1", "169.254.169.254", "192.0.2.1", "198.18.0.1", "203.0.113.1", "224.0.0.1"} {
		if IsPublicGameDestination(netip.MustParseAddr(value)) {
			t.Fatalf("special destination %s was accepted", value)
		}
	}
	if !IsPublicGameDestination(netip.MustParseAddr("8.8.8.8")) {
		t.Fatal("public IPv4 destination was rejected")
	}
}

func testIPv4UDP(source, destination netip.Addr) []byte {
	packet := make([]byte, 28)
	packet[0] = 0x45
	binary.BigEndian.PutUint16(packet[2:4], uint16(len(packet)))
	packet[8] = 64
	packet[9] = 17
	copy(packet[12:16], source.AsSlice())
	copy(packet[16:20], destination.AsSlice())
	binary.BigEndian.PutUint16(packet[24:26], 8)
	return packet
}
