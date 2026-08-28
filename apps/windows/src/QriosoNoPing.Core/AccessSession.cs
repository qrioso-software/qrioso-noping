namespace QriosoNoPing.Core;

public sealed record AccessSession(
    string Status,
    int LeaseSeconds,
    string DirectEndpoint,
    string AcceleratedEndpoint,
    string ServerPublicKeyA,
    string ServerPublicKeyB,
    string ClientAddressA,
    string ClientAddressB,
    string VirtualAddress,
    string RelayDataAddressA,
    string RelayDataAddressB,
    string SessionId,
    int Mtu)
{
    public Guid ParsedSessionId
    {
        get
        {
            if (SessionId.Length != 22 || SessionId.Any(value => !(char.IsAsciiLetterOrDigit(value) || value is '-' or '_')))
            {
                throw new FormatException("Session ID must contain exactly 16 bytes.");
            }

            byte[] bytes = Convert.FromBase64String(SessionId.Replace('-', '+').Replace('_', '/') + "==");
            string canonical = Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
            if (bytes.Length != 16 || !string.Equals(canonical, SessionId, StringComparison.Ordinal))
            {
                throw new FormatException("Session ID must be canonical base64url for exactly 16 bytes.");
            }

            return new Guid(
                (int)System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(0, 4)),
                (short)System.Buffers.Binary.BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(4, 2)),
                (short)System.Buffers.Binary.BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(6, 2)),
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]);
        }
    }
}
