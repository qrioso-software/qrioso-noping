using System.Text;
using QriosoNoPing.Core;
using Xunit;

namespace QriosoNoPing.Core.Tests;

public sealed class BoundedUtf8LineReaderTests
{
    [Theory]
    [InlineData("ok\n", "ok")]
    [InlineData("español\r\n", "español")]
    public async Task ReadsOneStrictUtf8Line(string input, string expected)
    {
        await using MemoryStream stream = new(Encoding.UTF8.GetBytes(input));

        Assert.Equal(expected, await BoundedUtf8LineReader.ReadAsync(stream, 64));
    }

    [Fact]
    public async Task AcceptsExactlyTheLimitOnlyWhenTerminated()
    {
        await using MemoryStream stream = new(Encoding.UTF8.GetBytes("1234\n"));
        await using MemoryStream windowsStream = new(Encoding.UTF8.GetBytes("1234\r\n"));

        Assert.Equal("1234", await BoundedUtf8LineReader.ReadAsync(stream, 4));
        Assert.Equal("1234", await BoundedUtf8LineReader.ReadAsync(windowsStream, 4));
    }

    [Fact]
    public async Task RejectsInputBeforeBufferingPastTheLimit()
    {
        await using MemoryStream stream = new(Encoding.UTF8.GetBytes("12345\n"));

        await Assert.ThrowsAsync<InvalidDataException>(() => BoundedUtf8LineReader.ReadAsync(stream, 4));
    }

    [Fact]
    public async Task RejectsUnterminatedAndInvalidUtf8Input()
    {
        await using MemoryStream unterminated = new(Encoding.UTF8.GetBytes("partial"));
        await Assert.ThrowsAsync<InvalidDataException>(() => BoundedUtf8LineReader.ReadAsync(unterminated, 64));

        await using MemoryStream invalidUtf8 = new([0xC3, 0x28, (byte)'\n']);
        await Assert.ThrowsAsync<DecoderFallbackException>(() => BoundedUtf8LineReader.ReadAsync(invalidUtf8, 64));
    }
}
