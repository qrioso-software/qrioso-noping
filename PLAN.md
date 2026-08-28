# Qrioso NoPing

## Plan de ejecución del MVP

**Versión:** 0.6

**Fecha:** 28 de agosto de 2026

**Objetivo permanente:** ver `AGENTS.md`

**Arquitectura gráfica:** ver `docs/architecture.md`

## 1. Resultado que vamos a construir

Una aplicación nativa para Windows que:

- se instala como un solo producto, sin pedir al usuario instalar WireGuard;
- solicita una llave de acceso creada y entregada por el propietario;
- guarda esa llave protegida con DPAPI;
- comprueba contra la EC2 si la llave sigue autorizada;
- selecciona el tráfico de Fortnite sin modificar el proceso del juego;
- duplica cada paquete seleccionado por dos rutas cifradas;
- conserva la primera copia que llegue y descarta la segunda;
- muestra ping, jitter, pérdida, estado y ruta ganadora;
- vuelve de forma segura a la ruta directa si falla el relay o la llave es revocada.

No habrá Cognito, Lambda, API Gateway, DynamoDB, SQS ni panel administrativo en el MVP.

## 2. Decisiones técnicas

### Cliente Windows autocontenido

- C# + .NET 10 LTS + WinUI 3.
- Windows Service para operaciones privilegiadas.
- Dos túneles WireGuard embebidos usando `tunnel.dll` y `wireguard.dll`.
- Todo se distribuye dentro del instalador firmado de Qrioso NoPing.
- DPAPI para proteger la llave de acceso, configuraciones y claves locales.
- WFP para seleccionar tráfico de Fortnite.
- Motor propio de bonding/deduplicación encima de WireGuard.

El usuario no instalará la aplicación oficial WireGuard. Sí se instalarán internamente los componentes de red requeridos y Windows mostrará UAC durante la instalación.

### Autorización con archivo local

La única fuente de autorización será:

```text
/etc/ridenow-noping/access-keys.yaml
```

El archivo tendrá permisos `0640`, propietario `root:ridenow`, y guardará hashes, no las llaves completas:

```yaml
version: 1
keys:
  cliente-001:
    tokenHash: "sha256:..."
    enabled: true
    maxDevices: 1
    note: "PC de prueba"
```

Formato recomendado de la llave entregada:

```text
qnp_cliente-001_<secreto-base64url-de-32-bytes>
```

La aplicación presenta la llave a `ridenow-accessd` mediante HTTPS. El servicio valida el hash, registra las dos claves públicas WireGuard del cliente y entrega un lease corto con la configuración de ambos túneles.

La llave nunca viajará por HTTP plano. Para la prueba se usará TLS con pin de certificado/SPKI; si luego se dispone de un dominio, podrá utilizarse un certificado público normal.

### Administración simple

El propietario administrará las llaves desde SSM Session Manager:

```bash
sudo ridenow-token add --id cliente-001
sudo ridenow-token add --id cliente-002 --token 'qnp_cliente-002_...'
sudo ridenow-token list
sudo ridenow-token revoke cliente-001
sudo ridenow-token validate
```

`add` genera la llave y muestra el secreto completo una sola vez. `revoke` modifica el archivo de forma atómica. También será posible editar el archivo manualmente, pero el CLI evita errores de YAML y permisos.

### Revocación

`ridenow-accessd` observará el archivo con `inotify` y mantendrá una reconciliación periódica.

Al eliminar o deshabilitar una entrada:

1. invalidará los leases relacionados;
2. eliminará los peers del cliente en `wg-direct`;
3. eliminará los peers del cliente en `wg-accelerated`;
4. cerrará su sesión multipath;
5. la app restaurará la ruta directa al fallar el heartbeat.

Objetivo: corte efectivo en 10 segundos o menos, normalmente inmediato por el watcher.

### Data plane multipath

Ruta A:

```text
Windows -> WireGuard A -> Internet -> Elastic IP -> wg-direct
```

Ruta B:

```text
Windows -> WireGuard B -> AWS edge -> Global Accelerator -> wg-accelerated
```

Ambas llegan a la misma EC2 `t4g.small`. El relay deduplica antes de `nftables`, por lo que Fortnite recibe un solo paquete desde una sola salida NAT.

WireGuard no hace multipath por sí mismo. Qrioso NoPing agregará un encabezado interno con `sessionId`, número de secuencia y flags, enviará la misma trama por ambos túneles y mantendrá una ventana de deduplicación en cliente y relay. No se implementará criptografía propia.

## 3. AWS en Virginia

- Región: `us-east-1`.
- EC2: `t4g.small`, Amazon Linux 2023 ARM64.
- EBS `gp3` cifrado de 8-10 GiB.
- Elastic IP.
- Global Accelerator UDP.
- VPC con una subred pública e Internet Gateway.
- Solo HTTPS/TLS, puertos UDP del data plane y TCP de health check en el Security Group.
- Sin SSH; acceso administrativo con SSM Session Manager.
- IMDSv2 requerido.
- Dos interfaces WireGuard: `wg-direct` y `wg-accelerated`.
- `ridenow-accessd`, `ridenow-relay`, TUN `ridenow0` y `nftables`.
- CloudWatch, métricas ENA y AWS Budget.

El perfil confirmado es `ridenow-main`, cuenta `009160027850`, región `us-east-1`. El prefijo se controla con `PROJECT_PREFIX` y su valor predeterminado es `ridenow`; todos los recursos nombrables deben empezar con `${PROJECT_PREFIX}-`. No se desplegará sin revisar primero `cdk synth` y `cdk diff`.

### Ciclo de costo temporal

La infraestructura se divide en dos stacks:

- `ridenow-noping-dev-core`: EC2, EBS, EIP, VPC, IAM, SSM, alarmas y budget;
- `ridenow-noping-dev-edge`: Global Accelerator, listener y endpoint group.

`make infra-down` detiene la EC2 y elimina completamente `edge`, porque un acelerador deshabilitado continúa cobrando la tarifa fija. Conserva `core` para no perder `/etc/ridenow-noping/access-keys.yaml` ni la Elastic IP. `make infra-up` crea core solo si falta, inicia y espera la EC2, y vuelve a crear edge. Los cambios deliberados al core usan `make infra-update` con confirmación exacta.

La AMI ARM64 se fija mediante `RELAY_AMI_ID`; no se resolverá automáticamente la última AMI en cada encendido porque eso podría reemplazar la EC2 y perder el volumen raíz.

El DNS/IP de Global Accelerator puede cambiar después de cada recreación. El endpoint de ruta B siempre debe provenir de la respuesta de sesión de `ridenow-accessd`, no de una constante compilada en Windows.

## 4. Capacidad inicial

AWS publica 128 Mbps base para `t4g.small`. La duplicación usa aproximadamente dos veces el ancho de banda de un túnel simple.

```text
capacidad_red = floor(
  (128 Mbps * 0.60) /
  (Mbps_P95_por_PC * 2 copias)
)
```

Con una hipótesis conservadora de 0.5 Mbps por dirección y PC, la matemática de ancho de banda daría 76 PC. Eso no considera CPU, PPS, conntrack, WFP, wrappers, ráfagas ni latencia de deduplicación.

El límite operativo del MVP será **10 PC simultáneas**. Las pruebas subirán en escalones de 1, 5, 10, 15, 25 y 50.

No se aumentará el límite si ocurre cualquiera de estos puntos:

- CPU sostenida por encima de 50%;
- procesamiento del relay agrega más de 1 ms en p95;
- pérdida atribuible al relay igual o mayor a 0.1%;
- incremento en `bw_in_allowance_exceeded`;
- incremento en `bw_out_allowance_exceeded`;
- incremento en `pps_allowance_exceeded`;
- incremento en `conntrack_allowance_exceeded`.

## 5. Criterio de éxito

Compararemos cuatro modos en condiciones cercanas:

1. Directo sin Qrioso.
2. Solo ruta A por Elastic IP.
3. Solo ruta B por Global Accelerator.
4. Multipath A+B con first-arrival-wins.

El MVP será considerado útil si en partidas reales logra de forma repetible al menos una condición:

- mediana de RTT 5 ms o 10% menor;
- p95 de latencia o jitter 20% menor;
- pérdida menor sin más desconexiones.

La duplicación suele tener más potencial para mejorar jitter, pérdida y p95 que para reducir el ping mínimo. Con un solo ISP, ambas rutas todavía comparten la última milla.

## 6. Fases

### Fase 0 — Preparación y baseline (en progreso)

- Base del repositorio y comandos Docker creados.
- Crear ADR de multipath y llaves locales.
- Medir Fortnite NA-East directo en varias franjas horarias.
- Definir presupuesto y alarmas.
- Perfil, cuenta, región y recursos existentes verificados.

**Salida:** baseline y `cdk synth` sin desplegar.

### Fase 1 — Infraestructura base (implementada y validable; no desplegada por este cambio)

- CDK separado en core persistente y edge descartable.
- VPC, EC2, EIP, Global Accelerator, IAM, SSM y CloudWatch.
- `cdk diff` revisable.
- `infra-up`, `infra-down`, `infra-status` e `infra-destroy` con verificación de cuenta.
- Instalar los dos WireGuard, `ridenow-accessd` y el relay multipath.

**Salida:** una sola EC2 con data plane y autorización local.

### Fase 2 — Llaves y revocación (implementada; falta prueba E2E desplegada)

- Archivo `access-keys.yaml`.
- CLI `ridenow-token`.
- Alta con llave generada o proporcionada por el propietario.
- Validación HTTPS con certificado fijado.
- Watcher, leases y heartbeat.
- Prueba E2E: llave eliminada pierde ambos peers en menos de 10 segundos.

**Salida:** control de acceso simple, local y verificable.

### Fase 3 — App Windows single-path (código administrado implementado)

- Instalador único.
- Pantalla para registrar la llave.
- Windows Service.
- WireGuard embebido.
- Modo directo, ruta A y ruta B.
- Métricas y recuperación de rutas.

**Salida:** app autocontenida sin instalar WireGuard por separado.

### Fase 4 — Multipath y deduplicación (implementada; falta validación Windows/AWS)

- Encabezado interno y secuencias.
- Dos túneles simultáneos.
- Duplicación en ambas direcciones.
- Ventana de deduplicación.
- Reordenamiento limitado.
- Métricas por ruta y first-arrival-wins.
- Ajuste y prueba de MTU.

**Salida:** multipath real por EIP + Global Accelerator.

### Fase 5 — Selección de Fortnite (integración/ABI listos; driver firmado externo pendiente)

- WFP para identificar el ejecutable y conexiones UDP.
- Enviar solo tráfico seleccionado al motor multipath.
- Driver/callout firmado si el spike demuestra que es necesario.
- Validar Easy Anti-Cheat.
- Restauración limpia tras crash o desinstalación.

**Salida:** Fortnite usa Qrioso; el resto de Windows continúa directo.

### Fase 6 — Carga y beta privada

- Pruebas UDP sintéticas; no bots de Fortnite.
- Escalones de PC concurrentes.
- Revocación de llaves bajo carga.
- Upgrade y rollback del cliente.
- Informe A/B con partidas reales.

**Salida:** capacidad real y decisión GO/NO-GO.

## 7. Estructura del repositorio

```text
qrioso-noping/
  apps/
    windows/                 # WinUI, Service, WFP y multipath client
  infra/                     # CDK: VPC, EC2, EIP y Global Accelerator
  relay/
    cmd/                     # ridenow-token, accessd y relay
    internal/access/         # archivo de llaves y validación
    internal/multipath/      # ventana de deduplicación
    systemd/                 # unidades del servidor
  scripts/                   # todos los builds locales vía Docker
  build-windows.ps1          # build completo ejecutado en la PC Windows
  docs/
    architecture.md
    adr/
    experiments/
    security/
```

## 8. Costos que deben aceptarse

Al exigir dos rutas en el MVP, Global Accelerator sigue siendo obligatorio:

- acelerador: USD 0.025 por hora, unos USD 18.25/mes;
- dos IPv4 de Global Accelerator: aproximadamente USD 7.30/mes;
- IPv4 de la EC2: aproximadamente USD 3.65/mes;
- más EC2, EBS y transferencia;
- la duplicación aproxima el doble de bytes del juego dentro del túnel.

Con `infra-up` activo, el fijo de red ronda USD 29.20/mes antes de cómputo, almacenamiento y datos. `infra-down` elimina Global Accelerator y detiene el cómputo, pero mantiene cargos residuales de EBS, Elastic IP/IPv4 y monitoreo. Se crearán alertas de presupuesto al 50%, 80% y 100%.

## 9. Próximo paso para liberar

1. compilar el componente WFP x64 contra `apps/windows/native/include/qrioso_wfp.h` y completar pruebas WDK/Driver Verifier;
2. obtener el catálogo firmado por Microsoft Hardware Dev Center y preparar las DLL oficiales firmadas de WireGuard;
3. ejecutar `build-windows.ps1` en Windows con el pin SPKI y el certificado Authenticode de Qrioso;
4. revisar `make infra-synth` y `make infra-diff`; desplegar solamente con autorización explícita;
5. probar instalación/upgrade/rollback/crash, revocación menor a 10 segundos y 1/5/10 clientes;
6. validar Easy Anti-Cheat y completar partidas reales directo/A/B/A+B antes de decidir GO.

## 10. Fuentes principales

- [Arquitectura gráfica y fuentes detalladas](docs/architecture.md)
- [Epic Games: Fortnite latency and ping](https://www.epicgames.com/help/c-202300000001636/c-202300000001690/a202300000010042?lang=en-US)
- [AWS: especificaciones EC2 general purpose](https://docs.aws.amazon.com/ec2/latest/instancetypes/gp.html)
- [AWS: Global Accelerator pricing](https://aws.amazon.com/global-accelerator/pricing/)
