using QriosoNoPing.Core;
using Xunit;

namespace QriosoNoPing.Core.Tests;

public sealed class RouteMetricsTests
{
    [Fact]
    public void CalculatesRttJitterAndLossWithoutClaimingUnsampledValues()
    {
        RouteMetrics metrics = new();
        for (int index = 0; index < 4; index++)
        {
            metrics.RecordSent((ulong)index);
        }

        metrics.RecordReply(0, TimeSpan.FromMilliseconds(10));
        metrics.RecordReply(1, TimeSpan.FromMilliseconds(20));
        metrics.RecordReply(2, TimeSpan.FromMilliseconds(30));

        RouteMetricsSnapshot snapshot = metrics.Snapshot();

        Assert.Equal(20, snapshot.MedianRttMs);
        Assert.Equal(30, snapshot.P95RttMs);
        Assert.Equal(10, snapshot.JitterMs);
        Assert.Equal(25, snapshot.LossPercent);
        Assert.Equal(4, snapshot.Sent);
        Assert.Equal(3, snapshot.Received);
    }

    [Fact]
    public void CalculatesJitterInArrivalOrderInsteadOfSortedOrder()
    {
        RouteMetrics metrics = new();
        metrics.RecordSent(1);
        metrics.RecordSent(2);
        metrics.RecordSent(3);
        metrics.RecordReply(1, TimeSpan.FromMilliseconds(10));
        metrics.RecordReply(2, TimeSpan.FromMilliseconds(30));
        metrics.RecordReply(3, TimeSpan.FromMilliseconds(20));

        Assert.Equal(15, metrics.Snapshot().JitterMs);
    }

    [Fact]
    public void UsesOnlyTheRecentProbeWindowAndIgnoresDuplicateReplies()
    {
        RouteMetrics metrics = new(capacity: 2);
        metrics.RecordSent(1);
        metrics.RecordSent(2);
        metrics.RecordReply(1, TimeSpan.FromMilliseconds(90));
        metrics.RecordReply(1, TimeSpan.FromMilliseconds(1));
        metrics.RecordSent(3);
        metrics.RecordReply(3, TimeSpan.FromMilliseconds(10));

        RouteMetricsSnapshot snapshot = metrics.Snapshot();
        Assert.Equal(50, snapshot.LossPercent);
        Assert.Equal(10, snapshot.MedianRttMs);
        Assert.Equal(2, snapshot.Sent);
        Assert.Equal(1, snapshot.Received);
    }
}
