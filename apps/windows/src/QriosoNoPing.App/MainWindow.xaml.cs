using System.IO;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using QriosoNoPing.Core;
using Windows.Graphics;

namespace QriosoNoPing.App;

public sealed partial class MainWindow : Window
{
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
    }

    private void RegisterToken_Click(object sender, RoutedEventArgs e)
    {
        if (!AccessToken.TryParse(AccessTokenInput.Password, out AccessToken? token))
        {
            HeaderStatusDot.Fill = new SolidColorBrush(ColorHelper.FromArgb(255, 239, 101, 101));
            HeaderStatusText.Text = "LLAVE INVÁLIDA";
            ConfigurationLabel.Text = "Revisa la llave de acceso";
            ConfigurationDescription.Text = "El formato no coincide con una llave válida de Qrioso NoPing.";
            StatusBar.Severity = InfoBarSeverity.Error;
            StatusBar.Title = "Llave inválida";
            StatusBar.Message = "Verifica el formato de la llave entregada.";
            return;
        }

        AccessTokenInput.Password = string.Empty;
        HeaderStatusDot.Fill = (SolidColorBrush)Application.Current.Resources["BrandAccentBrush"];
        HeaderStatusText.Text = "LLAVE PREPARADA";
        ConfigurationLabel.Text = "Acceso preparado";
        ConfigurationDescription.Text = $"{token!.Redacted} está lista para validarse de forma segura contra el servidor.";
        StatusBar.Severity = InfoBarSeverity.Success;
        StatusBar.Title = "Formato válido";
        StatusBar.Message = $"{token.Redacted} quedó preparada; el secreto se ocultó de la pantalla.";
    }
}
