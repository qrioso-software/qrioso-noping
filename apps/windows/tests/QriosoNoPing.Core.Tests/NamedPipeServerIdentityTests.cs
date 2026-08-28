using QriosoNoPing.Core;
using Xunit;

namespace QriosoNoPing.Core.Tests;

public sealed class NamedPipeServerIdentityTests
{
    [Fact]
    public void AcceptsOnlyCanonicalInstalledServicePath()
    {
        string programFiles = Path.Combine(Path.GetTempPath(), "Program Files");
        string expectedService = Path.Combine(programFiles, "Qrioso NoPing", "service", "Qrioso NoPing Service.exe");

        Assert.True(NamedPipeServerIdentity.IsExpectedInstalledPath(
            expectedService,
            programFiles));
        Assert.False(NamedPipeServerIdentity.IsExpectedInstalledPath(
            Path.Combine(Path.GetTempPath(), "Public", "Qrioso NoPing Service.exe"),
            programFiles));
        Assert.False(NamedPipeServerIdentity.IsExpectedInstalledPath(
            expectedService + ".malicious",
            programFiles));
    }
}
