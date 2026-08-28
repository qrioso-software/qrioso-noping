using System.ComponentModel;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace QriosoNoPing.Core;

public static class NamedPipeServerIdentity
{
    private const uint ProcessQueryLimitedInformation = 0x1000;
    private const string ServiceExecutableName = "Qrioso NoPing Service.exe";

    public static void AssertTrustedInstalledService(NamedPipeClientStream pipe)
    {
        ArgumentNullException.ThrowIfNull(pipe);
        if (!OperatingSystem.IsWindows() || !pipe.IsConnected)
        {
            throw new UnauthorizedAccessException("The Qrioso service identity cannot be verified.");
        }

        if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle, out uint processId) || processId == 0)
        {
            throw new UnauthorizedAccessException("The Qrioso service process could not be identified.", new Win32Exception(Marshal.GetLastPInvokeError()));
        }

        nint process = OpenProcess(ProcessQueryLimitedInformation, false, processId);
        if (process == 0)
        {
            throw new UnauthorizedAccessException("The Qrioso service process could not be inspected.", new Win32Exception(Marshal.GetLastPInvokeError()));
        }

        try
        {
            StringBuilder imagePath = new(32768);
            uint capacity = checked((uint)imagePath.Capacity);
            if (!QueryFullProcessImageName(process, 0, imagePath, ref capacity) ||
                !IsExpectedInstalledPath(imagePath.ToString(), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles)))
            {
                throw new UnauthorizedAccessException("The named pipe is not owned by the installed Qrioso service.");
            }
        }
        finally
        {
            _ = CloseHandle(process);
        }
    }

    public static bool IsExpectedInstalledPath(string actualPath, string programFilesPath)
    {
        if (string.IsNullOrWhiteSpace(actualPath) || string.IsNullOrWhiteSpace(programFilesPath))
        {
            return false;
        }

        string expectedPath = Path.GetFullPath(Path.Combine(programFilesPath, "Qrioso NoPing", "service", ServiceExecutableName));
        string normalizedActual = Path.GetFullPath(actualPath);
        return string.Equals(normalizedActual, expectedPath, StringComparison.OrdinalIgnoreCase);
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint serverProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern nint OpenProcess(uint desiredAccess, [MarshalAs(UnmanagedType.Bool)] bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryFullProcessImageName(nint process, uint flags, StringBuilder executableName, ref uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(nint handle);
}
