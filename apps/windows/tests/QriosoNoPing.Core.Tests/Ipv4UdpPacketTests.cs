using System.Buffers.Binary;
using System.Net;
using QriosoNoPing.Core;
using Xunit;

namespace QriosoNoPing.Core.Tests;

public sealed class Ipv4UdpPacketTests
{
    [Fact]
    public void RewritesAddressesAndProducesValidChecksums()
    {
        byte[] packet = CreatePacket(IPAddress.Parse("192.168.1.10"), IPAddress.Parse("8.8.8.8"), 50000, 9000, [1, 2, 3]);

        byte[] outbound = Ipv4UdpPacket.RewriteSource(packet, IPAddress.Parse("10.80.0.2"));
        Assert.True(Ipv4UdpPacket.TryParse(outbound, out ParsedIpv4UdpPacket? parsed));
        Assert.Equal(IPAddress.Parse("10.80.0.2"), parsed!.SourceAddress);
        Assert.Equal(0, Checksum(outbound.AsSpan(0, 20)));
        Assert.Equal(0, UdpChecksum(outbound));

        byte[] inbound = Ipv4UdpPacket.RewriteDestination(outbound, IPAddress.Parse("192.168.1.10"));
        Assert.True(Ipv4UdpPacket.TryParse(inbound, out parsed));
        Assert.Equal(IPAddress.Parse("192.168.1.10"), parsed!.DestinationAddress);
        Assert.Equal(0, UdpChecksum(inbound));
    }

    [Fact]
    public void RejectsTcpAndFragments()
    {
        byte[] packet = CreatePacket(IPAddress.Loopback, IPAddress.Parse("8.8.8.8"), 1, 2, []);
        packet[9] = 6;
        Assert.False(Ipv4UdpPacket.TryParse(packet, out _));
        packet[9] = 17;
        packet[7] = 1;
        Assert.False(Ipv4UdpPacket.TryParse(packet, out _));
    }

    private static byte[] CreatePacket(IPAddress source, IPAddress destination, ushort sourcePort, ushort destinationPort, byte[] payload)
    {
        byte[] packet = new byte[28 + payload.Length];
        packet[0] = 0x45;
        BinaryPrimitives.WriteUInt16BigEndian(packet.AsSpan(2, 2), checked((ushort)packet.Length));
        packet[8] = 64;
        packet[9] = 17;
        source.GetAddressBytes().CopyTo(packet, 12);
        destination.GetAddressBytes().CopyTo(packet, 16);
        BinaryPrimitives.WriteUInt16BigEndian(packet.AsSpan(20, 2), sourcePort);
        BinaryPrimitives.WriteUInt16BigEndian(packet.AsSpan(22, 2), destinationPort);
        BinaryPrimitives.WriteUInt16BigEndian(packet.AsSpan(24, 2), checked((ushort)(8 + payload.Length)));
        payload.CopyTo(packet, 28);
        return Ipv4UdpPacket.RewriteSource(packet, source);
    }

    private static ushort Checksum(ReadOnlySpan<byte> data)
    {
        uint sum = 0;
        for (int index = 0; index < data.Length; index += 2)
        {
            sum += BinaryPrimitives.ReadUInt16BigEndian(data.Slice(index, 2));
        }
        while ((sum >> 16) != 0) sum = (sum & 0xFFFF) + (sum >> 16);
        return (ushort)~sum;
    }

    private static ushort UdpChecksum(byte[] packet)
    {
        uint sum = 0;
        for (int index = 12; index < 20; index += 2) sum += BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(index, 2));
        sum += 17;
        sum += (uint)(packet.Length - 20);
        for (int index = 20; index < packet.Length; index += 2)
        {
            sum += index + 1 < packet.Length
                ? BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(index, 2))
                : (uint)packet[index] << 8;
        }
        while ((sum >> 16) != 0) sum = (sum & 0xFFFF) + (sum >> 16);
        return (ushort)~sum;
    }
}
