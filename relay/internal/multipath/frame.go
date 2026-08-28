package multipath

import (
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	Version      = 1
	HeaderLength = 36
	// The WireGuard carrier MTU is 1420. Its inner IPv4 + UDP + bonding
	// header consumes 64 bytes before the original game packet.
	MaxPayload       = 1356
	FlagUpstream     = 1
	FlagDownstream   = 2
	FlagProbeRequest = 3
	FlagProbeReply   = 4
	RouteA           = 1
	RouteB           = 2
	ModeRouteA       = 1
	ModeRouteB       = 2
	ModeDuplicate    = 3
)

var frameMagic = [4]byte{'Q', 'N', 'P', '1'}

type Frame struct {
	Flags     uint8
	Route     uint8
	Mode      uint8
	SessionID [16]byte
	Sequence  uint64
	Payload   []byte
}

func EncodeFrame(frame Frame) ([]byte, error) {
	if !validDirection(frame.Flags) {
		return nil, errors.New("invalid frame direction")
	}
	if frame.Route != RouteA && frame.Route != RouteB {
		return nil, errors.New("invalid frame route")
	}
	mode := frame.Mode
	if mode == 0 {
		mode = ModeDuplicate
	}
	if !validMode(mode) {
		return nil, errors.New("invalid traffic mode")
	}
	if len(frame.Payload) == 0 || len(frame.Payload) > MaxPayload {
		return nil, fmt.Errorf("payload length must be between 1 and %d", MaxPayload)
	}

	encoded := make([]byte, HeaderLength+len(frame.Payload))
	copy(encoded[0:4], frameMagic[:])
	encoded[4] = Version
	encoded[5] = frame.Flags
	encoded[6] = frame.Route
	encoded[7] = mode
	copy(encoded[8:24], frame.SessionID[:])
	binary.BigEndian.PutUint64(encoded[24:32], frame.Sequence)
	binary.BigEndian.PutUint16(encoded[32:34], uint16(len(frame.Payload)))
	copy(encoded[HeaderLength:], frame.Payload)
	return encoded, nil
}

func DecodeFrame(encoded []byte) (Frame, error) {
	if len(encoded) < HeaderLength {
		return Frame{}, errors.New("frame is shorter than the fixed header")
	}
	if string(encoded[0:4]) != string(frameMagic[:]) || encoded[4] != Version {
		return Frame{}, errors.New("frame magic or version is invalid")
	}
	if !validDirection(encoded[5]) {
		return Frame{}, errors.New("frame direction is invalid")
	}
	if encoded[6] != RouteA && encoded[6] != RouteB {
		return Frame{}, errors.New("frame route is invalid")
	}
	if !validMode(encoded[7]) || encoded[34] != 0 || encoded[35] != 0 {
		return Frame{}, errors.New("reserved frame bytes must be zero")
	}
	payloadLength := int(binary.BigEndian.Uint16(encoded[32:34]))
	if payloadLength < 1 || payloadLength > MaxPayload || len(encoded) != HeaderLength+payloadLength {
		return Frame{}, errors.New("frame payload length is invalid")
	}
	var sessionID [16]byte
	copy(sessionID[:], encoded[8:24])
	payload := make([]byte, payloadLength)
	copy(payload, encoded[HeaderLength:])
	return Frame{
		Flags:     encoded[5],
		Route:     encoded[6],
		Mode:      encoded[7],
		SessionID: sessionID,
		Sequence:  binary.BigEndian.Uint64(encoded[24:32]),
		Payload:   payload,
	}, nil
}

func validDirection(direction uint8) bool {
	return direction == FlagUpstream || direction == FlagDownstream || direction == FlagProbeRequest || direction == FlagProbeReply
}

func validMode(mode uint8) bool {
	return mode == ModeRouteA || mode == ModeRouteB || mode == ModeDuplicate
}
