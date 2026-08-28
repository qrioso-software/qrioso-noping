# Modelo de seguridad del MVP

## Activos

- llaves de acceso completas y sus hashes;
- claves privadas WireGuard del relay y de cada PC;
- integridad del selector WFP, del servicio privilegiado y del instalador;
- autorización de peers, aislamiento entre sesiones y una única salida NAT;
- disponibilidad de la ruta directa al fallar Qrioso.

## Fronteras de confianza

- UI sin privilegios → named pipe local → Windows Service SYSTEM;
- Windows Service → HTTPS con pin SPKI → `ridenow-accessd`;
- cliente → dos túneles WireGuard → relay;
- `ridenow-token`/archivo local → watcher → peers/snapshot;
- repositorio fuente → PC Windows de firma → paquete distribuido;
- CDK/SSM → cuenta AWS `009160027850` en `us-east-1`.

## Controles

- secreto aleatorio de 32 bytes, representación base64url canónica, hash SHA-256 y comparación constante;
- token y claves de cliente bajo DPAPI `LocalMachine` más ACL SYSTEM/Administradores; temporales WireGuard fail-closed al borrar;
- TLS 1.2 mínimo y pin SPKI; límites de cuerpo, timeouts, concurrencia y rate limit por IP;
- peer distinto por ruta, AllowedIPs `/32`, máximo 10 clientes, lease de 10 segundos y reconciliación cada segundo;
- comprobación de session ID, IP interior asignada, modo, ruta, UDP IPv4 público, MTU y secuencia en el relay;
- deduplicadores O(1) acotados; saturación descarta en vez de crecer memoria;
- WFP dinámico: el cierre/crash elimina filtros y restaura la ruta directa;
- release firmado, manifiesto de todos los archivos, catálogo Microsoft, ACL de instalación y rollback;
- SSM/IMDSv2 sin SSH, EBS cifrado, bucket privado efímero, budget y alarmas.

## Datos prohibidos en logs

Payloads, tokens completos, hashes reutilizables como credencial y claves privadas. Se permiten IDs de llave, device ID, métricas agregadas, contadores y errores sanitizados.

## Riesgos residuales que bloquean release

- el driver WFP aún debe implementarse, firmarse y probarse en Windows real; el ABI administrado no sustituye esa evidencia;
- una cuenta local Administrador o SYSTEM puede acceder al estado de máquina y reemplazar software instalado;
- ambas rutas comparten la última milla y un único ISP puede tumbarlas simultáneamente;
- la renovación normal del certificado conserva la clave TLS y el pin SPKI; una rotación de esa clave exige un release coordinado antes de aplicarla;
- falta demostrar compatibilidad con Easy Anti-Cheat y capacidad real a 10 clientes;
- la infraestructura no existe hasta un despliegue explícitamente autorizado y verificado.
