namespace QriosoNoPing.Service;

public sealed class Worker(
    ILogger<Worker> logger,
    NetworkController controller,
    ServiceCommandServer commandServer) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        logger.LogInformation("Qrioso NoPing privileged service started.");
        await controller.InitializeAsync(stoppingToken);
        await commandServer.RunAsync(stoppingToken);
    }

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        await controller.ShutdownAsync();
        await base.StopAsync(cancellationToken);
    }
}
