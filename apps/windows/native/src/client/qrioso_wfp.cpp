#define QNP_WFP_EXPORTS
#define WIN32_LEAN_AND_MEAN

#include <Windows.h>
#include <fwpmu.h>
#include <newdev.h>
#include <TlHelp32.h>
#include <wincrypt.h>
#include <wintrust.h>
#include <Softpub.h>

#include <algorithm>
#include <cwctype>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "../../include/qrioso_wfp.h"
#include "../../include/qrioso_wfp_ioctl.h"

#pragma comment(lib, "Advapi32.lib")
#pragma comment(lib, "Crypt32.lib")
#pragma comment(lib, "Fwpuclnt.lib")
#pragma comment(lib, "Newdev.lib")
#pragma comment(lib, "Wintrust.lib")

namespace
{
    const GUID ProviderKey =
        {0x17c5d199, 0x7358, 0x4496, {0xb7, 0xfc, 0x75, 0x30, 0x82, 0xf0, 0xb4, 0x56}};
    const GUID SublayerKey =
        {0x8b889103, 0xe0d5, 0x437b, {0xaf, 0x59, 0x27, 0x13, 0xa0, 0x9d, 0xb9, 0x41}};
    const GUID AleCalloutKey =
        {0x876d4075, 0x955f, 0x4932, {0xba, 0xb5, 0xf4, 0x6a, 0x33, 0xb8, 0x58, 0xfc}};
    const GUID TransportCalloutKey =
        {0x409bc739, 0xfd2a, 0x42b1, {0x97, 0xca, 0x3e, 0xa4, 0x73, 0x67, 0xff, 0x67}};

    constexpr wchar_t DevicePath[] = L"\\\\.\\QriosoNoPingWfp";
    constexpr wchar_t DriverServiceName[] = L"QriosoNoPingWfp";
    constexpr DWORD MaximumExecutableNames = 16;

    struct WfpContext
    {
        HANDLE Device = INVALID_HANDLE_VALUE;
        HANDLE Engine = nullptr;
        HANDLE StopEvent = nullptr;
        HANDLE MonitorThread = nullptr;
        DWORD ProxyProcessId = 0;
        std::vector<std::wstring> ExecutableNames;
        std::set<std::wstring> FilteredPaths;
    };

    void SetError(int32_t* errorCode, DWORD value)
    {
        if (errorCode != nullptr)
            *errorCode = static_cast<int32_t>(value == ERROR_SUCCESS ? ERROR_GEN_FAILURE : value);
    }

    bool DeviceIoControlSync(HANDLE device, DWORD code, void* input, DWORD inputLength, void* output, DWORD outputLength, DWORD* bytesReturned)
    {
        HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (event == nullptr)
            return false;
        OVERLAPPED overlapped{};
        overlapped.hEvent = event;
        DWORD transferred = 0;
        BOOL started = DeviceIoControl(device, code, input, inputLength, output, outputLength, &transferred, &overlapped);
        if (!started && GetLastError() == ERROR_IO_PENDING)
            started = GetOverlappedResult(device, &overlapped, &transferred, TRUE);
        DWORD error = started ? ERROR_SUCCESS : GetLastError();
        CloseHandle(event);
        if (bytesReturned != nullptr)
            *bytesReturned = transferred;
        SetLastError(error);
        return started != FALSE;
    }

    std::wstring ToLower(std::wstring value)
    {
        std::transform(value.begin(), value.end(), value.begin(), [](wchar_t character)
        {
            return static_cast<wchar_t>(towlower(character));
        });
        return value;
    }

    bool ParseExecutableNames(const wchar_t* input, std::vector<std::wstring>& names)
    {
        if (input == nullptr || *input == L'\0')
            return false;
        std::wstring value(input);
        size_t start = 0;
        while (start <= value.size())
        {
            size_t end = value.find(L';', start);
            std::wstring name = value.substr(start, end == std::wstring::npos ? value.size() - start : end - start);
            if (name.empty() || name.size() > MAX_PATH || name.find_first_of(L"\\/:") != std::wstring::npos ||
                name.size() < 5 || _wcsicmp(name.c_str() + name.size() - 4, L".exe") != 0)
                return false;
            name = ToLower(name);
            if (std::find(names.begin(), names.end(), name) == names.end())
                names.push_back(std::move(name));
            if (names.size() > MaximumExecutableNames)
                return false;
            if (end == std::wstring::npos)
                break;
            start = end + 1;
        }
        return !names.empty();
    }

    bool VerifyTrustedSignature(const std::wstring& path)
    {
        WINTRUST_FILE_INFO fileInfo{};
        fileInfo.cbStruct = sizeof(fileInfo);
        fileInfo.pcwszFilePath = path.c_str();
        WINTRUST_DATA trustData{};
        trustData.cbStruct = sizeof(trustData);
        trustData.dwUIChoice = WTD_UI_NONE;
        trustData.fdwRevocationChecks = WTD_REVOKE_WHOLECHAIN;
        trustData.dwUnionChoice = WTD_CHOICE_FILE;
        trustData.pFile = &fileInfo;
        trustData.dwStateAction = WTD_STATEACTION_VERIFY;
        trustData.dwProvFlags = WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT;
        GUID policy = WINTRUST_ACTION_GENERIC_VERIFY_V2;
        LONG result = WinVerifyTrust(nullptr, &policy, &trustData);
        trustData.dwStateAction = WTD_STATEACTION_CLOSE;
        WinVerifyTrust(nullptr, &policy, &trustData);
        return result == ERROR_SUCCESS;
    }

    bool VerifyEpicPublisher(const std::wstring& path)
    {
        HCERTSTORE store = nullptr;
        HCRYPTMSG message = nullptr;
        DWORD encoding = 0;
        DWORD contentType = 0;
        DWORD formatType = 0;
        DWORD signerSize = 0;
        bool epic = false;
        if (!VerifyTrustedSignature(path) ||
            !CryptQueryObject(CERT_QUERY_OBJECT_FILE, path.c_str(),
                CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED,
                CERT_QUERY_FORMAT_FLAG_BINARY, 0, &encoding, &contentType, &formatType,
                &store, &message, nullptr))
            return false;
        if (CryptMsgGetParam(message, CMSG_SIGNER_INFO_PARAM, 0, nullptr, &signerSize) && signerSize != 0)
        {
            std::vector<BYTE> signerBuffer(signerSize);
            if (CryptMsgGetParam(message, CMSG_SIGNER_INFO_PARAM, 0, signerBuffer.data(), &signerSize))
            {
                auto signer = reinterpret_cast<CMSG_SIGNER_INFO*>(signerBuffer.data());
                CERT_INFO certificateInfo{};
                certificateInfo.Issuer = signer->Issuer;
                certificateInfo.SerialNumber = signer->SerialNumber;
                PCCERT_CONTEXT certificate = CertFindCertificateInStore(store, encoding, 0,
                    CERT_FIND_SUBJECT_CERT, &certificateInfo, nullptr);
                if (certificate != nullptr)
                {
                    DWORD length = CertGetNameStringW(certificate, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, nullptr, nullptr, 0);
                    if (length > 1)
                    {
                        std::wstring publisher(length, L'\0');
                        CertGetNameStringW(certificate, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, nullptr, publisher.data(), length);
                        publisher.resize(length - 1);
                        epic = ToLower(publisher).find(L"epic games") != std::wstring::npos;
                    }
                    CertFreeCertificateContext(certificate);
                }
            }
        }
        if (message != nullptr)
            CryptMsgClose(message);
        if (store != nullptr)
            CertCloseStore(store, 0);
        return epic;
    }

    bool AddApplicationFilter(WfpContext& context, const std::wstring& path)
    {
        std::wstring normalized = ToLower(path);
        if (context.FilteredPaths.contains(normalized))
            return true;
        FWP_BYTE_BLOB* appId = nullptr;
        DWORD result = FwpmGetAppIdFromFileName0(path.c_str(), &appId);
        if (result != ERROR_SUCCESS)
            return false;

        UINT8 protocol = IPPROTO_UDP;
        UINT32 direction = FWP_DIRECTION_OUTBOUND;
        FWPM_FILTER_CONDITION0 conditions[3]{};
        conditions[0].fieldKey = FWPM_CONDITION_ALE_APP_ID;
        conditions[0].matchType = FWP_MATCH_EQUAL;
        conditions[0].conditionValue.type = FWP_BYTE_BLOB_TYPE;
        conditions[0].conditionValue.byteBlob = appId;
        conditions[1].fieldKey = FWPM_CONDITION_IP_PROTOCOL;
        conditions[1].matchType = FWP_MATCH_EQUAL;
        conditions[1].conditionValue.type = FWP_UINT8;
        conditions[1].conditionValue.uint8 = protocol;
        conditions[2].fieldKey = FWPM_CONDITION_DIRECTION;
        conditions[2].matchType = FWP_MATCH_EQUAL;
        conditions[2].conditionValue.type = FWP_UINT32;
        conditions[2].conditionValue.uint32 = direction;

        FWPM_FILTER0 filter{};
        filter.displayData.name = const_cast<wchar_t*>(L"Qrioso NoPing - Fortnite UDP flow");
        filter.displayData.description = const_cast<wchar_t*>(L"Associates signed Fortnite UDP flows with the Qrioso packet path");
        filter.providerKey = const_cast<GUID*>(&ProviderKey);
        filter.layerKey = FWPM_LAYER_ALE_FLOW_ESTABLISHED_V4;
        filter.subLayerKey = SublayerKey;
        filter.weight.type = FWP_EMPTY;
        filter.numFilterConditions = ARRAYSIZE(conditions);
        filter.filterCondition = conditions;
        filter.action.type = FWP_ACTION_CALLOUT_INSPECTION;
        filter.action.calloutKey = AleCalloutKey;
        result = FwpmFilterAdd0(context.Engine, &filter, nullptr, nullptr);
        FwpmFreeMemory0(reinterpret_cast<void**>(&appId));
        if (result == ERROR_SUCCESS)
            context.FilteredPaths.insert(std::move(normalized));
        return result == ERROR_SUCCESS;
    }

    void DiscoverFortniteProcesses(WfpContext& context)
    {
        HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot == INVALID_HANDLE_VALUE)
            return;
        PROCESSENTRY32W process{};
        process.dwSize = sizeof(process);
        if (Process32FirstW(snapshot, &process))
        {
            do
            {
                std::wstring executable = ToLower(process.szExeFile);
                if (std::find(context.ExecutableNames.begin(), context.ExecutableNames.end(), executable) == context.ExecutableNames.end() ||
                    process.th32ProcessID == context.ProxyProcessId)
                    continue;
                HANDLE processHandle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process.th32ProcessID);
                if (processHandle == nullptr)
                    continue;
                std::wstring path(32768, L'\0');
                DWORD pathLength = static_cast<DWORD>(path.size());
                if (QueryFullProcessImageNameW(processHandle, 0, path.data(), &pathLength))
                {
                    path.resize(pathLength);
                    if (VerifyEpicPublisher(path))
                        AddApplicationFilter(context, path);
                }
                CloseHandle(processHandle);
            } while (Process32NextW(snapshot, &process));
        }
        CloseHandle(snapshot);
    }

    DWORD WINAPI MonitorProcesses(void* parameter)
    {
        auto& context = *static_cast<WfpContext*>(parameter);
        do
        {
            DiscoverFortniteProcesses(context);
        } while (WaitForSingleObject(context.StopEvent, 2000) == WAIT_TIMEOUT);
        return ERROR_SUCCESS;
    }

    DWORD AddBasePolicy(WfpContext& context)
    {
        FWPM_SESSION0 session{};
        FWPM_PROVIDER0 provider{};
        FWPM_SUBLAYER0 sublayer{};
        FWPM_CALLOUT0 callout{};
        UINT8 protocol = IPPROTO_UDP;
        FWPM_FILTER_CONDITION0 condition{};
        FWPM_FILTER0 filter{};
        session.displayData.name = const_cast<wchar_t*>(L"Qrioso NoPing dynamic session");
        session.flags = FWPM_SESSION_FLAG_DYNAMIC;
        session.txnWaitTimeoutInMSec = 5000;
        DWORD result = FwpmEngineOpen0(nullptr, RPC_C_AUTHN_WINNT, nullptr, &session, &context.Engine);
        if (result != ERROR_SUCCESS)
            return result;
        result = FwpmTransactionBegin0(context.Engine, 0);
        if (result != ERROR_SUCCESS)
            return result;

        provider.providerKey = ProviderKey;
        provider.displayData.name = const_cast<wchar_t*>(L"Qrioso NoPing");
        provider.displayData.description = const_cast<wchar_t*>(L"Ephemeral Fortnite multipath filtering policy");
        result = FwpmProviderAdd0(context.Engine, &provider, nullptr);
        if (result != ERROR_SUCCESS)
            goto Abort;

        sublayer.subLayerKey = SublayerKey;
        sublayer.displayData.name = const_cast<wchar_t*>(L"Qrioso NoPing dynamic filters");
        sublayer.providerKey = const_cast<GUID*>(&ProviderKey);
        sublayer.weight = 0xf000;
        result = FwpmSubLayerAdd0(context.Engine, &sublayer, nullptr);
        if (result != ERROR_SUCCESS)
            goto Abort;

        callout.calloutKey = AleCalloutKey;
        callout.displayData.name = const_cast<wchar_t*>(L"Qrioso NoPing flow association");
        callout.providerKey = const_cast<GUID*>(&ProviderKey);
        callout.applicableLayer = FWPM_LAYER_ALE_FLOW_ESTABLISHED_V4;
        result = FwpmCalloutAdd0(context.Engine, &callout, nullptr, nullptr);
        if (result != ERROR_SUCCESS)
            goto Abort;
        callout = {};
        callout.calloutKey = TransportCalloutKey;
        callout.displayData.name = const_cast<wchar_t*>(L"Qrioso NoPing UDP capture");
        callout.providerKey = const_cast<GUID*>(&ProviderKey);
        callout.applicableLayer = FWPM_LAYER_OUTBOUND_TRANSPORT_V4;
        result = FwpmCalloutAdd0(context.Engine, &callout, nullptr, nullptr);
        if (result != ERROR_SUCCESS)
            goto Abort;

        condition.fieldKey = FWPM_CONDITION_IP_PROTOCOL;
        condition.matchType = FWP_MATCH_EQUAL;
        condition.conditionValue.type = FWP_UINT8;
        condition.conditionValue.uint8 = protocol;
        filter.displayData.name = const_cast<wchar_t*>(L"Qrioso NoPing UDP transport callout");
        filter.providerKey = const_cast<GUID*>(&ProviderKey);
        filter.layerKey = FWPM_LAYER_OUTBOUND_TRANSPORT_V4;
        filter.subLayerKey = SublayerKey;
        filter.weight.type = FWP_EMPTY;
        filter.numFilterConditions = 1;
        filter.filterCondition = &condition;
        filter.action.type = FWP_ACTION_CALLOUT_TERMINATING;
        filter.action.calloutKey = TransportCalloutKey;
        result = FwpmFilterAdd0(context.Engine, &filter, nullptr, nullptr);
        if (result != ERROR_SUCCESS)
            goto Abort;

        result = FwpmTransactionCommit0(context.Engine);
        if (result == ERROR_SUCCESS)
            return ERROR_SUCCESS;
        return result;

    Abort:
        FwpmTransactionAbort0(context.Engine);
        return result;
    }

    void CloseContext(WfpContext* context)
    {
        if (context == nullptr)
            return;
        if (context->StopEvent != nullptr)
            SetEvent(context->StopEvent);
        if (context->MonitorThread != nullptr)
        {
            WaitForSingleObject(context->MonitorThread, INFINITE);
            CloseHandle(context->MonitorThread);
        }
        if (context->Engine != nullptr)
            FwpmEngineClose0(context->Engine);
        if (context->Device != INVALID_HANDLE_VALUE)
        {
            DWORD returned = 0;
            DeviceIoControlSync(context->Device, QNP_IOCTL_DEACTIVATE, nullptr, 0, nullptr, 0, &returned);
            CloseHandle(context->Device);
        }
        if (context->StopEvent != nullptr)
            CloseHandle(context->StopEvent);
        delete context;
    }

    bool StartDriverService(DWORD& error)
    {
        SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
        if (manager == nullptr)
        {
            error = GetLastError();
            return false;
        }
        SC_HANDLE service = OpenServiceW(manager, DriverServiceName, SERVICE_START | SERVICE_QUERY_STATUS);
        if (service == nullptr)
        {
            error = GetLastError();
            CloseServiceHandle(manager);
            return false;
        }
        bool success = StartServiceW(service, 0, nullptr) != FALSE || GetLastError() == ERROR_SERVICE_ALREADY_RUNNING;
        if (!success)
            error = GetLastError();
        CloseServiceHandle(service);
        CloseServiceHandle(manager);
        return success;
    }

    void StopDriverService()
    {
        SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
        if (manager == nullptr)
            return;
        SC_HANDLE service = OpenServiceW(manager, DriverServiceName, SERVICE_STOP | SERVICE_QUERY_STATUS);
        if (service != nullptr)
        {
            SERVICE_STATUS status{};
            ControlService(service, SERVICE_CONTROL_STOP, &status);
            for (DWORD attempt = 0; attempt < 40; ++attempt)
            {
                SERVICE_STATUS_PROCESS current{};
                DWORD needed = 0;
                if (!QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO, reinterpret_cast<BYTE*>(&current), sizeof(current), &needed) ||
                    current.dwCurrentState == SERVICE_STOPPED)
                    break;
                Sleep(250);
            }
            CloseServiceHandle(service);
        }
        CloseServiceHandle(manager);
    }

    bool GetDriverInfBesideModule(std::wstring& path)
    {
        HMODULE module = nullptr;
        if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCWSTR>(&GetDriverInfBesideModule), &module))
            return false;
        std::wstring modulePath(32768, L'\0');
        DWORD length = GetModuleFileNameW(module, modulePath.data(), static_cast<DWORD>(modulePath.size()));
        if (length == 0 || length >= modulePath.size())
            return false;
        modulePath.resize(length);
        size_t separator = modulePath.find_last_of(L"\\/");
        if (separator == std::wstring::npos)
            return false;
        path = modulePath.substr(0, separator) + L"\\driver\\QriosoNoPing.Wfp.inf";
        return true;
    }
}

extern "C" bool __cdecl QnpWfpInstall(const wchar_t* driverDirectory, int32_t* errorCode)
{
    if (errorCode != nullptr)
        *errorCode = 0;
    try
    {
        if (driverDirectory == nullptr || *driverDirectory == L'\0')
        {
            SetError(errorCode, ERROR_INVALID_PARAMETER);
            return false;
        }
        std::wstring infPath(32768, L'\0');
        DWORD length = GetFullPathNameW((std::wstring(driverDirectory) + L"\\QriosoNoPing.Wfp.inf").c_str(),
            static_cast<DWORD>(infPath.size()), infPath.data(), nullptr);
        if (length == 0 || length >= infPath.size() || GetFileAttributesW(infPath.c_str()) == INVALID_FILE_ATTRIBUTES)
        {
            SetError(errorCode, length == 0 ? GetLastError() : ERROR_FILE_NOT_FOUND);
            return false;
        }
        infPath.resize(length);
        BOOL rebootRequired = FALSE;
        if (!DiInstallDriverW(nullptr, infPath.c_str(), DIIRFLAG_FORCE_INF, &rebootRequired))
        {
            SetError(errorCode, GetLastError());
            return false;
        }
        DWORD startError = ERROR_SUCCESS;
        if (!StartDriverService(startError))
        {
            BOOL uninstallRebootRequired = FALSE;
            DiUninstallDriverW(nullptr, infPath.c_str(), 0, &uninstallRebootRequired);
            SetError(errorCode, startError);
            return false;
        }
        if (rebootRequired)
        {
            StopDriverService();
            BOOL uninstallRebootRequired = FALSE;
            DiUninstallDriverW(nullptr, infPath.c_str(), 0, &uninstallRebootRequired);
            SetError(errorCode, ERROR_SUCCESS_REBOOT_REQUIRED);
            return false;
        }
        return true;
    }
    catch (...)
    {
        SetError(errorCode, ERROR_OUTOFMEMORY);
        return false;
    }
}

extern "C" bool __cdecl QnpWfpUninstall(int32_t* errorCode)
{
    if (errorCode != nullptr)
        *errorCode = 0;
    try
    {
        std::wstring infPath;
        if (!GetDriverInfBesideModule(infPath) || GetFileAttributesW(infPath.c_str()) == INVALID_FILE_ATTRIBUTES)
        {
            SetError(errorCode, ERROR_FILE_NOT_FOUND);
            return false;
        }
        StopDriverService();
        BOOL rebootRequired = FALSE;
        if (!DiUninstallDriverW(nullptr, infPath.c_str(), 0, &rebootRequired))
        {
            DWORD error = GetLastError();
            if (error != ERROR_NOT_FOUND && error != ERROR_FILE_NOT_FOUND)
            {
                SetError(errorCode, error);
                return false;
            }
        }
        if (rebootRequired)
        {
            SetError(errorCode, ERROR_SUCCESS_REBOOT_REQUIRED);
            return false;
        }
        return true;
    }
    catch (...)
    {
        SetError(errorCode, ERROR_OUTOFMEMORY);
        return false;
    }
}

extern "C" void* __cdecl QnpWfpOpen(const wchar_t* executableNames, uint32_t proxyProcessId, int32_t* errorCode)
{
    if (errorCode != nullptr)
        *errorCode = 0;
    std::unique_ptr<WfpContext> context;
    try
    {
        context = std::make_unique<WfpContext>();
        if (proxyProcessId == 0 || !ParseExecutableNames(executableNames, context->ExecutableNames))
        {
            SetError(errorCode, ERROR_INVALID_PARAMETER);
            return nullptr;
        }
        context->ProxyProcessId = proxyProcessId;
        context->Device = CreateFileW(DevicePath, GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED, nullptr);
        if (context->Device == INVALID_HANDLE_VALUE)
        {
            SetError(errorCode, GetLastError());
            return nullptr;
        }
        QNP_WFP_ACTIVATE_REQUEST request{QNP_WFP_ABI_VERSION, proxyProcessId};
        DWORD returned = 0;
        if (!DeviceIoControlSync(context->Device, QNP_IOCTL_ACTIVATE, &request, sizeof(request), nullptr, 0, &returned))
        {
            SetError(errorCode, GetLastError());
            CloseContext(context.release());
            return nullptr;
        }
        DWORD result = AddBasePolicy(*context);
        if (result != ERROR_SUCCESS)
        {
            SetError(errorCode, result);
            CloseContext(context.release());
            return nullptr;
        }
        context->StopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (context->StopEvent == nullptr)
        {
            SetError(errorCode, GetLastError());
            CloseContext(context.release());
            return nullptr;
        }
        DiscoverFortniteProcesses(*context);
        context->MonitorThread = CreateThread(nullptr, 0, MonitorProcesses, context.get(), 0, nullptr);
        if (context->MonitorThread == nullptr)
        {
            SetError(errorCode, GetLastError());
            CloseContext(context.release());
            return nullptr;
        }
        return context.release();
    }
    catch (...)
    {
        SetError(errorCode, ERROR_OUTOFMEMORY);
        CloseContext(context.release());
        return nullptr;
    }
}

extern "C" int32_t __cdecl QnpWfpRead(void* handle, uint8_t* buffer, int32_t capacity, int32_t* packetLength, int32_t timeoutMs)
{
    if (packetLength != nullptr)
        *packetLength = 0;
    auto context = static_cast<WfpContext*>(handle);
    if (context == nullptr || buffer == nullptr || packetLength == nullptr || capacity < static_cast<int32_t>(QNP_WFP_MAX_PACKET_SIZE) || timeoutMs < 0)
    {
        SetLastError(ERROR_INVALID_PARAMETER);
        return -1;
    }
    HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (event == nullptr)
        return -1;
    OVERLAPPED overlapped{};
    overlapped.hEvent = event;
    DWORD returned = 0;
    BOOL started = DeviceIoControl(context->Device, QNP_IOCTL_READ_PACKET, nullptr, 0, buffer,
        static_cast<DWORD>(capacity), &returned, &overlapped);
    if (!started && GetLastError() != ERROR_IO_PENDING)
    {
        CloseHandle(event);
        return -1;
    }
    if (!started)
    {
        DWORD wait = WaitForSingleObject(event, static_cast<DWORD>(timeoutMs));
        if (wait == WAIT_TIMEOUT)
        {
            CancelIoEx(context->Device, &overlapped);
            GetOverlappedResult(context->Device, &overlapped, &returned, TRUE);
            CloseHandle(event);
            SetLastError(ERROR_TIMEOUT);
            return 0;
        }
        if (wait != WAIT_OBJECT_0 || !GetOverlappedResult(context->Device, &overlapped, &returned, FALSE))
        {
            CloseHandle(event);
            return -1;
        }
    }
    CloseHandle(event);
    if (returned == 0 || returned > static_cast<DWORD>(capacity))
    {
        SetLastError(ERROR_INVALID_DATA);
        return -1;
    }
    *packetLength = static_cast<int32_t>(returned);
    return 1;
}

extern "C" int32_t __cdecl QnpWfpInjectInbound(void* handle, const uint8_t* packet, int32_t packetLength)
{
    auto context = static_cast<WfpContext*>(handle);
    if (context == nullptr || packet == nullptr || packetLength < 28 || packetLength > static_cast<int32_t>(QNP_WFP_MAX_PACKET_SIZE))
    {
        SetLastError(ERROR_INVALID_PARAMETER);
        return 0;
    }
    DWORD returned = 0;
    return DeviceIoControlSync(context->Device, QNP_IOCTL_INJECT_PACKET, const_cast<uint8_t*>(packet),
        static_cast<DWORD>(packetLength), nullptr, 0, &returned) ? 1 : 0;
}

extern "C" void __cdecl QnpWfpClose(void* handle)
{
    CloseContext(static_cast<WfpContext*>(handle));
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved)
{
    UNREFERENCED_PARAMETER(reserved);
    if (reason == DLL_PROCESS_ATTACH)
        DisableThreadLibraryCalls(instance);
    return TRUE;
}
