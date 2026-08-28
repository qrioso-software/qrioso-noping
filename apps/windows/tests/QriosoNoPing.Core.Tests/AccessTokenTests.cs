using QriosoNoPing.Core;
using Xunit;

namespace QriosoNoPing.Core.Tests;

public sealed class AccessTokenTests
{
    [Fact]
    public void AcceptsExpectedTokenFormat()
    {
        const string value = "qnp_cliente-001_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

        bool parsed = AccessToken.TryParse(value, out AccessToken? token);

        Assert.True(parsed);
        Assert.NotNull(token);
        Assert.Equal("cliente-001", token.Id);
        Assert.Equal("qnp_cliente-001_***", token.Redacted);
    }

    [Theory]
    [InlineData("")]
    [InlineData("qnp_cliente-001_short")]
    [InlineData("not-a-token")]
    [InlineData("qnp_CLIENTE_001_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")]
    public void RejectsMalformedTokens(string value)
    {
        Assert.False(AccessToken.TryParse(value, out _));
    }
}
