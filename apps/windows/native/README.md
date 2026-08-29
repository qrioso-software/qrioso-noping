# Componente nativo WFP

Esta carpeta contiene la implementación del selector de tráfico de Qrioso NoPing:

- `src/client/qrioso_wfp.cpp`: DLL del ABI consumido por el Windows Service, instalación idempotente, sesión WFP dinámica, descubrimiento de procesos y validación Authenticode de Epic Games;
- `src/driver/qrioso_wfp_driver.c`: callout WFP de kernel, asociación de flows, captura UDP IPv4, cola acotada y reinyección inbound;
- `src/driver/QriosoNoPing.Wfp.inf`: paquete del driver demand-start;
- `scripts/acquire-wireguard.ps1`: descarga WireGuardNT oficial con SHA-256 fijado y compila `tunnel.dll` desde un commit oficial fijado;
- `scripts/build-native.ps1`: compila DLL/SYS con Visual Studio + WDK y genera el catálogo exacto;
- `scripts/new-driver-submission.ps1`: crea y firma el CAB que se sube a Microsoft Partner Center;
- `scripts/prepare-test-driver.ps1`: firma SYS/CAT para una prueba local explícita en Windows Test Mode.

El artefacto de producción contiene:

```text
bin/x64/
  tunnel.dll
  wireguard.dll
  wireguard-provenance.json
  QriosoNoPing.Wfp.dll
  licenses/
  driver/
    QriosoNoPing.Wfp.inf
    QriosoNoPing.Wfp.sys
    QriosoNoPing.Wfp.cat
```

`build-windows.ps1` prepara automáticamente `tunnel.dll` y `wireguard.dll` cuando no están en el cache ignorado `bin/x64/`. El ZIP los incorpora y `install.ps1` los copia a `Program Files`; el usuario final no descarga ni instala WireGuard por separado.

El driver WFP se compila con WDK para x64. Windows 10/11 con Secure Boot exige que el catálogo vuelva firmado por Microsoft Hardware Dev Center. El build genera el CAB de entrega, pero no puede fabricar esa firma localmente. El build de producción nunca acepta test-signing ni un catálogo local.

## Build y firma

En una PC Windows con Visual Studio 2022, Desktop C++, Windows 11 SDK, WDK, Git y .NET 10:

```powershell
& .\apps\windows\native\scripts\acquire-wireguard.ps1
& .\apps\windows\native\scripts\build-native.ps1
& .\apps\windows\native\scripts\new-driver-submission.ps1 -SigningCertificateThumbprint <EV_THUMBPRINT>
```

Se sube `apps/windows/native/build/submission/QriosoNoPing-Wfp-attestation.cab` como attestation signing. Al terminar, se reemplazan los tres archivos dentro de `bin/x64/driver/` con los devueltos por Microsoft. Después se ejecuta `build-windows.ps1`; este se niega a producir el ZIP si el catálogo no es Microsoft-signed o no coincide exactamente con INF/SYS.

Para firmar la aplicación de una prueba exclusivamente en la misma PC puede crearse un certificado local con `scripts/new-development-certificate.ps1`. Ese certificado no es apto para distribución.

### Piloto local en una sola PC

Mientras Partner Center no esté disponible, el propietario puede probar el producto en su propia PC con Windows Test Mode. Esto mantiene separado el producto distribuible del piloto local:

En macOS, `make windows-command` imprime el comando completo. En Windows se pega ese comando en PowerShell como Administrador; `build-windows-pilot.ps1` instala .NET SDK 10 mediante `winget` si falta, crea o reutiliza el certificado de desarrollo y compila automáticamente el `.env.infra` local dentro del servicio. No se pasa ningún parámetro y el primer arranque registra la llave automáticamente.

```powershell
$gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue; $gitPath = if ($gitCommand) { $gitCommand.Source } else { $null }; if (-not $gitPath) { $winget = Get-Command winget.exe -ErrorAction SilentlyContinue; if (-not $winget) { throw "Git for Windows no está instalado y winget no está disponible." }; & $winget.Source install --id Git.Git --exact --source winget --scope machine --accept-source-agreements --accept-package-agreements; if ($LASTEXITCODE -ne 0) { throw "No se pudo instalar Git for Windows." }; $gitPath = Join-Path $env:ProgramFiles "Git\cmd\git.exe"; if (-not (Test-Path -LiteralPath $gitPath)) { throw "Git se instaló, pero no se encontró git.exe." } }; $env:Path = "$(Split-Path -Parent $gitPath);$env:Path"; & $gitPath pull --ff-only origin main; if ($LASTEXITCODE -ne 0) { throw "git pull falló." }; Set-ExecutionPolicy -Scope Process Bypass -Force; & ".\build-windows-pilot.ps1"
```

`build-windows.ps1` recompila el WFP, firma el SYS y el catálogo con el certificado `Development`, valida el catálogo exacto y marca el ZIP como `Test`. No distribuyas ese ZIP. Para regresar al modo normal ejecuta `bcdedit /set testsigning off` y reinicia. El flujo `Microsoft` sigue siendo obligatorio para otros usuarios o una release pública.

## Invariantes

- sesión WFP dinámica y no persistente; al cerrar el handle o morir el servicio desaparecen todos los filtros;
- captura exclusiva de UDP IPv4 público perteneciente a ejecutables de Fortnite autenticados por ruta y firma de Epic;
- exclusión del PID del servicio, de los portadores WireGuard y de destinos privados, loopback, link-local, multicast, metadata y rangos especiales;
- entrega de paquetes IPv4 completos de hasta 1356 bytes, sin truncado ni fragmentos;
- asociación de la respuesta con el flow original antes de reinyectarla;
- colas acotadas, cancelación segura de I/O y cero payloads en logs;
- instalación, upgrade, rollback y desinstalación mediante `QnpWfpInstall`/`QnpWfpUninstall`;
- fail-open: si no existe un lector activo, se agota la cola o falla una asignación, el paquete original sigue por el ISP.

La compatibilidad real con HVCI/Memory Integrity, Secure Boot y Easy Anti-Cheat debe comprobarse en la PC Windows con el paquete devuelto por Microsoft y una partida real; el source y el build por sí solos no prueban ese comportamiento externo.

`build-windows.ps1` se niega a crear el ZIP si falta un artefacto, si WireGuard no tiene firma válida o si el catálogo WFP no valida exactamente INF/SYS. Binarios, certificados, CAB y secretos están ignorados por Git.
