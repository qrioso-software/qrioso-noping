namespace QriosoNoPing.Core;

public sealed class PacketDeduplicator(TimeSpan window, int capacity = 65_536)
{
    private sealed record SeenPacket((Guid SessionId, ulong Sequence) Key, DateTimeOffset SeenAt);

    private readonly Lock gate = new();
    private readonly Dictionary<(Guid SessionId, ulong Sequence), DateTimeOffset> seen = new(capacity);
    private readonly Queue<SeenPacket> order = new(capacity);

    public bool Accept(Guid sessionId, ulong sequence, DateTimeOffset now)
    {
        lock (gate)
        {
            DateTimeOffset cutoff = now - window;
            while (order.TryPeek(out SeenPacket? oldest) && oldest.SeenAt < cutoff)
            {
                order.Dequeue();
                if (seen.TryGetValue(oldest.Key, out DateTimeOffset current) && current == oldest.SeenAt)
                {
                    seen.Remove(oldest.Key);
                }
            }

            (Guid SessionId, ulong Sequence) key = (sessionId, sequence);
            if (seen.ContainsKey(key) || seen.Count >= capacity)
            {
                return false;
            }

            seen[key] = now;
            order.Enqueue(new SeenPacket(key, now));
            return true;
        }
    }
}
