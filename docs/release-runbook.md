# Runbook de release y aceptación

Un release solo recibe estado **GO** cuando todos los gates siguientes tienen evidencia guardada. Compilar código o sintetizar CDK no equivale a probar producción.

## Estado verificable al 28 de agosto de 2026

- **PASS local:** 23/23 pruebas .NET, Windows Service `win-x64` sin warnings, pruebas Go normales y con detector de carreras, `go vet`, `govulncheck`, build ARM64, ShellCheck, parseo PowerShell, manifiesto/staging anti-tampering, `npm audit`, CDK synth/diff, validación CloudFormation y `cfn-lint`.
- **PATCHED:** la revisión de seguridad previa al parche encontró dos riesgos medios y dos bajos. Se cerraron el bypass entre interfaces WireGuard, el TOCTOU del instalador, la suplantación del servidor named-pipe y el agotamiento por mensajes/conexiones locales. Las pruebas de integración Windows de estos controles siguen perteneciendo al gate nativo.
- **HARDENED:** el rate limiter elimina clientes expirados antes de aplicar su tope global y `/uninstall-wfp` funciona aunque la configuración local esté ausente o dañada.
- **BLOCKED externo:** faltan el binario WFP x64, su catálogo firmado por Microsoft, las DLL oficiales de WireGuard, el certificado Authenticode de Qrioso y la ejecución de `build-windows.ps1` en Windows.
- **NO DEPLOY:** la cuenta, perfil, región, AMI y diff fueron verificados en modo lectura. AWS permanece sin recursos `ridenow-noping-*` porque no existe autorización explícita de despliegue.
- **NO-GO beta todavía:** faltan la aceptación en Windows/Easy Anti-Cheat, revocación y carga sobre AWS, y las partidas A/B exigidas por el criterio de éxito.

## 1. Gates locales

```bash
make relay-test
make relay-build
make windows-check
make infra-synth
make infra-diff
```

- cero fallos, carreras, warnings de compilación o findings críticos/altos abiertos;
- templates CloudFormation validados y diff revisado para la cuenta/región correctas;
- ningún secreto, binario nativo, certificado, `dist/`, `.env` o llave de acceso versionado.

## 2. Gate nativo Windows

- `tunnel.dll` y `wireguard.dll` oficiales con Authenticode válido;
- WFP x64 compilado con WDK contra `apps/windows/native/include/qrioso_wfp.h`;
- Driver Verifier sin errores durante captura, cambio de red, suspensión, crash y desinstalación;
- catálogo WFP firmado por Microsoft; Secure Boot y Memory Integrity permanecen habilitados;
- certificado Code Signing de Qrioso vigente por más de 30 días y timestamp RFC 3161 disponible;
- `build-windows.ps1` genera ZIP, SHA-256 y manifiesto firmado sin bypasses.

## 3. Gate de instalación

En una PC Windows limpia:

1. instalar como Administrador y comprobar Publisher, icono, Inicio y “Aplicaciones instaladas”;
2. confirmar `QriosoNoPing`, `WireGuardTunnel$QriosoRouteA/B` y el driver WFP;
3. registrar una llave y reiniciar Windows; comprobar que la llave nunca queda en texto plano;
4. probar upgrade exitoso y rollback provocado;
5. forzar cierre del servicio y verificar que desaparece el filtro, se detienen túneles y vuelve Internet directo;
6. desinstalar y confirmar que no quedan filtros, servicios, drivers ni datos, salvo uso explícito de `-KeepLocalAccess`.

## 4. Gate AWS

Antes de cualquier mutación confirmar `ridenow-main`, cuenta `009160027850`, `us-east-1`, stacks y recursos existentes. Ejecutar el despliegue solo después de autorización explícita del propietario.

Después de `infra-up`:

- ambos WireGuard activos, health público 8080 y health internos 8081/8082 correctos, certificado TLS con más de 30 días y Global Accelerator healthy;
- budget, SNS y alarmas `CPU`, `StatusCheck`, `ServiceHealthy` y `EnaAllowanceExceeded` presentes;
- `ridenow-token add/list/validate/revoke` conserva `root:ridenow 0640`;
- eliminar una llave quita ambos peers, vacía la sesión del relay y corta tráfico en menos de 10 segundos;
- `infra-down` elimina edge/Global Accelerator, detiene EC2 y conserva EIP/EBS/llaves.

## 5. Gate de red y juego

- pruebas UDP sintéticas en directo, A, B y A+B; MTU 1356 sin fragmentación;
- cambio Wi-Fi/Ethernet, pérdida de Internet, suspensión/reanudación y cambio de endpoint GA sin rutas huérfanas;
- escalones 1/5/10 PC sin allowance ENA, pérdida atribuible al relay ni procesamiento p95 mayor de 1 ms;
- Fortnite real con Easy Anti-Cheat, sin inyección de proceso, lectura de memoria ni automatización;
- varias partidas y franjas horarias con evidencia de mediana, p95, jitter, pérdida y desconexiones.

GO exige al menos uno de los criterios del MVP y ninguna regresión de desconexiones. Si no mejora, el resultado correcto es NO-GO; nunca se promete reducción fija de ping.

## 6. Rollback

- cliente: desconectar, restaurar ruta directa y ejecutar el desinstalador firmado; el instalador restaura automáticamente la versión anterior si el upgrade falla;
- relay: revisar `journalctl` y health; no editar peers manualmente salvo incidente controlado;
- costo/incidente: `make infra-down` elimina edge y detiene cómputo sin borrar llaves;
- destrucción total: solo `CONFIRM_DESTROY=ridenow-noping-dev make infra-destroy`, entendiendo que elimina el disco y las llaves.
