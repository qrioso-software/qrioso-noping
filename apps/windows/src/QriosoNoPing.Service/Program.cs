using QriosoNoPing.Service;

HostApplicationBuilder builder = Host.CreateApplicationBuilder(args);
builder.Services.AddWindowsService(options => options.ServiceName = "QriosoNoPing");
builder.Services.AddHostedService<Worker>();

IHost host = builder.Build();
await host.RunAsync();
