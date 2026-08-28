#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <wchar.h>

#if defined(QNP_WFP_EXPORTS)
#define QNP_API __declspec(dllexport)
#else
#define QNP_API __declspec(dllimport)
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Installs or upgrades the Microsoft-attestation-signed WFP driver package.
QNP_API bool __cdecl QnpWfpInstall(const wchar_t* driver_directory, int32_t* error_code);

// Removes all filters, stops the driver and removes its package.
QNP_API bool __cdecl QnpWfpUninstall(int32_t* error_code);

// Opens a dynamic WFP session. executable_names is a semicolon-separated
// allowlist; the native component must resolve and authenticate the Epic-signed
// executable paths before it captures their public IPv4 UDP flows. The proxy
// process must always be excluded to prevent a routing loop.
QNP_API void* __cdecl QnpWfpOpen(const wchar_t* executable_names, uint32_t proxy_process_id, int32_t* error_code);

// Returns 1 with one complete IPv4 UDP packet, 0 on timeout and -1 on error.
// Packets larger than capacity must fail closed and must never be truncated.
QNP_API int32_t __cdecl QnpWfpRead(void* handle, uint8_t* buffer, int32_t capacity, int32_t* packet_length, int32_t timeout_ms);

// Injects one authenticated response into the original Fortnite UDP flow.
QNP_API int32_t __cdecl QnpWfpInjectInbound(void* handle, const uint8_t* packet, int32_t packet_length);

// Closes the dynamic session. All filters must disappear even after a service
// crash so Windows immediately returns to the normal ISP route.
QNP_API void __cdecl QnpWfpClose(void* handle);

#ifdef __cplusplus
}
#endif
