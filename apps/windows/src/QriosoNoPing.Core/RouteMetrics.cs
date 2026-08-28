namespace QriosoNoPing.Core;

public sealed record RouteMetricsSnapshot(
    double? MedianRttMs,
    double? P95RttMs,
    double? JitterMs,
    double LossPercent,
    int Sent,
    int Received);

public sealed class RouteMetrics(int capacity = 60)
{
    private sealed class Probe(ulong sequence)
    {
        public ulong Sequence { get; } = sequence;
        public double? RttMilliseconds { get; set; }
    }

    private readonly Lock gate = new();
    private readonly Queue<Probe> probes = new(capacity);
    private readonly Dictionary<ulong, Probe> pending = new(capacity);

    public void RecordSent(ulong sequence)
    {
        lock (gate)
        {
            if (pending.ContainsKey(sequence))
            {
                return;
            }

            if (probes.Count == capacity)
            {
                Probe expired = probes.Dequeue();
                pending.Remove(expired.Sequence);
            }

            Probe probe = new(sequence);
            probes.Enqueue(probe);
            pending[sequence] = probe;
        }
    }

    public void RecordReply(ulong sequence, TimeSpan roundTrip)
    {
        lock (gate)
        {
            if (!pending.TryGetValue(sequence, out Probe? probe) || probe.RttMilliseconds is not null)
            {
                return;
            }

            probe.RttMilliseconds = Math.Max(0, roundTrip.TotalMilliseconds);
        }
    }

    public RouteMetricsSnapshot Snapshot()
    {
        lock (gate)
        {
            Probe[] window = probes.ToArray();
            double[] samples = window
                .Where(probe => probe.RttMilliseconds is not null)
                .Select(probe => probe.RttMilliseconds!.Value)
                .ToArray();
            double[] ordered = samples.Order().ToArray();
            double? median = Percentile(ordered, 0.50);
            double? p95 = Percentile(ordered, 0.95);
            double? jitter = samples.Length < 2
                ? null
                : samples.Zip(samples.Skip(1), (left, right) => Math.Abs(right - left)).Average();
            int sent = window.Length;
            int received = samples.Length;
            double loss = sent == 0 ? 0 : Math.Max(0, sent - received) * 100d / sent;
            return new RouteMetricsSnapshot(median, p95, jitter, loss, sent, received);
        }
    }

    private static double? Percentile(double[] ordered, double percentile)
    {
        if (ordered.Length == 0)
        {
            return null;
        }

        int index = Math.Clamp((int)Math.Ceiling(percentile * ordered.Length) - 1, 0, ordered.Length - 1);
        return ordered[index];
    }
}
