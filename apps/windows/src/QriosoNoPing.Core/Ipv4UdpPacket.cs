using System.Buffers.Binary;
using System.Net;

namespace QriosoNoPing.Core;

public sealed record UdpFlowKey(IPAddress RemoteAddress, ushort RemotePort, ushort LocalPort);

public sealed record ParsedIpv4UdpPacket(
    IPAddress SourceAddress,
    IPAddress DestinationAddress,
    ushort SourcePort,
    ushort DestinationPort,
    int HeaderLength);

public static class Ipv4UdpPacket
{
    public static bool TryParse(ReadOnlySpan<byte> packet, out ParsedIpv4UdpPacket? parsed)
    {
        parsed = null;
        if (packet.Length < 28 || packet[0] >> 4 != 4)
        {
            return false;
        }

        int headerLength = (packet[0] & 0x0F) * 4;
        if (headerLength < 20 || headerLength + 8 > packet.Length || BinaryPrimitives.ReadUInt16BigEndian(packet[2..4]) != packet.Length)
        {
            return false;
        }

        ushort fragment = BinaryPrimitives.ReadUInt16BigEndian(packet[6..8]);
        if ((fragment & 0x3FFF) != 0 || packet[9] != 17)
        {
            return false;
        }

        ushort udpLength = BinaryPrimitives.ReadUInt16BigEndian(packet.Slice(headerLength + 4, 2));
        if (udpLength != packet.Length - headerLength || udpLength < 8)
        {
            return false;
        }

        parsed = new ParsedIpv4UdpPacket(
            new IPAddress(packet[12..16]),
            new IPAddress(packet[16..20]),
            BinaryPrimitives.ReadUInt16BigEndian(packet.Slice(headerLength, 2)),
            BinaryPrimitives.ReadUInt16BigEndian(packet.Slice(headerLength + 2, 2)),
            headerLength);
        return true;
    }

    public static byte[] RewriteSource(ReadOnlySpan<byte> packet, IPAddress sourceAddress)
    {
        if (!TryParse(packet, out ParsedIpv4UdpPacket? parsed))
        {
            throw new ArgumentException("Packet must be an unfragmented IPv4 UDP datagram.", nameof(packet));
        }

        byte[] rewritten = packet.ToArray();
        WriteIpv4Address(sourceAddress, rewritten.AsSpan(12, 4));
        RecalculateChecksums(rewritten, parsed!.HeaderLength);
        return rewritten;
    }

    public static byte[] RewriteDestination(ReadOnlySpan<byte> packet, IPAddress destinationAddress)
    {
        if (!TryParse(packet, out ParsedIpv4UdpPacket? parsed))
        {
            throw new ArgumentException("Packet must be an unfragmented IPv4 UDP datagram.", nameof(packet));
        }

        byte[] rewritten = packet.ToArray();
        WriteIpv4Address(destinationAddress, rewritten.AsSpan(16, 4));
        RecalculateChecksums(rewritten, parsed!.HeaderLength);
        return rewritten;
    }

    public static UdpFlowKey OutboundFlow(ParsedIpv4UdpPacket packet) =>
        new(packet.DestinationAddress, packet.DestinationPort, packet.SourcePort);

    public static UdpFlowKey InboundFlow(ParsedIpv4UdpPacket packet) =>
        new(packet.SourceAddress, packet.SourcePort, packet.DestinationPort);

    private static void WriteIpv4Address(IPAddress address, Span<byte> destination)
    {
        byte[] bytes = address.GetAddressBytes();
        if (bytes.Length != 4)
        {
            throw new ArgumentException("Only IPv4 addresses are supported.", nameof(address));
        }

        bytes.CopyTo(destination);
    }

    private static void RecalculateChecksums(Span<byte> packet, int headerLength)
    {
        packet[10] = 0;
        packet[11] = 0;
        BinaryPrimitives.WriteUInt16BigEndian(packet[10..12], InternetChecksum(packet[..headerLength]));

        int udpLength = packet.Length - headerLength;
        packet[headerLength + 6] = 0;
        packet[headerLength + 7] = 0;
        uint sum = 0;
        sum = AddWords(sum, packet.Slice(12, 8));
        sum += 17;
        sum += checked((uint)udpLength);
        sum = AddWords(sum, packet[headerLength..]);
        ushort udpChecksum = Fold(sum);
        BinaryPrimitives.WriteUInt16BigEndian(packet.Slice(headerLength + 6, 2), udpChecksum == 0 ? (ushort)0xFFFF : udpChecksum);
    }

    private static ushort InternetChecksum(ReadOnlySpan<byte> data) => Fold(AddWords(0, data));

    private static uint AddWords(uint sum, ReadOnlySpan<byte> data)
    {
        int index = 0;
        for (; index + 1 < data.Length; index += 2)
        {
            sum += BinaryPrimitives.ReadUInt16BigEndian(data.Slice(index, 2));
        }

        if (index < data.Length)
        {
            sum += (uint)data[index] << 8;
        }

        return sum;
    }

    private static ushort Fold(uint sum)
    {
        while ((sum >> 16) != 0)
        {
            sum = (sum & 0xFFFF) + (sum >> 16);
        }

        return (ushort)~sum;
    }
}
