using QriosoNoPing.Service;

public static class Program
{
    public static async Task<int> Main(string[] args)
    {
        if (args is ["/uninstall-wfp"])
        {
            string nativeDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                "Qrioso NoPing", "service", "native");
            return WfpPacketInterceptor.Uninstall(nativeDirectory);
        }

        ServiceConfiguration configuration = ServiceConfiguration.Load();
        if (args is ["/wireguard-service", string configFile])
        {
            return new WireGuardNative(configuration).RunTunnelService(configFile) ? 0 : 1;
        }
        if (args is ["/install-wfp"])
        {
            return WfpPacketInterceptor.Install(configuration);
        }
        HostApplicationBuilder builder = Host.CreateApplicationBuilder(args);
        builder.Services.AddWindowsService(options => options.ServiceName = "QriosoNoPing");
        builder.Services.AddSingleton(configuration);
        builder.Services.AddSingleton<ProtectedStateStore>();
        builder.Services.AddSingleton<WireGuardNative>();
        builder.Services.AddSingleton<AccessApiClient>();
        builder.Services.AddSingleton<WireGuardTunnelManager>();
        builder.Services.AddSingleton<NetworkController>();
        builder.Services.AddSingleton<ServiceCommandServer>();
        builder.Services.AddHostedService<Worker>();

        using IHost host = builder.Build();
        await host.RunAsync();
        return 0;
    }
}
