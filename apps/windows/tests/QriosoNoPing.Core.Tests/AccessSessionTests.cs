using QriosoNoPing.Core;
using Xunit;

namespace QriosoNoPing.Core.Tests;

public sealed class AccessSessionTests
{
    [Fact]
    public void ParsesRelayBase64UrlSessionIdWithoutChangingBytes()
    {
        AccessSession session = new(
            "authorized", 10, "203.0.113.10:51820", "a.example.awsglobalaccelerator.com:51821",
            "a", "b", "10.78.0.2/32", "10.79.0.2/32", "10.80.0.2/32",
            "10.78.0.1:51900", "10.79.0.1:51900", "ABEiM0RVZneImaq7zN3u_w", 1380);

        Assert.Equal(Guid.Parse("00112233-4455-6677-8899-aabbccddeeff"), session.ParsedSessionId);
    }

    [Fact]
    public void RejectsNonCanonicalSessionIds()
    {
        AccessSession session = new("authorized", 10, "203.0.113.10:51820", "example.awsglobalaccelerator.com:51821", "", "", "", "", "", "", "", "AAAAAAAAAAAAAAAAAAAAA+", 1420);

        Assert.ThrowsAny<FormatException>(() => session.ParsedSessionId);
    }
}
