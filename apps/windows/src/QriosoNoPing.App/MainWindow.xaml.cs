using System.Globalization;
using System.IO;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using QriosoNoPing.Core;
using Windows.Graphics;

namespace QriosoNoPing.App;

public sealed partial class MainWindow : Window
{
    private static readonly SolidColorBrush NeutralBrush = Brush(123, 131, 159);
    private static readonly SolidColorBrush SuccessBrush = Brush(68, 217, 170);
    private static readonly SolidColorBrush WarningBrush = Brush(247, 190, 78);
    private static readonly SolidColorBrush ErrorBrush = Brush(239, 101, 101);

    private readonly ServiceControlClient service = new();
    private readonly SemaphoreSlim requestGate = new(1, 1);
    private readonly DispatcherQueueTimer refreshTimer;
    private bool closing;

    public MainWindow()
    {
        InitializeComponent();
        Title = "Qrioso NoPing";
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);

        AppWindow.Title = "Qrioso NoPing";
        AppWindow.Resize(new SizeInt32(1180, 760));
        AppWindow.TitleBar.ButtonBackgroundColor = Colors.Transparent;
        AppWindow.TitleBar.ButtonInactiveBackgroundColor = Colors.Transparent;
        AppWindow.TitleBar.ButtonForegroundColor = Colors.White;
        AppWindow.TitleBar.ButtonInactiveForegroundColor = ColorHelper.FromArgb(255, 169, 177, 207);

        string iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "QriosoNoPing.ico");
        if (File.Exists(iconPath))
        {
            AppWindow.SetIcon(iconPath);
        }

        refreshTimer = DispatcherQueue.CreateTimer();
        refreshTimer.Interval = TimeSpan.FromSeconds(1);
        refreshTimer.Tick += RefreshTimer_Tick;
        refreshTimer.Start();
        Closed += MainWindow_Closed;
        _ = RefreshStatusAsync(showConnectionError: true);
    }

    private async void RegisterToken_Click(object sender, RoutedEventArgs e)
    {
        string tokenValue = AccessTokenInput.Password;
        if (!AccessToken.TryParse(tokenValue, out _))
        {
            ShowError("Llave inválida", "Verifica el formato de la llave entregada por Qrioso.");
            return;
        }

        AccessTokenInput.Password = string.Empty;
        await SendAsync(new ServiceRequest(ServiceCommands.Register, tokenValue), "Registrando llave…");
    }

    private async void Connect_Click(object sender, RoutedEventArgs e) =>
        await SendAsync(new ServiceRequest(ServiceCommands.Connect, Mode: SelectedMode()), "Preparando la ruta seleccionada…");

    private async void Disconnect_Click(object sender, RoutedEventArgs e) =>
        await SendAsync(new ServiceRequest(ServiceCommands.Disconnect), "Restaurando la ruta directa…");

    private async void RefreshTimer_Tick(DispatcherQueueTimer sender, object args)
    {
        if (!closing)
        {
            await RefreshStatusAsync(showConnectionError: false);
        }
    }

    private void MainWindow_Closed(object sender, WindowEventArgs args)
    {
        closing = true;
        refreshTimer.Stop();
        refreshTimer.Tick -= RefreshTimer_Tick;
    }

    private async Task SendAsync(ServiceRequest request, string pendingMessage)
    {
        if (!await requestGate.WaitAsync(0))
        {
            return;
        }

        try
        {
            SetControlsEnabled(false);
            StatusBar.Severity = InfoBarSeverity.Informational;
            StatusBar.Title = "Procesando";
            StatusBar.Message = pendingMessage;
            ServiceResponse response = await service.SendAsync(request);
            ApplyStatus(response.Status);
            if (!response.Success)
            {
                ShowError("No se pudo completar", response.Error ?? "El servicio rechazó la operación.");
            }
        }
        catch (Exception exception) when (exception is IOException or TimeoutException or UnauthorizedAccessException or InvalidDataException or OperationCanceledException)
        {
            ShowServiceUnavailable();
        }
        finally
        {
            requestGate.Release();
        }
    }

    private async Task RefreshStatusAsync(bool showConnectionError)
    {
        if (!await requestGate.WaitAsync(0))
        {
            return;
        }

        try
        {
            ServiceResponse response = await service.SendAsync(new ServiceRequest(ServiceCommands.Status));
            ApplyStatus(response.Status);
        }
        catch (Exception exception) when (exception is IOException or TimeoutException or UnauthorizedAccessException or InvalidDataException or OperationCanceledException)
        {
            if (showConnectionError)
            {
                ShowServiceUnavailable();
            }
        }
        finally
        {
            requestGate.Release();
        }
    }

    private void ApplyStatus(ServiceStatus status)
    {
        bool connected = string.Equals(status.State, "connected", StringComparison.OrdinalIgnoreCase);
        bool busy = status.State is "connecting" or "registering";
        HeaderStatusDot.Fill = connected ? SuccessBrush : busy ? WarningBrush : NeutralBrush;
        HeaderStatusText.Text = status.State switch
        {
            "connected" => "CONECTADO",
            "connecting" => "CONECTANDO",
            "registering" => "REGISTRANDO",
            "disconnected" => "LISTO",
            _ => "SIN CONFIGURAR"
        };

        ConfigurationLabel.Text = status.State switch
        {
            "connected" => "Protección multipath activa",
            "connecting" => "Preparando conexión segura",
            "registering" => "Validando acceso",
            "disconnected" => "Listo para conectar",
            _ => "Prepara tu acceso privado"
        };
        ConfigurationDescription.Text = status.Message ?? (connected
            ? status.Mode == "duplicate"
                ? "Las dos rutas están activas y se entrega solamente la primera copia recibida."
                : "El tráfico del juego usa solamente la ruta seleccionada para esta sesión."
            : "Registra la llave entregada por Qrioso para habilitar la conexión.");

        MultipathFeatureStatus.Text = connected
            ? status.Mode == "duplicate" ? "Duplicación y deduplicación activas" : "Modo de ruta única activo"
            : "Servicio desconectado";
        EncryptionFeatureStatus.Text = connected ? "Túneles cifrados administrados" : "Administrado por Qrioso";
        MetricsFeatureStatus.Text = connected ? "Medición en tiempo real" : "Se activa al conectar";
        RouteAStatusText.Text = connected ? status.Mode == "route-b" ? "INACTIVA" : RouteState(status.RouteA) : "DESCONECTADA";
        RouteBStatusText.Text = connected ? status.Mode == "route-a" ? "INACTIVA" : RouteState(status.RouteB) : "DESCONECTADA";

        RouteMetricsSnapshot winningMetrics = status.WinningRoute == "Ruta B" ? status.RouteB : status.RouteA;
        PingMetricText.Text = FormatMilliseconds(winningMetrics.MedianRttMs);
        JitterMetricText.Text = FormatMilliseconds(winningMetrics.JitterMs);
        LossMetricText.Text = connected && winningMetrics.Sent > 0
            ? $"{winningMetrics.LossPercent.ToString("0.0", CultureInfo.CurrentCulture)} %"
            : "— %";
        WinningRouteText.Text = connected ? status.WinningRoute : "—";
        PingMetricDetail.Text = winningMetrics.P95RttMs is double p95
            ? $"p95 {p95.ToString("0.0", CultureInfo.CurrentCulture)} ms"
            : "Mediana de la ruta ganadora";

        SetControlsEnabled(!busy);
        RegisterButton.IsEnabled = !connected && !busy;
        ConnectButton.IsEnabled = status.HasAccessToken && !connected && !busy;
        DisconnectButton.IsEnabled = connected && !busy;
        ModeSelector.IsEnabled = !connected && !busy;
        if (!connected && !busy)
        {
            ModeSelector.SelectedIndex = status.Mode switch { "route-a" => 0, "route-b" => 1, _ => 2 };
        }

        StatusBar.Severity = connected ? InfoBarSeverity.Success : InfoBarSeverity.Informational;
        StatusBar.Title = connected ? "Protección activa" : status.HasAccessToken ? "Acceso registrado" : "Sin configurar";
        StatusBar.Message = status.Message ?? "Servicio disponible.";
    }

    private void SetControlsEnabled(bool enabled)
    {
        AccessTokenInput.IsEnabled = enabled;
        ModeSelector.IsEnabled = enabled;
        RegisterButton.IsEnabled = enabled;
        ConnectButton.IsEnabled = enabled;
        DisconnectButton.IsEnabled = enabled;
    }

    private void ShowError(string title, string message)
    {
        HeaderStatusDot.Fill = ErrorBrush;
        HeaderStatusText.Text = "REQUIERE ATENCIÓN";
        StatusBar.Severity = InfoBarSeverity.Error;
        StatusBar.Title = title;
        StatusBar.Message = message;
    }

    private void ShowServiceUnavailable()
    {
        SetControlsEnabled(false);
        RegisterButton.IsEnabled = false;
        ConnectButton.IsEnabled = false;
        DisconnectButton.IsEnabled = false;
        HeaderStatusDot.Fill = ErrorBrush;
        HeaderStatusText.Text = "SERVICIO NO DISPONIBLE";
        ConfigurationLabel.Text = "El servicio de Qrioso no responde";
        ConfigurationDescription.Text = "Repara o reinstala Qrioso NoPing antes de intentar conectar.";
        StatusBar.Severity = InfoBarSeverity.Error;
        StatusBar.Title = "Servicio no disponible";
        StatusBar.Message = "Windows no pudo comunicarse con Qrioso NoPing Service.";
    }

    private static string RouteState(RouteMetricsSnapshot metrics) => metrics.Received > 0 ? "ACTIVA" : "VERIFICANDO";

    private static string FormatMilliseconds(double? value) => value is double milliseconds
        ? $"{milliseconds.ToString("0.0", CultureInfo.CurrentCulture)} ms"
        : "— ms";

    private string SelectedMode() => (ModeSelector.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "duplicate";

    private static SolidColorBrush Brush(byte red, byte green, byte blue) =>
        new(ColorHelper.FromArgb(255, red, green, blue));
}
