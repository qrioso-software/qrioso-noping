using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;

namespace QriosoNoPing.App;

public partial class App : Application
{
    private const string AppUserModelId = "QriosoSoftwareConsulting.QriosoNoPing";
    private Window? window;

    [LibraryImport("shell32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int SetCurrentProcessExplicitAppUserModelID(string appId);

    public App()
    {
        _ = SetCurrentProcessExplicitAppUserModelID(AppUserModelId);
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window = new MainWindow();
        window.Activate();
    }
}
