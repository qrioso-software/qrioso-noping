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
- Visual Studio/Build Tools con .NET Desktop, C++ x64, WinUI, Windows 11 SDK y WDK;
- .NET SDK 10;
- Git for Windows y acceso de red durante la primera preparación nativa;
- certificado Authenticode de Qrioso con clave privada;
- acceso a Microsoft Partner Center con un certificado EV asociado para devolver el catálogo del driver firmado.

`build-windows.ps1` descarga `wireguard.dll` desde WireGuardNT, compila `tunnel.dll` desde source oficial fijado y compila el componente WFP desde `native/`. Esos archivos se incorporan al paquete y se instalan automáticamente; el usuario no instala WireGuard por separado. La firma Microsoft del catálogo WFP sigue el flujo de `native/README.md`. El build de producción es deliberadamente fail-closed:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\build-windows.ps1 `
  -SigningCertificateThumbprint "<THUMBPRINT-QRIOSO>"
```

En el piloto privado actual, el build lee automáticamente `.env.infra` desde la raíz del proyecto y compila el endpoint de acceso, el pin TLS y el token dentro del Windows Service. No se pasan parámetros: la llave se registra automáticamente en el primer arranque y el estado queda protegido con DPAPI. `.env.infra` está ignorado por Git y debe permanecer únicamente en la PC del propietario. Este acoplamiento es temporal y se sustituirá por el flujo definitivo de la aplicación de escritorio.

Produce `dist\windows\QriosoNoPing-win-x64.zip`. El paquete lleva configuración TLS sellada, firmas con timestamp, catálogo WFP validado y un manifiesto SHA-256 firmado. `install.ps1` verifica todo antes de elevar cambios, instala/actualiza WFP, aplica ACL, registra recuperación del servicio, crea accesos directos y registra la app en “Aplicaciones instaladas”. Ante un error restaura la versión anterior.

Para probar exclusivamente en la misma PC sin esperar Partner Center existe `-DriverSigningMode Test`, usando el certificado creado por `native\scripts\new-development-certificate.ps1` y Windows Test Mode. El valor predeterminado `Microsoft` sigue siendo el único build de producción y exige el catálogo oficial.

El repositorio no contiene binarios, certificados ni secretos de release. Conserva source, INF y scripts reproducibles; los outputs de `native/bin`, `native/build`, CAB y `dist` permanecen ignorados.
