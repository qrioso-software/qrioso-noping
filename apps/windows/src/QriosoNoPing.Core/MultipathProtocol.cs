using System.Buffers.Binary;

namespace QriosoNoPing.Core;

public enum MultipathDirection : byte
{
    Upstream = 1,
    Downstream = 2,
    ProbeRequest = 3,
    ProbeReply = 4
}

public enum MultipathRoute : byte
{
    RouteA = 1,
    RouteB = 2
}

public enum TrafficMode : byte
{
    RouteA = 1,
    RouteB = 2,
    Duplicate = 3
}

public sealed record MultipathFrame(
    MultipathDirection Direction,
    MultipathRoute Route,
    Guid SessionId,
    ulong Sequence,
    byte[] Payload,
    TrafficMode Mode = TrafficMode.Duplicate);

public static class MultipathProtocol
{
    public const int Version = 1;
    public const int HeaderLength = 36;
    public const int CarrierMtu = 1420;
    // A carrier packet contains IPv4 + UDP + this protocol header before the
    // original game packet: 20 + 8 + 36 bytes.
    public const int MaxPayloadLength = CarrierMtu - 64;
    private static ReadOnlySpan<byte> Magic => "QNP1"u8;

    public static byte[] Encode(MultipathFrame frame)
    {
        ArgumentNullException.ThrowIfNull(frame);
        if (!Enum.IsDefined(frame.Direction))
        {
            throw new ArgumentOutOfRangeException(nameof(frame), "Invalid multipath direction.");
        }

        if (!Enum.IsDefined(frame.Route))
        {
            throw new ArgumentOutOfRangeException(nameof(frame), "Invalid multipath route.");
        }

        if (!Enum.IsDefined(frame.Mode))
        {
            throw new ArgumentOutOfRangeException(nameof(frame), "Invalid traffic mode.");
        }

        if (frame.Payload is null || frame.Payload.Length is < 1 or > MaxPayloadLength)
        {
            throw new ArgumentOutOfRangeException(nameof(frame), $"Payload must contain 1-{MaxPayloadLength} bytes.");
        }

        byte[] encoded = new byte[HeaderLength + frame.Payload.Length];
        Magic.CopyTo(encoded);
        encoded[4] = Version;
        encoded[5] = (byte)frame.Direction;
        encoded[6] = (byte)frame.Route;
        encoded[7] = (byte)frame.Mode;
        WriteSessionId(frame.SessionId, encoded.AsSpan(8, 16));
        BinaryPrimitives.WriteUInt64BigEndian(encoded.AsSpan(24, 8), frame.Sequence);
        BinaryPrimitives.WriteUInt16BigEndian(encoded.AsSpan(32, 2), checked((ushort)frame.Payload.Length));
        frame.Payload.CopyTo(encoded, HeaderLength);
        return encoded;
    }

    public static bool TryDecode(ReadOnlySpan<byte> encoded, out MultipathFrame? frame)
    {
        frame = null;
        if (encoded.Length < HeaderLength || !encoded[..4].SequenceEqual(Magic) || encoded[4] != Version)
        {
            return false;
        }

        MultipathDirection direction = (MultipathDirection)encoded[5];
        MultipathRoute route = (MultipathRoute)encoded[6];
        TrafficMode mode = (TrafficMode)encoded[7];
        if (!Enum.IsDefined(direction) || !Enum.IsDefined(route) || !Enum.IsDefined(mode) || encoded[34] != 0 || encoded[35] != 0)
        {
            return false;
        }

        int payloadLength = BinaryPrimitives.ReadUInt16BigEndian(encoded.Slice(32, 2));
        if (payloadLength is < 1 or > MaxPayloadLength || encoded.Length != HeaderLength + payloadLength)
        {
            return false;
        }

        frame = new MultipathFrame(
            direction,
            route,
            ReadSessionId(encoded.Slice(8, 16)),
            BinaryPrimitives.ReadUInt64BigEndian(encoded.Slice(24, 8)),
            encoded[HeaderLength..].ToArray(),
            mode);
        return true;
    }

    private static void WriteSessionId(Guid sessionId, Span<byte> destination)
    {
        Span<byte> littleEndian = stackalloc byte[16];
        if (!sessionId.TryWriteBytes(littleEndian))
        {
            throw new InvalidOperationException("Could not encode the session ID.");
        }

        // Guid byte arrays use little endian for the first three fields. The
        // relay treats the ID as opaque network-order bytes.
        BinaryPrimitives.WriteUInt32BigEndian(destination[..4], BinaryPrimitives.ReadUInt32LittleEndian(littleEndian[..4]));
        BinaryPrimitives.WriteUInt16BigEndian(destination.Slice(4, 2), BinaryPrimitives.ReadUInt16LittleEndian(littleEndian.Slice(4, 2)));
        BinaryPrimitives.WriteUInt16BigEndian(destination.Slice(6, 2), BinaryPrimitives.ReadUInt16LittleEndian(littleEndian.Slice(6, 2)));
        littleEndian[8..].CopyTo(destination[8..]);
    }

    private static Guid ReadSessionId(ReadOnlySpan<byte> source)
    {
        Span<byte> littleEndian = stackalloc byte[16];
        BinaryPrimitives.WriteUInt32LittleEndian(littleEndian[..4], BinaryPrimitives.ReadUInt32BigEndian(source[..4]));
        BinaryPrimitives.WriteUInt16LittleEndian(littleEndian.Slice(4, 2), BinaryPrimitives.ReadUInt16BigEndian(source.Slice(4, 2)));
        BinaryPrimitives.WriteUInt16LittleEndian(littleEndian.Slice(6, 2), BinaryPrimitives.ReadUInt16BigEndian(source.Slice(6, 2)));
        source[8..].CopyTo(littleEndian[8..]);
        return new Guid(littleEndian);
    }
}
