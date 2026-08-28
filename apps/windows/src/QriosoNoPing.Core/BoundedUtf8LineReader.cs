using System.Buffers;
using System.Text;

namespace QriosoNoPing.Core;

public static class BoundedUtf8LineReader
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    public static async Task<string?> ReadAsync(Stream stream, int maximumBytes, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(stream);
        if (maximumBytes < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumBytes));
        }

        ArrayBufferWriter<byte> line = new(Math.Min(maximumBytes, 4096));
        byte[] buffer = ArrayPool<byte>.Shared.Rent(4096);
        try
        {
            while (true)
            {
                int remainingWithTerminator = checked(maximumBytes + 1 - line.WrittenCount);
                int read = await stream.ReadAsync(buffer.AsMemory(0, Math.Min(buffer.Length, remainingWithTerminator)), cancellationToken);
                if (read == 0)
                {
                    return line.WrittenCount == 0 ? null : throw new InvalidDataException("The line was not terminated.");
                }

                int newline = buffer.AsSpan(0, read).IndexOf((byte)'\n');
                int contentLength = newline >= 0 ? newline : read;
                if (line.WrittenCount + contentLength > maximumBytes)
                {
                    bool isSplitCarriageReturn = newline < 0 &&
                        line.WrittenCount + contentLength == maximumBytes + 1 &&
                        buffer[contentLength - 1] == (byte)'\r';
                    bool isCompleteCarriageReturn = newline >= 0 &&
                        line.WrittenCount + contentLength == maximumBytes + 1 &&
                        buffer[contentLength - 1] == (byte)'\r';
                    if (!isSplitCarriageReturn && !isCompleteCarriageReturn)
                    {
                        throw new InvalidDataException("The line is too large.");
                    }

                    line.Write(buffer.AsSpan(0, contentLength - 1));
                    if (isCompleteCarriageReturn)
                    {
                        return Decode(line.WrittenSpan);
                    }
                    int terminatorRead = await stream.ReadAsync(buffer.AsMemory(0, 1), cancellationToken);
                    if (terminatorRead != 1 || buffer[0] != (byte)'\n')
                    {
                        throw new InvalidDataException("The line is too large or was not terminated.");
                    }
                    return Decode(line.WrittenSpan);
                }

                line.Write(buffer.AsSpan(0, contentLength));
                if (newline >= 0)
                {
                    return Decode(line.WrittenSpan);
                }

                if (line.WrittenCount == maximumBytes)
                {
                    int terminatorRead = await stream.ReadAsync(buffer.AsMemory(0, 1), cancellationToken);
                    if (terminatorRead != 1 || buffer[0] != (byte)'\n')
                    {
                        throw new InvalidDataException("The line is too large or was not terminated.");
                    }
                    return Decode(line.WrittenSpan);
                }
            }
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer, clearArray: true);
        }
    }

    private static string Decode(ReadOnlySpan<byte> encoded)
    {
        if (!encoded.IsEmpty && encoded[^1] == (byte)'\r')
        {
            encoded = encoded[..^1];
        }
        return StrictUtf8.GetString(encoded);
    }
}
