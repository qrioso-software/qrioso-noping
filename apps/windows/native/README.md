# Componente nativo WFP

El servicio administrado consume el ABI definido en `include/qrioso_wfp.h`. El artefacto de producción debe contener:

```text
bin/x64/
  tunnel.dll
  wireguard.dll
  QriosoNoPing.Wfp.dll
  driver/
    QriosoNoPing.Wfp.inf
    QriosoNoPing.Wfp.sys
    QriosoNoPing.Wfp.cat
```

`tunnel.dll` y `wireguard.dll` deben provenir del paquete oficial embebible de WireGuard y conservar una firma Authenticode válida. El driver WFP debe compilarse con WDK para x64 y su catálogo debe estar firmado por Microsoft mediante Hardware Dev Center/attestation signing. No se permite test-signing, desactivar Secure Boot ni instalar certificados raíz de prueba en una distribución.

## Invariantes obligatorias

- sesión WFP dinámica y no persistente; al cerrar el handle o morir el servicio desaparecen todos los filtros;
- captura exclusiva de UDP IPv4 público perteneciente a ejecutables de Fortnite autenticados por ruta y firma de Epic;
- exclusión del PID del servicio, de los dos portadores WireGuard y de destinos privados, loopback, link-local, multicast, metadata y rangos especiales;
- entrega de paquetes completos de hasta 1356 bytes, sin truncado ni fragmentos;
- asociación de la respuesta con el flow original antes de reinyectarla;
- colas acotadas, cancelación segura de I/O y cero payloads en logs;
- instalación, upgrade, rollback y desinstalación idempotentes mediante `QnpWfpInstall`/`QnpWfpUninstall`;
- compatibilidad comprobada con HVCI/Memory Integrity, Secure Boot y Easy Anti-Cheat.

`build-windows.ps1` se niega a crear el ZIP si falta cualquiera de estos archivos, si WireGuard no tiene firma válida o si el catálogo WFP no valida exactamente el contenido del driver. Los binarios generados y certificados nunca se versionan en Git.
