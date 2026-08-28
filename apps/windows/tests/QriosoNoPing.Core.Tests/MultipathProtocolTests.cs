using QriosoNoPing.Core;
using Xunit;

namespace QriosoNoPing.Core.Tests;

public sealed class MultipathProtocolTests
{
    [Fact]
    public void FrameRoundTripsWithNetworkOrderSessionId()
    {
        Guid sessionId = Guid.Parse("00112233-4455-6677-8899-aabbccddeeff");
        MultipathFrame expected = new(MultipathDirection.Upstream, MultipathRoute.RouteB, sessionId, 42, [1, 2, 3]);

        byte[] encoded = MultipathProtocol.Encode(expected);

        Assert.Equal("514E50310101020300112233445566778899AABBCCDDEEFF000000000000002A00030000010203", Convert.ToHexString(encoded));
        Assert.Equal("00112233445566778899AABBCCDDEEFF", Convert.ToHexString(encoded.AsSpan(8, 16)));
        Assert.True(MultipathProtocol.TryDecode(encoded, out MultipathFrame? actual));
        Assert.Equal(expected.Direction, actual!.Direction);
        Assert.Equal(expected.Route, actual.Route);
        Assert.Equal(expected.SessionId, actual.SessionId);
        Assert.Equal(expected.Sequence, actual.Sequence);
        Assert.Equal(expected.Payload, actual!.Payload);
        Assert.Equal(TrafficMode.Duplicate, actual.Mode);
    }

    [Fact]
    public void RejectsTrailingAndReservedBytes()
    {
        byte[] encoded = MultipathProtocol.Encode(new(
            MultipathDirection.Downstream, MultipathRoute.RouteA, Guid.NewGuid(), 1, [1]));
        Assert.False(MultipathProtocol.TryDecode([.. encoded, 0], out _));
        encoded[7] = 4;
        Assert.False(MultipathProtocol.TryDecode(encoded, out _));
    }

    [Fact]
    public void DeduplicatorAcceptsOnlyFirstCopyInsideWindow()
    {
        PacketDeduplicator deduplicator = new(TimeSpan.FromSeconds(1));
        DateTimeOffset now = DateTimeOffset.UnixEpoch;
        Guid sessionId = Guid.NewGuid();

        Assert.True(deduplicator.Accept(sessionId, 7, now));
        Assert.False(deduplicator.Accept(sessionId, 7, now.AddMilliseconds(999)));
        Assert.True(deduplicator.Accept(sessionId, 7, now.AddMilliseconds(1001)));
    }

    [Fact]
    public void DeduplicatorFailsClosedAtItsMemoryLimit()
    {
        PacketDeduplicator deduplicator = new(TimeSpan.FromMinutes(1), capacity: 2);
        Guid sessionId = Guid.NewGuid();

        Assert.True(deduplicator.Accept(sessionId, 1, DateTimeOffset.UnixEpoch));
        Assert.True(deduplicator.Accept(sessionId, 2, DateTimeOffset.UnixEpoch));
        Assert.False(deduplicator.Accept(sessionId, 3, DateTimeOffset.UnixEpoch));
    }
}
