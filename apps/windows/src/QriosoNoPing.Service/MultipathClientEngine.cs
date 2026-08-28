using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using QriosoNoPing.Core;

namespace QriosoNoPing.Service;

public sealed class MultipathClientEngine : IAsyncDisposable
{
    private const int MaximumTrackedFlows = 4096;
    private sealed record FlowState(IPAddress OriginalLocalAddress, DateTimeOffset SeenAt);

    private readonly ILogger<MultipathClientEngine> logger;
    private readonly AccessSession session;
    private readonly TrafficMode mode;
    private readonly Guid sessionId;
    private readonly IPAddress virtualAddress;
    private readonly IPacketInterceptor interceptor;
    private readonly UdpClient routeA;
    private readonly UdpClient routeB;
    private readonly CancellationTokenSource cancellation = new();
    private readonly PacketDeduplicator deduplicator = new(TimeSpan.FromSeconds(30));
    private readonly ConcurrentDictionary<UdpFlowKey, FlowState> flows = new();
    private readonly RouteMetrics metricsA = new();
    private readonly RouteMetrics metricsB = new();
    private readonly Task completion;
    private long sequence;
    private long routeAWins;
    private long routeBWins;

    public MultipathClientEngine(ILogger<MultipathClientEngine> logger, AccessSession session, IPacketInterceptor interceptor, TrafficMode mode)
    {
        this.logger = logger;
        this.session = session;
        this.interceptor = interceptor;
        this.mode = mode;
        sessionId = session.ParsedSessionId;
        virtualAddress = ParseCidrAddress(session.VirtualAddress);
        routeA = CreateRouteSocket(session.ClientAddressA, session.RelayDataAddressA);
        routeB = CreateRouteSocket(session.ClientAddressB, session.RelayDataAddressB);
        completion = RunAsync(cancellation.Token);
    }

    public Task Completion => completion;

    public (RouteMetricsSnapshot RouteA, RouteMetricsSnapshot RouteB, string Winner) Snapshot()
    {
        long winsA = Interlocked.Read(ref routeAWins);
        long winsB = Interlocked.Read(ref routeBWins);
        string winner = mode switch
        {
            TrafficMode.RouteA => "Ruta A",
            TrafficMode.RouteB => "Ruta B",
            _ => winsA == winsB ? "Empate" : winsA > winsB ? "Ruta A" : "Ruta B"
        };
        return (metricsA.Snapshot(), metricsB.Snapshot(), winner);
    }

    public async ValueTask DisposeAsync()
    {
        cancellation.Cancel();
        routeA.Dispose();
        routeB.Dispose();
        interceptor.Dispose();
        try
        {
            await completion;
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception exception)
        {
            logger.LogWarning(exception, "Multipath engine stopped while restoring the direct route.");
        }
        finally
        {
            cancellation.Dispose();
        }
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        List<Task> workers =
        [
            CaptureOutboundAsync(cancellationToken),
            ReceiveAsync(routeA, MultipathRoute.RouteA, metricsA, cancellationToken),
            ReceiveAsync(routeB, MultipathRoute.RouteB, metricsB, cancellationToken),
            PruneFlowsAsync(cancellationToken)
        ];
        if (IsActive(MultipathRoute.RouteA))
        {
            workers.Add(ProbeAsync(routeA, MultipathRoute.RouteA, metricsA, cancellationToken));
        }
        if (IsActive(MultipathRoute.RouteB))
        {
            workers.Add(ProbeAsync(routeB, MultipathRoute.RouteB, metricsB, cancellationToken));
        }
        await Task.WhenAll(workers);
    }

    private async Task CaptureOutboundAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            byte[]? packet = await Task.Run(() => interceptor.ReadOutbound(250), cancellationToken);
            if (packet is null)
            {
                continue;
            }

            if (!Ipv4UdpPacket.TryParse(packet, out ParsedIpv4UdpPacket? parsed))
            {
                continue;
            }

            ParsedIpv4UdpPacket validPacket = parsed!;
            UdpFlowKey flowKey = Ipv4UdpPacket.OutboundFlow(validPacket);
            if (!flows.ContainsKey(flowKey) && flows.Count >= MaximumTrackedFlows)
            {
                continue;
            }
            flows[flowKey] = new FlowState(validPacket.SourceAddress, DateTimeOffset.UtcNow);
            byte[] rewritten = Ipv4UdpPacket.RewriteSource(packet, virtualAddress);
            ulong packetSequence = checked((ulong)Interlocked.Increment(ref sequence));
            if (mode == TrafficMode.Duplicate)
            {
                byte[] frameA = MultipathProtocol.Encode(new(MultipathDirection.Upstream, MultipathRoute.RouteA, sessionId, packetSequence, rewritten, mode));
                byte[] frameB = MultipathProtocol.Encode(new(MultipathDirection.Upstream, MultipathRoute.RouteB, sessionId, packetSequence, rewritten, mode));
                await Task.WhenAll(routeA.SendAsync(frameA, cancellationToken).AsTask(), routeB.SendAsync(frameB, cancellationToken).AsTask());
            }
            else
            {
                MultipathRoute activeRoute = mode == TrafficMode.RouteA ? MultipathRoute.RouteA : MultipathRoute.RouteB;
                UdpClient activeClient = activeRoute == MultipathRoute.RouteA ? routeA : routeB;
                byte[] frame = MultipathProtocol.Encode(new(MultipathDirection.Upstream, activeRoute, sessionId, packetSequence, rewritten, mode));
                await activeClient.SendAsync(frame, cancellationToken);
            }
        }
    }

    private async Task ReceiveAsync(UdpClient client, MultipathRoute route, RouteMetrics metrics, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            UdpReceiveResult received = await client.ReceiveAsync(cancellationToken);
            if (!MultipathProtocol.TryDecode(received.Buffer, out MultipathFrame? frame) || frame!.Route != route || frame.SessionId != sessionId || frame.Mode != mode)
            {
                continue;
            }

            if (frame.Direction == MultipathDirection.ProbeReply && frame.Payload.Length == 8)
            {
                long started = BinaryPrimitives.ReadInt64BigEndian(frame.Payload);
                metrics.RecordReply(frame.Sequence, Stopwatch.GetElapsedTime(started));
                continue;
            }

            if (frame.Direction != MultipathDirection.Downstream || !IsActive(route) || !deduplicator.Accept(frame.SessionId, frame.Sequence, DateTimeOffset.UtcNow))
            {
                continue;
            }

            if (route == MultipathRoute.RouteA)
            {
                Interlocked.Increment(ref routeAWins);
            }
            else
            {
                Interlocked.Increment(ref routeBWins);
            }

            if (!Ipv4UdpPacket.TryParse(frame.Payload, out ParsedIpv4UdpPacket? parsed) || !flows.TryGetValue(Ipv4UdpPacket.InboundFlow(parsed!), out FlowState? flow))
            {
                continue;
            }

            interceptor.InjectInbound(Ipv4UdpPacket.RewriteDestination(frame.Payload, flow.OriginalLocalAddress));
        }
    }

    private async Task ProbeAsync(UdpClient client, MultipathRoute route, RouteMetrics metrics, CancellationToken cancellationToken)
    {
        using PeriodicTimer timer = new(TimeSpan.FromSeconds(1));
        while (await timer.WaitForNextTickAsync(cancellationToken))
        {
            long started = Stopwatch.GetTimestamp();
            byte[] payload = new byte[8];
            BinaryPrimitives.WriteInt64BigEndian(payload, started);
            ulong probeSequence = checked((ulong)Interlocked.Increment(ref sequence));
            metrics.RecordSent(probeSequence);
            byte[] frame = MultipathProtocol.Encode(new(MultipathDirection.ProbeRequest, route, sessionId, probeSequence, payload, mode));
            await client.SendAsync(frame, cancellationToken);
        }
    }

    private async Task PruneFlowsAsync(CancellationToken cancellationToken)
    {
        using PeriodicTimer timer = new(TimeSpan.FromSeconds(10));
        while (await timer.WaitForNextTickAsync(cancellationToken))
        {
            DateTimeOffset cutoff = DateTimeOffset.UtcNow.AddMinutes(-2);
            foreach ((UdpFlowKey key, FlowState value) in flows)
            {
                if (value.SeenAt < cutoff)
                {
                    flows.TryRemove(key, out _);
                }
            }
        }
    }

    private static UdpClient CreateRouteSocket(string clientAddress, string relayAddress)
    {
        IPAddress local = ParseCidrAddress(clientAddress);
        IPEndPoint remote = IPEndPoint.Parse(relayAddress);
        UdpClient client = new(AddressFamily.InterNetwork);
        client.Client.Bind(new IPEndPoint(local, 0));
        client.Connect(remote);
        return client;
    }

    private bool IsActive(MultipathRoute route) => mode == TrafficMode.Duplicate ||
        (mode == TrafficMode.RouteA && route == MultipathRoute.RouteA) ||
        (mode == TrafficMode.RouteB && route == MultipathRoute.RouteB);

    private static IPAddress ParseCidrAddress(string value)
    {
        string address = value.Split('/', 2, StringSplitOptions.TrimEntries)[0];
        IPAddress parsed = IPAddress.Parse(address);
        if (parsed.AddressFamily != AddressFamily.InterNetwork)
        {
            throw new InvalidDataException("Only IPv4 tunnel addresses are supported.");
        }

        return parsed;
    }
}
