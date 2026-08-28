# Qrioso NoPing — objetivo permanente del proyecto

## Objetivo

Construir **Qrioso NoPing**, un optimizador de rutas para juegos con una aplicación nativa y autocontenida para Windows. El primer juego es Fortnite NA-East y la primera infraestructura se ejecutará en AWS `us-east-1` (Virginia).

El producto debe medir si la ruta optimizada mejora ping, jitter o pérdida. Nunca debe prometer una reducción fija de latencia ni asumir que pasar por AWS siempre es mejor que la ruta directa del ISP.

## Requisitos no negociables del MVP

1. Usar una EC2 Linux `t4g.small` en `us-east-1` como relay inicial.
2. La aplicación Windows debe instalar todo lo necesario. El usuario no debe instalar WireGuard ni otra VPN por separado.
3. La aplicación debe incluir:
   - registro de una llave de acceso entregada por el propietario;
   - conexión y desconexión;
   - estado de las dos rutas;
   - ping, jitter, pérdida y ruta ganadora;
   - recuperación segura ante caídas o cambios de red.
4. No usar Cognito, Lambda, API Gateway, DynamoDB, SQS ni un panel administrativo para el MVP.
5. El archivo local `/etc/ridenow-noping/access-keys.yaml` en la EC2 será la única fuente de autorización.
6. El propietario crea y entrega cada llave. El usuario solamente la registra en la aplicación Windows.
7. Al eliminar o deshabilitar una llave del archivo, el servicio debe eliminar inmediatamente sus dos peers/túneles y cortar el acceso en un objetivo máximo de 10 segundos.
8. El MVP debe implementar multipath real con duplicación y deduplicación de paquetes:
   - Ruta A: Internet directo hacia la Elastic IP de la EC2.
   - Ruta B: AWS Global Accelerator UDP hacia la misma EC2.
   - el relay y el cliente entregan solo la primera copia recibida;
   - Fortnite debe ver una sola salida NAT y no dos sesiones distintas.
9. El tráfico de Fortnite debe seleccionarse sin inyectar código, leer memoria ni modificar el proceso del juego.
10. No registrar payloads, llaves de acceso completas ni claves privadas.

## Arquitectura técnica aprobada

- Windows: C# + .NET 10 LTS + WinUI 3.
- Componente privilegiado: Windows Service.
- Túneles portadores: dos instancias WireGuard embebidas mediante `tunnel.dll` + `wireguard.dll`; se distribuyen dentro del instalador firmado.
- Selección de tráfico: Windows Filtering Platform (WFP), con componente firmado si se necesita un callout de kernel.
- Multipath: motor propio de bonding con `sessionId`, número de secuencia, ventana de deduplicación y estrategia first-arrival-wins. No implementar criptografía propia; usar WireGuard como portador cifrado.
- Relay: Amazon Linux 2023 ARM64, dos interfaces WireGuard, daemon de bonding/deduplicación, TUN de salida y `nftables` para SNAT.
- Acceso: `ridenow-accessd`, un servicio HTTPS local en la EC2 que valida llaves, registra los dos peers y mantiene leases cortos.
- Archivo de acceso: `/etc/ridenow-noping/access-keys.yaml`, permisos `0640`, propietario `root:ridenow`.
- Administración: CLI local `ridenow-token` para agregar, listar, validar y revocar llaves mediante escritura atómica del archivo.
- Revocación: watcher del archivo + reconciliación periódica. Una llave eliminada debe cerrar sus leases y remover sus peers A/B.
- Transporte de la llave: siempre TLS con pin de certificado/SPKI o certificado público válido; nunca HTTP plano.
- Almacenamiento Windows: DPAPI; nunca guardar la llave en texto plano.
- Infraestructura como código: AWS CDK en TypeScript.
- Administración de EC2: Systems Manager Session Manager; no abrir SSH público.
- Prefijo AWS: `PROJECT_PREFIX`, valor predeterminado y requerido para este entorno `ridenow`. Todo recurso nombrable debe comenzar con `${PROJECT_PREFIX}-` aunque el producto visible se llame Qrioso NoPing.
- Dependencias en macOS: ejecutar CDK, Go y las pruebas .NET compartidas exclusivamente en Docker. No instalar dependencias del proyecto directamente en macOS.
- Release Windows: no usar compilación remota. El build completo se ejecuta en una PC Windows con `build-windows.ps1` y produce `dist/windows/QriosoNoPing-win-x64.zip`.
- Ciclo AWS: dividir CDK en `ridenow-noping-<stage>-core` y `ridenow-noping-<stage>-edge`.
  - `make infra-up` crea core solo si no existe, inicia la EC2 y crea edge; no actualiza el core durante el encendido diario.
  - `make infra-down` detiene la EC2 y elimina edge/Global Accelerator, conservando EBS, EIP y llaves.
  - `make infra-update` aplica cambios deliberados al core y exige `CONFIRM_UPDATE` exacto.
  - `make infra-destroy` elimina todo y debe exigir confirmación exacta porque borra las llaves del disco.
- Fijar la AMI ARM64 mediante `RELAY_AMI_ID`. No cambiarla automáticamente porque un reemplazo de EC2 puede borrar las llaves del volumen raíz.
- La aplicación debe obtener el endpoint de Global Accelerator al crear o renovar una sesión; nunca fijarlo, porque `infra-down` lo elimina y `infra-up` puede crear otro DNS/IP.

La referencia detallada y los diagramas están en `docs/architecture.md`. El plan por fases está en `PLAN.md`.

## Formato y ciclo de las llaves

- Formato recomendado: `qnp_<id>_<secreto-base64url-de-32-bytes>`.
- El archivo debe guardar `id`, hash del secreto, estado, límite de dispositivos y comentario; no guardar el secreto completo.
- `ridenow-token add --id <id>` genera una llave segura, imprime el valor completo una sola vez y guarda solo su hash.
- También se permitirá `ridenow-token add --id <id> --token <llave>` cuando el propietario quiera crear la llave por su cuenta.
- `ridenow-token revoke <id>` elimina/deshabilita la entrada de forma atómica y dispara la revocación inmediata.
- Una edición manual inválida debe fallar cerrada: no aceptar nuevas conexiones y alertar, sin aplicar parcialmente el archivo.

## Límites y honestidad técnica

- WireGuard no ofrece multipath por sí solo. Qrioso NoPing debe superponer un motor de bonding sobre dos túneles embebidos.
- Con una sola conexión ISP, ambas rutas comparten la última milla. La duplicación puede mejorar pérdida, jitter y latencia de cola después de que las rutas divergen; no reduce la velocidad física de propagación.
- Duplicar tráfico consume aproximadamente el doble de ancho de banda tunelizado y más CPU.
- El límite inicial de la `t4g.small` será 10 PC simultáneas hasta completar pruebas de carga.
- No usar bots, automatización de Fortnite ni técnicas que puedan interferir con Easy Anti-Cheat.

## Seguridad de cambios en AWS

- Perfil AWS confirmado: `ridenow-main`.
- Cuenta verificada: `009160027850`.
- Región efectiva y obligatoria del MVP: `us-east-1`.
- Antes de cualquier cambio, verificar y reportar:
  - `aws sts get-caller-identity`;
  - perfil efectivo;
  - Account ID;
  - región efectiva;
  - recursos existentes relevantes.
- No inventar IDs, dominio, cuenta ni topología.
- No desplegar hasta ejecutar las verificaciones anteriores y recibir autorización explícita para el despliegue.
- Ejecutar `cdk synth` y `cdk diff` antes de `cdk deploy`.
- Crear AWS Budget y alarmas de costo antes o junto con el primer despliegue.
- No reutilizar infraestructura de producción de otros proyectos.

## Definición de éxito técnico

La arquitectura pasa a beta solo cuando una prueba A/B repetible demuestra al menos una de estas mejoras durante partidas reales:

- mediana de RTT al menos 5 ms o 10% menor;
- p95 de latencia o jitter al menos 20% menor;
- pérdida de paquetes menor sin aumentar desconexiones.

La ruta directa debe permanecer disponible como fallback seguro.
