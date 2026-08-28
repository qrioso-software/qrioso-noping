# Cliente Windows

La solución contiene la UI WinUI 3, el Windows Service privilegiado y la lógica compartida. La app registra la llave contra `ridenow-accessd`, la guarda con DPAPI `LocalMachine` dentro de un directorio accesible solo por SYSTEM/Administradores, crea dos túneles WireGuard embebidos y ejecuta el motor A/B/A+B con métricas por ruta y fallback directo.

La identidad visible es:

- aplicación/proceso: `Qrioso NoPing.exe`;
- servicio/proceso privilegiado: `Qrioso NoPing Service.exe`;
- servicio interno: `QriosoNoPing`;
- editor: Qrioso Software Consulting.

## Verificación desde macOS

`make windows-check` ejecuta en Docker todas las pruebas portables. El Windows Service también se compila con targeting Windows dentro del contenedor. WinUI/XAML, el driver y el release firmado solo se pueden compilar y probar en Windows.

## Release en Windows

Requisitos:

- Windows 11 x64 con Secure Boot y Memory Integrity habilitables;
- Visual Studio/Build Tools con .NET Desktop, WinUI, Windows 11 SDK y WDK;
- .NET SDK 10;
- certificado Authenticode de Qrioso con clave privada;
- DLL oficiales firmadas `tunnel.dll` y `wireguard.dll`;
- componente WFP x64 con catálogo firmado por Microsoft Hardware Dev Center.

Los artefactos nativos usan la estructura documentada en `native/README.md`. El build de producción es deliberadamente fail-closed:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\build-windows.ps1 `
  -AccessApiBaseUri "https://<ELASTIC-IP>:8443" `
  -TlsSpkiPin "sha256/<PIN-SPKI>" `
  -SigningCertificateThumbprint "<THUMBPRINT-QRIOSO>"
```

Produce `dist\windows\QriosoNoPing-win-x64.zip`. El paquete lleva configuración TLS sellada, firmas con timestamp, catálogo WFP validado y un manifiesto SHA-256 firmado. `install.ps1` verifica todo antes de elevar cambios, instala/actualiza WFP, aplica ACL, registra recuperación del servicio, crea accesos directos y registra la app en “Aplicaciones instaladas”. Ante un error restaura la versión anterior.

El repositorio no contiene binarios, drivers, certificados ni secretos de release. Sin esos insumos `build-windows.ps1` no genera el ZIP.
