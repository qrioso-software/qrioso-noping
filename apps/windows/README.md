# Cliente Windows

Esta solución contiene la UI WinUI 3, el Windows Service y la lógica compartida. El usuario final no tendrá que instalar WireGuard; sus DLL y el componente WFP se incorporarán al paquete cuando se implemente el data plane.

`make windows-check` valida `QriosoNoPing.Core` desde macOS dentro de Docker. La compilación completa se hace únicamente en una PC Windows:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\build-windows.ps1
```

Requisitos de esa PC:

- Windows 11 x64;
- Visual Studio con desarrollo de escritorio .NET, WinUI/Windows App SDK y Windows 11 SDK;
- .NET SDK 10.

El resultado queda en `dist\windows\QriosoNoPing-win-x64.zip`. El ZIP incluye la aplicación, el servicio y scripts de instalación/desinstalación.

La identidad visible de Windows usa estos nombres:

- aplicación y proceso: `Qrioso NoPing.exe`;
- servicio y proceso privilegiado: `Qrioso NoPing Service.exe`;
- nombre interno del servicio: `QriosoNoPing`;
- accesos directos: `Qrioso NoPing`, con icono corporativo de Qrioso.

El artefacto actual es un build de desarrollo. Registra el servicio, pero todavía no contiene WireGuard/WFP y no debe distribuirse como MVP funcional.
