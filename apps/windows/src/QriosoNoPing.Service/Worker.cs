namespace QriosoNoPing.Service;

public sealed class Worker(ILogger<Worker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        logger.LogInformation("Qrioso NoPing service started; network engine is not enabled in this scaffold.");
        await Task.Delay(Timeout.InfiniteTimeSpan, stoppingToken);
    }
}

