#define INITGUID
#define POOL_ZERO_DOWN_LEVEL_SUPPORT

#include <ntddk.h>
#include <fwpsk.h>
#include <fwpmk.h>
#include <ndis.h>
#include <wdmsec.h>
#include <ntstrsafe.h>

#include "../../include/qrioso_wfp_ioctl.h"

#define QNP_POOL_TAG 'pNQQ'
#define QNP_MAX_QUEUED_PACKETS 1024u
#define QNP_MAX_FLOWS 4096u
#define QNP_UDP_PROTOCOL 17u

DEFINE_GUID(QNP_WFP_DEVICE_CLASS_GUID,
    0x17c5d199, 0x7358, 0x4496, 0xb7, 0xfc, 0x75, 0x30, 0x82, 0xf0, 0xb4, 0x56);
DEFINE_GUID(QNP_WFP_ALE_CALLOUT_KEY,
    0x876d4075, 0x955f, 0x4932, 0xba, 0xb5, 0xf4, 0x6a, 0x33, 0xb8, 0x58, 0xfc);
DEFINE_GUID(QNP_WFP_TRANSPORT_CALLOUT_KEY,
    0x409bc739, 0xfd2a, 0x42b1, 0x97, 0xca, 0x3e, 0xa4, 0x73, 0x67, 0xff, 0x67);

typedef struct QNP_PACKET_ENTRY_
{
    LIST_ENTRY Link;
    ULONG Length;
    UCHAR Data[QNP_WFP_MAX_PACKET_SIZE];
} QNP_PACKET_ENTRY;

typedef struct QNP_FLOW_CONTEXT_
{
    LIST_ENTRY Link;
    UINT64 FlowHandle;
    UINT32 LocalAddress;
    UINT32 RemoteAddress;
    UINT16 LocalPort;
    UINT16 RemotePort;
    COMPARTMENT_ID CompartmentId;
    IF_INDEX InterfaceIndex;
    IF_INDEX SubInterfaceIndex;
} QNP_FLOW_CONTEXT;

typedef struct QNP_INJECT_CONTEXT_
{
    PMDL Mdl;
    NET_BUFFER_LIST* NetBufferList;
    ULONG Length;
    UCHAR Data[1];
} QNP_INJECT_CONTEXT;

static PDEVICE_OBJECT gDeviceObject;
static UNICODE_STRING gSymbolicLink;
static UINT32 gAleCalloutId;
static UINT32 gTransportCalloutId;
static HANDLE gInjectionHandle;
static NDIS_HANDLE gNdisObject;
static NDIS_HANDLE gNblPool;

static IO_CSQ gReadCsq;
static LIST_ENTRY gPendingReads;
static KSPIN_LOCK gReadLock;

static LIST_ENTRY gPacketQueue;
static ULONG gPacketCount;
static KSPIN_LOCK gPacketLock;
static volatile LONG gPumping;

static LIST_ENTRY gFlowList;
static ULONG gFlowCount;
static KSPIN_LOCK gFlowLock;
static KEVENT gFlowChanged;

static PFILE_OBJECT gActiveFile;
static ULONG gProxyProcessId;
static KSPIN_LOCK gStateLock;
static volatile LONG gUnloading;
static volatile LONG gOutstandingInjections;
static KEVENT gInjectionsDrained;

DRIVER_INITIALIZE DriverEntry;

static VOID QnpCompleteIrp(_Inout_ PIRP Irp, _In_ NTSTATUS Status, _In_ ULONG_PTR Information)
{
    Irp->IoStatus.Status = Status;
    Irp->IoStatus.Information = Information;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
}

static VOID QnpCsqInsertIrp(_In_ PIO_CSQ Csq, _Inout_ PIRP Irp)
{
    UNREFERENCED_PARAMETER(Csq);
    InsertTailList(&gPendingReads, &Irp->Tail.Overlay.ListEntry);
}

static VOID QnpCsqRemoveIrp(_In_ PIO_CSQ Csq, _Inout_ PIRP Irp)
{
    UNREFERENCED_PARAMETER(Csq);
    RemoveEntryList(&Irp->Tail.Overlay.ListEntry);
}

static PIRP QnpCsqPeekNextIrp(_In_ PIO_CSQ Csq, _In_opt_ PIRP Irp, _In_opt_ PVOID PeekContext)
{
    PLIST_ENTRY entry;
    UNREFERENCED_PARAMETER(Csq);
    UNREFERENCED_PARAMETER(PeekContext);
    entry = Irp == NULL ? gPendingReads.Flink : Irp->Tail.Overlay.ListEntry.Flink;
    return entry == &gPendingReads ? NULL : CONTAINING_RECORD(entry, IRP, Tail.Overlay.ListEntry);
}

static VOID QnpCsqAcquireLock(_In_ PIO_CSQ Csq, _Out_ PKIRQL Irql)
{
    UNREFERENCED_PARAMETER(Csq);
    KeAcquireSpinLock(&gReadLock, Irql);
}

static VOID QnpCsqReleaseLock(_In_ PIO_CSQ Csq, _In_ KIRQL Irql)
{
    UNREFERENCED_PARAMETER(Csq);
    KeReleaseSpinLock(&gReadLock, Irql);
}

static VOID QnpCsqCompleteCanceledIrp(_In_ PIO_CSQ Csq, _Inout_ PIRP Irp)
{
    UNREFERENCED_PARAMETER(Csq);
    QnpCompleteIrp(Irp, STATUS_CANCELLED, 0);
}

static BOOLEAN QnpIsActive(VOID)
{
    KIRQL irql;
    BOOLEAN active;
    KeAcquireSpinLock(&gStateLock, &irql);
    active = gActiveFile != NULL && InterlockedCompareExchange(&gUnloading, 0, 0) == 0;
    KeReleaseSpinLock(&gStateLock, irql);
    return active;
}

static BOOLEAN QnpFileOwnsSession(_In_ PFILE_OBJECT FileObject)
{
    KIRQL irql;
    BOOLEAN ownsSession;
    KeAcquireSpinLock(&gStateLock, &irql);
    ownsSession = gActiveFile == FileObject && InterlockedCompareExchange(&gUnloading, 0, 0) == 0;
    KeReleaseSpinLock(&gStateLock, irql);
    return ownsSession;
}

static VOID QnpFlushPackets(VOID)
{
    LIST_ENTRY released;
    KIRQL irql;
    InitializeListHead(&released);
    KeAcquireSpinLock(&gPacketLock, &irql);
    while (!IsListEmpty(&gPacketQueue))
    {
        PLIST_ENTRY entry = RemoveHeadList(&gPacketQueue);
        InsertTailList(&released, entry);
    }
    gPacketCount = 0;
    KeReleaseSpinLock(&gPacketLock, irql);
    while (!IsListEmpty(&released))
    {
        QNP_PACKET_ENTRY* packet = CONTAINING_RECORD(RemoveHeadList(&released), QNP_PACKET_ENTRY, Link);
        ExFreePoolWithTag(packet, QNP_POOL_TAG);
    }
}

static VOID QnpCancelPendingReads(VOID)
{
    PIRP irp;
    while ((irp = IoCsqRemoveNextIrp(&gReadCsq, NULL)) != NULL)
        QnpCompleteIrp(irp, STATUS_CANCELLED, 0);
}

static VOID QnpPumpReads(VOID)
{
    if (InterlockedCompareExchange(&gPumping, 1, 0) != 0)
        return;

    for (;;)
    {
        PIRP irp;
        QNP_PACKET_ENTRY* packet = NULL;
        PIO_STACK_LOCATION stack;
        PVOID output;
        KIRQL irql;

        irp = IoCsqRemoveNextIrp(&gReadCsq, NULL);
        if (irp == NULL)
            break;
        stack = IoGetCurrentIrpStackLocation(irp);

        KeAcquireSpinLock(&gPacketLock, &irql);
        if (!IsListEmpty(&gPacketQueue))
        {
            packet = CONTAINING_RECORD(RemoveHeadList(&gPacketQueue), QNP_PACKET_ENTRY, Link);
            --gPacketCount;
        }
        else
        {
            packet = NULL;
        }
        KeReleaseSpinLock(&gPacketLock, irql);
        if (packet == NULL)
        {
            IoCsqInsertIrp(&gReadCsq, irp, NULL);
            if (!QnpFileOwnsSession(stack->FileObject))
            {
                PIRP removed = IoCsqRemoveIrp(&gReadCsq, irp);
                if (removed != NULL)
                    QnpCompleteIrp(removed, STATUS_CANCELLED, 0);
            }
            break;
        }

        if (stack->Parameters.DeviceIoControl.OutputBufferLength < packet->Length || irp->MdlAddress == NULL)
        {
            QnpCompleteIrp(irp, STATUS_BUFFER_TOO_SMALL, 0);
            ExFreePoolWithTag(packet, QNP_POOL_TAG);
            continue;
        }

        output = MmGetSystemAddressForMdlSafe(irp->MdlAddress, NormalPagePriority | MdlMappingNoExecute);
        if (output == NULL)
            QnpCompleteIrp(irp, STATUS_INSUFFICIENT_RESOURCES, 0);
        else
        {
            RtlCopyMemory(output, packet->Data, packet->Length);
            QnpCompleteIrp(irp, STATUS_SUCCESS, packet->Length);
        }
        ExFreePoolWithTag(packet, QNP_POOL_TAG);
    }

    InterlockedExchange(&gPumping, 0);
    KeMemoryBarrier();
    {
        BOOLEAN hasPackets;
        BOOLEAN hasReads;
        KIRQL irql;
        KeAcquireSpinLock(&gPacketLock, &irql);
        hasPackets = !IsListEmpty(&gPacketQueue);
        KeReleaseSpinLock(&gPacketLock, irql);
        KeAcquireSpinLock(&gReadLock, &irql);
        hasReads = !IsListEmpty(&gPendingReads);
        KeReleaseSpinLock(&gReadLock, irql);
        if (hasPackets && hasReads)
            QnpPumpReads();
    }
}

static BOOLEAN QnpQueuePacket(_In_reads_bytes_(Length) const UCHAR* Data, _In_ ULONG Length)
{
    QNP_PACKET_ENTRY* packet;
    KIRQL stateIrql;
    BOOLEAN accepted = FALSE;

    if (!QnpIsActive() || Length == 0 || Length > QNP_WFP_MAX_PACKET_SIZE)
        return FALSE;
    packet = ExAllocatePool2(POOL_FLAG_NON_PAGED, sizeof(*packet), QNP_POOL_TAG);
    if (packet == NULL)
        return FALSE;
    packet->Length = Length;
    RtlCopyMemory(packet->Data, Data, Length);

    KeAcquireSpinLock(&gStateLock, &stateIrql);
    if (gActiveFile != NULL && InterlockedCompareExchange(&gUnloading, 0, 0) == 0)
    {
        KeAcquireSpinLockAtDpcLevel(&gPacketLock);
        if (gPacketCount < QNP_MAX_QUEUED_PACKETS)
        {
            InsertTailList(&gPacketQueue, &packet->Link);
            ++gPacketCount;
            accepted = TRUE;
        }
        KeReleaseSpinLockFromDpcLevel(&gPacketLock);
    }
    KeReleaseSpinLock(&gStateLock, stateIrql);
    if (!accepted)
        ExFreePoolWithTag(packet, QNP_POOL_TAG);
    else
        QnpPumpReads();
    return accepted;
}

static UINT16 QnpReadNetworkU16(_In_reads_(2) const UCHAR* Value)
{
    return (UINT16)(((UINT16)Value[0] << 8) | Value[1]);
}

static VOID QnpWriteNetworkU16(_Out_writes_(2) UCHAR* Value, _In_ UINT16 Number)
{
    Value[0] = (UCHAR)(Number >> 8);
    Value[1] = (UCHAR)(Number & 0xff);
}

static UINT32 QnpReadNetworkU32(_In_reads_(4) const UCHAR* Value)
{
    return ((UINT32)Value[0] << 24) | ((UINT32)Value[1] << 16) | ((UINT32)Value[2] << 8) | Value[3];
}

static VOID QnpWriteNetworkU32(_Out_writes_(4) UCHAR* Value, _In_ UINT32 Number)
{
    Value[0] = (UCHAR)(Number >> 24);
    Value[1] = (UCHAR)(Number >> 16);
    Value[2] = (UCHAR)(Number >> 8);
    Value[3] = (UCHAR)Number;
}

static ULONG QnpChecksumAdd(_In_reads_bytes_(Length) const UCHAR* Data, _In_ ULONG Length, _In_ ULONG Sum)
{
    ULONG index;
    for (index = 0; index + 1 < Length; index += 2)
        Sum += ((ULONG)Data[index] << 8) | Data[index + 1];
    if ((Length & 1u) != 0)
        Sum += (ULONG)Data[Length - 1] << 8;
    return Sum;
}

static UINT16 QnpChecksumFinish(_In_ ULONG Sum)
{
    while ((Sum >> 16) != 0)
        Sum = (Sum & 0xffffu) + (Sum >> 16);
    return (UINT16)~Sum;
}

static VOID QnpCalculateChecksums(_Inout_updates_bytes_(Length) UCHAR* Packet, _In_ ULONG Length)
{
    ULONG sum;
    UINT16 udpLength = (UINT16)(Length - 20u);
    Packet[10] = Packet[11] = 0;
    QnpWriteNetworkU16(Packet + 10, QnpChecksumFinish(QnpChecksumAdd(Packet, 20, 0)));

    Packet[26] = Packet[27] = 0;
    sum = QnpChecksumAdd(Packet + 12, 8, 0);
    sum += QNP_UDP_PROTOCOL;
    sum += udpLength;
    sum = QnpChecksumAdd(Packet + 20, udpLength, sum);
    {
        UINT16 checksum = QnpChecksumFinish(sum);
        QnpWriteNetworkU16(Packet + 26, checksum == 0 ? 0xffffu : checksum);
    }
}

static BOOLEAN QnpIsPublicIpv4(_In_ UINT32 Address)
{
    UCHAR a = (UCHAR)(Address >> 24);
    UCHAR b = (UCHAR)(Address >> 16);
    UCHAR c = (UCHAR)(Address >> 8);
    if (a == 0 || a == 10 || a == 127 || a >= 224)
        return FALSE;
    if (a == 100 && b >= 64 && b <= 127)
        return FALSE;
    if (a == 169 && b == 254)
        return FALSE;
    if (a == 172 && b >= 16 && b <= 31)
        return FALSE;
    if (a == 192 && (b == 168 || (b == 0 && (c == 0 || c == 2)) || (b == 88 && c == 99)))
        return FALSE;
    if (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)))
        return FALSE;
    if (a == 203 && b == 0 && c == 113)
        return FALSE;
    return TRUE;
}

static VOID NTAPI QnpAleClassify(
    _In_ const FWPS_INCOMING_VALUES0* InFixedValues,
    _In_ const FWPS_INCOMING_METADATA_VALUES0* InMetaValues,
    _Inout_opt_ VOID* LayerData,
    _In_opt_ const VOID* ClassifyContext,
    _In_ const FWPS_FILTER0* Filter,
    _In_ UINT64 FlowContext,
    _Inout_ FWPS_CLASSIFY_OUT0* ClassifyOut)
{
    QNP_FLOW_CONTEXT* flow;
    NTSTATUS status;
    KIRQL irql;
    UINT32 remoteAddress;
    ULONG proxyProcessId;

    UNREFERENCED_PARAMETER(LayerData);
    UNREFERENCED_PARAMETER(ClassifyContext);
    UNREFERENCED_PARAMETER(Filter);
    UNREFERENCED_PARAMETER(FlowContext);
    if ((ClassifyOut->rights & FWPS_RIGHT_ACTION_WRITE) == 0)
        return;
    ClassifyOut->actionType = FWP_ACTION_CONTINUE;
    if (!QnpIsActive() ||
        InFixedValues->incomingValue[FWPS_FIELD_ALE_FLOW_ESTABLISHED_V4_IP_PROTOCOL].value.uint8 != QNP_UDP_PROTOCOL ||
        InFixedValues->incomingValue[FWPS_FIELD_ALE_FLOW_ESTABLISHED_V4_DIRECTION].value.uint32 != FWP_DIRECTION_OUTBOUND ||
        !FWPS_IS_METADATA_FIELD_PRESENT(InMetaValues, FWPS_METADATA_FIELD_FLOW_HANDLE))
        return;

    remoteAddress = InFixedValues->incomingValue[FWPS_FIELD_ALE_FLOW_ESTABLISHED_V4_IP_REMOTE_ADDRESS].value.uint32;
    if (!QnpIsPublicIpv4(remoteAddress))
        return;
    KeAcquireSpinLock(&gStateLock, &irql);
    proxyProcessId = gProxyProcessId;
    KeReleaseSpinLock(&gStateLock, irql);
    if (FWPS_IS_METADATA_FIELD_PRESENT(InMetaValues, FWPS_METADATA_FIELD_PROCESS_ID) &&
        (ULONG)(ULONG_PTR)InMetaValues->processId == proxyProcessId)
        return;

    flow = ExAllocatePool2(POOL_FLAG_NON_PAGED, sizeof(*flow), QNP_POOL_TAG);
    if (flow == NULL)
        return;
    RtlZeroMemory(flow, sizeof(*flow));
    flow->FlowHandle = InMetaValues->flowHandle;
    flow->LocalAddress = InFixedValues->incomingValue[FWPS_FIELD_ALE_FLOW_ESTABLISHED_V4_IP_LOCAL_ADDRESS].value.uint32;
    flow->RemoteAddress = remoteAddress;
    flow->LocalPort = InFixedValues->incomingValue[FWPS_FIELD_ALE_FLOW_ESTABLISHED_V4_IP_LOCAL_PORT].value.uint16;
    flow->RemotePort = InFixedValues->incomingValue[FWPS_FIELD_ALE_FLOW_ESTABLISHED_V4_IP_REMOTE_PORT].value.uint16;
    if (FWPS_IS_METADATA_FIELD_PRESENT(InMetaValues, FWPS_METADATA_FIELD_COMPARTMENT_ID))
        flow->CompartmentId = InMetaValues->compartmentId;

    KeAcquireSpinLock(&gFlowLock, &irql);
    if (gFlowCount >= QNP_MAX_FLOWS || InterlockedCompareExchange(&gUnloading, 0, 0) != 0)
    {
        KeReleaseSpinLock(&gFlowLock, irql);
        ExFreePoolWithTag(flow, QNP_POOL_TAG);
        return;
    }
    InsertTailList(&gFlowList, &flow->Link);
    ++gFlowCount;
    KeReleaseSpinLock(&gFlowLock, irql);
    status = FwpsFlowAssociateContext0(flow->FlowHandle, FWPS_LAYER_OUTBOUND_TRANSPORT_V4, gTransportCalloutId, (UINT64)flow);
    if (!NT_SUCCESS(status))
    {
        KeAcquireSpinLock(&gFlowLock, &irql);
        RemoveEntryList(&flow->Link);
        --gFlowCount;
        KeReleaseSpinLock(&gFlowLock, irql);
    }
    if (!NT_SUCCESS(status))
        ExFreePoolWithTag(flow, QNP_POOL_TAG);
}

static VOID NTAPI QnpTransportClassify(
    _In_ const FWPS_INCOMING_VALUES0* InFixedValues,
    _In_ const FWPS_INCOMING_METADATA_VALUES0* InMetaValues,
    _Inout_opt_ VOID* LayerData,
    _In_opt_ const VOID* ClassifyContext,
    _In_ const FWPS_FILTER0* Filter,
    _In_ UINT64 FlowContext,
    _Inout_ FWPS_CLASSIFY_OUT0* ClassifyOut)
{
    QNP_FLOW_CONTEXT* flow = (QNP_FLOW_CONTEXT*)(ULONG_PTR)FlowContext;
    NET_BUFFER_LIST* nbl = (NET_BUFFER_LIST*)LayerData;
    NET_BUFFER* netBuffer;
    QNP_PACKET_ENTRY* scratch;
    ULONG transportLength;
    PUCHAR transport;
    KIRQL irql;

    UNREFERENCED_PARAMETER(ClassifyContext);
    UNREFERENCED_PARAMETER(Filter);
    if ((ClassifyOut->rights & FWPS_RIGHT_ACTION_WRITE) == 0)
        return;
    // This callout is attached to the UDP transport layer so that associated
    // Fortnite flows carry their context here. Unassociated UDP must continue
    // through the rest of the Windows filtering policy; returning PERMIT would
    // risk overriding a later firewall decision.
    ClassifyOut->actionType = FWP_ACTION_CONTINUE;
    if (flow == NULL || nbl == NULL || !QnpIsActive() ||
        InFixedValues->incomingValue[FWPS_FIELD_OUTBOUND_TRANSPORT_V4_IP_PROTOCOL].value.uint8 != QNP_UDP_PROTOCOL)
        return;
    if (FwpsQueryPacketInjectionState0(gInjectionHandle, nbl, NULL) != FWPS_PACKET_NOT_INJECTED)
        return;

    netBuffer = NET_BUFFER_LIST_FIRST_NB(nbl);
    if (netBuffer == NULL || NET_BUFFER_NEXT_NB(netBuffer) != NULL || NET_BUFFER_LIST_NEXT_NBL(nbl) != NULL)
        return;
    transportLength = NET_BUFFER_DATA_LENGTH(netBuffer);
    if (transportLength < 8 || transportLength + 20 > QNP_WFP_MAX_PACKET_SIZE)
        return;

    scratch = ExAllocatePool2(POOL_FLAG_NON_PAGED, sizeof(*scratch), QNP_POOL_TAG);
    if (scratch == NULL)
        return;
    transport = NdisGetDataBuffer(netBuffer, transportLength, scratch->Data + 20, 1, 0);
    if (transport == NULL)
    {
        ExFreePoolWithTag(scratch, QNP_POOL_TAG);
        return;
    }
    if (transport != scratch->Data + 20)
        RtlCopyMemory(scratch->Data + 20, transport, transportLength);
    if (QnpReadNetworkU16(scratch->Data + 24) != transportLength)
    {
        ExFreePoolWithTag(scratch, QNP_POOL_TAG);
        return;
    }

    RtlZeroMemory(scratch->Data, 20);
    scratch->Data[0] = 0x45;
    QnpWriteNetworkU16(scratch->Data + 2, (UINT16)(transportLength + 20));
    QnpWriteNetworkU16(scratch->Data + 6, 0x4000);
    scratch->Data[8] = 64;
    scratch->Data[9] = QNP_UDP_PROTOCOL;
    QnpWriteNetworkU32(scratch->Data + 12, flow->LocalAddress);
    QnpWriteNetworkU32(scratch->Data + 16, flow->RemoteAddress);
    QnpCalculateChecksums(scratch->Data, transportLength + 20);

    KeAcquireSpinLock(&gFlowLock, &irql);
    flow->CompartmentId = FWPS_IS_METADATA_FIELD_PRESENT(InMetaValues, FWPS_METADATA_FIELD_COMPARTMENT_ID)
        ? InMetaValues->compartmentId
        : flow->CompartmentId;
    flow->InterfaceIndex = InFixedValues->incomingValue[FWPS_FIELD_OUTBOUND_TRANSPORT_V4_INTERFACE_INDEX].value.uint32;
    flow->SubInterfaceIndex = InFixedValues->incomingValue[FWPS_FIELD_OUTBOUND_TRANSPORT_V4_SUB_INTERFACE_INDEX].value.uint32;
    KeReleaseSpinLock(&gFlowLock, irql);

    if (QnpQueuePacket(scratch->Data, transportLength + 20))
    {
        ClassifyOut->actionType = FWP_ACTION_BLOCK;
        ClassifyOut->flags |= FWPS_CLASSIFY_OUT_FLAG_ABSORB;
        ClassifyOut->rights &= ~FWPS_RIGHT_ACTION_WRITE;
    }
    ExFreePoolWithTag(scratch, QNP_POOL_TAG);
}

static NTSTATUS NTAPI QnpNotify(
    _In_ FWPS_CALLOUT_NOTIFY_TYPE NotifyType,
    _In_ const GUID* FilterKey,
    _Inout_ FWPS_FILTER0* Filter)
{
    UNREFERENCED_PARAMETER(NotifyType);
    UNREFERENCED_PARAMETER(FilterKey);
    UNREFERENCED_PARAMETER(Filter);
    return STATUS_SUCCESS;
}

static VOID NTAPI QnpFlowDelete(_In_ UINT16 LayerId, _In_ UINT32 CalloutId, _In_ UINT64 FlowContext)
{
    QNP_FLOW_CONTEXT* flow = (QNP_FLOW_CONTEXT*)(ULONG_PTR)FlowContext;
    KIRQL irql;
    UNREFERENCED_PARAMETER(LayerId);
    UNREFERENCED_PARAMETER(CalloutId);
    if (flow == NULL)
        return;
    KeAcquireSpinLock(&gFlowLock, &irql);
    RemoveEntryList(&flow->Link);
    if (gFlowCount != 0)
        --gFlowCount;
    KeReleaseSpinLock(&gFlowLock, irql);
    ExFreePoolWithTag(flow, QNP_POOL_TAG);
    KeSetEvent(&gFlowChanged, IO_NO_INCREMENT, FALSE);
}

static VOID QnpRemoveAllFlowContexts(VOID)
{
    for (;;)
    {
        QNP_FLOW_CONTEXT* flow;
        UINT64 flowHandle;
        NTSTATUS status;
        KIRQL irql;

        KeClearEvent(&gFlowChanged);
        KeAcquireSpinLock(&gFlowLock, &irql);
        if (IsListEmpty(&gFlowList))
        {
            KeReleaseSpinLock(&gFlowLock, irql);
            return;
        }
        flow = CONTAINING_RECORD(gFlowList.Flink, QNP_FLOW_CONTEXT, Link);
        flowHandle = flow->FlowHandle;
        KeReleaseSpinLock(&gFlowLock, irql);

        status = FwpsFlowRemoveContext0(flowHandle, FWPS_LAYER_OUTBOUND_TRANSPORT_V4, gTransportCalloutId);
        if (status != STATUS_SUCCESS)
        {
            NT_ASSERT(status == STATUS_PENDING || status == STATUS_UNSUCCESSFUL);
            KeWaitForSingleObject(&gFlowChanged, Executive, KernelMode, FALSE, NULL);
        }
    }
}

static VOID QnpUnregisterCallout(_In_ UINT32 CalloutId)
{
    LARGE_INTEGER retryInterval;
    NTSTATUS status;
    retryInterval.QuadPart = -100LL * 10LL * 1000LL;
    for (;;)
    {
        status = FwpsCalloutUnregisterById0(CalloutId);
        if (NT_SUCCESS(status))
            return;
        NT_ASSERT(status == STATUS_DEVICE_BUSY || status == STATUS_FWP_IN_USE);
        KeDelayExecutionThread(KernelMode, FALSE, &retryInterval);
    }
}

static VOID NTAPI QnpInjectComplete(_Inout_ VOID* Context, _Inout_ NET_BUFFER_LIST* NetBufferList, _In_ BOOLEAN DispatchLevel)
{
    QNP_INJECT_CONTEXT* injection = (QNP_INJECT_CONTEXT*)Context;
    UNREFERENCED_PARAMETER(NetBufferList);
    UNREFERENCED_PARAMETER(DispatchLevel);
    FwpsFreeNetBufferList0(injection->NetBufferList);
    IoFreeMdl(injection->Mdl);
    ExFreePoolWithTag(injection, QNP_POOL_TAG);
    if (InterlockedDecrement(&gOutstandingInjections) == 0)
        KeSetEvent(&gInjectionsDrained, IO_NO_INCREMENT, FALSE);
}

static NTSTATUS QnpInjectInbound(_In_reads_bytes_(Length) const UCHAR* Packet, _In_ ULONG Length)
{
    QNP_INJECT_CONTEXT* injection;
    QNP_FLOW_CONTEXT* flow;
    COMPARTMENT_ID compartmentId = UNSPECIFIED_COMPARTMENT_ID;
    IF_INDEX interfaceIndex = 0;
    IF_INDEX subInterfaceIndex = 0;
    UINT32 sourceAddress;
    UINT32 destinationAddress;
    UINT16 sourcePort;
    UINT16 destinationPort;
    KIRQL irql;
    NTSTATUS status;

    if (Length < 28 || Length > QNP_WFP_MAX_PACKET_SIZE || Packet[0] != 0x45 || Packet[9] != QNP_UDP_PROTOCOL ||
        QnpReadNetworkU16(Packet + 2) != Length || (QnpReadNetworkU16(Packet + 6) & 0x3fffu) != 0 ||
        QnpReadNetworkU16(Packet + 24) != Length - 20)
        return STATUS_INVALID_PARAMETER;
    sourceAddress = QnpReadNetworkU32(Packet + 12);
    destinationAddress = QnpReadNetworkU32(Packet + 16);
    sourcePort = QnpReadNetworkU16(Packet + 20);
    destinationPort = QnpReadNetworkU16(Packet + 22);

    KeAcquireSpinLock(&gFlowLock, &irql);
    for (flow = IsListEmpty(&gFlowList) ? NULL : CONTAINING_RECORD(gFlowList.Flink, QNP_FLOW_CONTEXT, Link);
         flow != NULL && &flow->Link != &gFlowList;
         flow = flow->Link.Flink == &gFlowList ? NULL : CONTAINING_RECORD(flow->Link.Flink, QNP_FLOW_CONTEXT, Link))
    {
        if (flow->RemoteAddress == sourceAddress && flow->LocalAddress == destinationAddress &&
            flow->RemotePort == sourcePort && flow->LocalPort == destinationPort && flow->InterfaceIndex != 0)
        {
            compartmentId = flow->CompartmentId;
            interfaceIndex = flow->InterfaceIndex;
            subInterfaceIndex = flow->SubInterfaceIndex;
            break;
        }
    }
    KeReleaseSpinLock(&gFlowLock, irql);
    if (interfaceIndex == 0)
        return STATUS_NOT_FOUND;

    injection = ExAllocatePool2(POOL_FLAG_NON_PAGED, FIELD_OFFSET(QNP_INJECT_CONTEXT, Data) + Length, QNP_POOL_TAG);
    if (injection == NULL)
        return STATUS_INSUFFICIENT_RESOURCES;
    RtlZeroMemory(injection, FIELD_OFFSET(QNP_INJECT_CONTEXT, Data));
    injection->Length = Length;
    RtlCopyMemory(injection->Data, Packet, Length);
    injection->Mdl = IoAllocateMdl(injection->Data, Length, FALSE, FALSE, NULL);
    if (injection->Mdl == NULL)
    {
        ExFreePoolWithTag(injection, QNP_POOL_TAG);
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    MmBuildMdlForNonPagedPool(injection->Mdl);
    status = FwpsAllocateNetBufferAndNetBufferList0(gNblPool, 0, 0, injection->Mdl, 0, Length, &injection->NetBufferList);
    if (!NT_SUCCESS(status))
    {
        IoFreeMdl(injection->Mdl);
        ExFreePoolWithTag(injection, QNP_POOL_TAG);
        return status;
    }

    if (InterlockedIncrement(&gOutstandingInjections) == 1)
        KeClearEvent(&gInjectionsDrained);
    status = FwpsInjectNetworkReceiveAsync0(gInjectionHandle, NULL, 0, compartmentId, interfaceIndex, subInterfaceIndex,
        injection->NetBufferList, QnpInjectComplete, injection);
    if (!NT_SUCCESS(status))
    {
        FwpsFreeNetBufferList0(injection->NetBufferList);
        IoFreeMdl(injection->Mdl);
        ExFreePoolWithTag(injection, QNP_POOL_TAG);
        if (InterlockedDecrement(&gOutstandingInjections) == 0)
            KeSetEvent(&gInjectionsDrained, IO_NO_INCREMENT, FALSE);
    }
    return status;
}

static NTSTATUS QnpDispatchCreateClose(_In_ PDEVICE_OBJECT DeviceObject, _Inout_ PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    QnpCompleteIrp(Irp, STATUS_SUCCESS, 0);
    return STATUS_SUCCESS;
}

static NTSTATUS QnpDispatchUnsupported(_In_ PDEVICE_OBJECT DeviceObject, _Inout_ PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    QnpCompleteIrp(Irp, STATUS_INVALID_DEVICE_REQUEST, 0);
    return STATUS_INVALID_DEVICE_REQUEST;
}

static VOID QnpDeactivate(_In_opt_ PFILE_OBJECT FileObject)
{
    KIRQL irql;
    BOOLEAN deactivate = FALSE;
    KeAcquireSpinLock(&gStateLock, &irql);
    if (gActiveFile != NULL && (FileObject == NULL || gActiveFile == FileObject))
    {
        gActiveFile = NULL;
        gProxyProcessId = 0;
        deactivate = TRUE;
    }
    KeReleaseSpinLock(&gStateLock, irql);
    if (deactivate)
    {
        QnpCancelPendingReads();
        QnpFlushPackets();
    }
}

static NTSTATUS QnpDispatchCleanup(_In_ PDEVICE_OBJECT DeviceObject, _Inout_ PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    QnpDeactivate(IoGetCurrentIrpStackLocation(Irp)->FileObject);
    QnpCompleteIrp(Irp, STATUS_SUCCESS, 0);
    return STATUS_SUCCESS;
}

static NTSTATUS QnpDispatchDeviceControl(_In_ PDEVICE_OBJECT DeviceObject, _Inout_ PIRP Irp)
{
    PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(Irp);
    ULONG code = stack->Parameters.DeviceIoControl.IoControlCode;
    NTSTATUS status = STATUS_INVALID_DEVICE_REQUEST;
    KIRQL irql;
    UNREFERENCED_PARAMETER(DeviceObject);

    if (code == QNP_IOCTL_ACTIVATE)
    {
        QNP_WFP_ACTIVATE_REQUEST* request;
        if (stack->Parameters.DeviceIoControl.InputBufferLength != sizeof(*request))
            status = STATUS_INFO_LENGTH_MISMATCH;
        else
        {
            request = (QNP_WFP_ACTIVATE_REQUEST*)Irp->AssociatedIrp.SystemBuffer;
            if (request->AbiVersion != QNP_WFP_ABI_VERSION || request->ProxyProcessId == 0)
                status = STATUS_REVISION_MISMATCH;
            else
            {
                KeAcquireSpinLock(&gStateLock, &irql);
                if (gActiveFile != NULL && gActiveFile != stack->FileObject)
                    status = STATUS_DEVICE_BUSY;
                else
                {
                    gActiveFile = stack->FileObject;
                    gProxyProcessId = request->ProxyProcessId;
                    status = STATUS_SUCCESS;
                }
                KeReleaseSpinLock(&gStateLock, irql);
            }
        }
    }
    else if (code == QNP_IOCTL_DEACTIVATE)
    {
        QnpDeactivate(stack->FileObject);
        status = STATUS_SUCCESS;
    }
    else if (code == QNP_IOCTL_READ_PACKET)
    {
        BOOLEAN ownsSession;
        KeAcquireSpinLock(&gStateLock, &irql);
        ownsSession = gActiveFile == stack->FileObject;
        KeReleaseSpinLock(&gStateLock, irql);
        if (!ownsSession)
            status = STATUS_ACCESS_DENIED;
        else if (stack->Parameters.DeviceIoControl.OutputBufferLength < QNP_WFP_MAX_PACKET_SIZE || Irp->MdlAddress == NULL)
            status = STATUS_BUFFER_TOO_SMALL;
        else
        {
            IoMarkIrpPending(Irp);
            IoCsqInsertIrp(&gReadCsq, Irp, NULL);
            if (!QnpFileOwnsSession(stack->FileObject))
            {
                PIRP removed = IoCsqRemoveIrp(&gReadCsq, Irp);
                if (removed != NULL)
                    QnpCompleteIrp(removed, STATUS_CANCELLED, 0);
                return STATUS_PENDING;
            }
            QnpPumpReads();
            return STATUS_PENDING;
        }
    }
    else if (code == QNP_IOCTL_INJECT_PACKET)
    {
        BOOLEAN ownsSession;
        KeAcquireSpinLock(&gStateLock, &irql);
        ownsSession = gActiveFile == stack->FileObject;
        KeReleaseSpinLock(&gStateLock, irql);
        if (!ownsSession)
            status = STATUS_ACCESS_DENIED;
        else
            status = QnpInjectInbound((const UCHAR*)Irp->AssociatedIrp.SystemBuffer,
                stack->Parameters.DeviceIoControl.InputBufferLength);
    }

    QnpCompleteIrp(Irp, status, 0);
    return status;
}

static VOID QnpDriverUnload(_In_ PDRIVER_OBJECT DriverObject)
{
    UNREFERENCED_PARAMETER(DriverObject);
    InterlockedExchange(&gUnloading, 1);
    QnpDeactivate(NULL);
    if (gAleCalloutId != 0)
    {
        QnpUnregisterCallout(gAleCalloutId);
        gAleCalloutId = 0;
    }
    QnpRemoveAllFlowContexts();
    if (gTransportCalloutId != 0)
    {
        QnpUnregisterCallout(gTransportCalloutId);
        gTransportCalloutId = 0;
    }
    if (InterlockedCompareExchange(&gOutstandingInjections, 0, 0) != 0)
        KeWaitForSingleObject(&gInjectionsDrained, Executive, KernelMode, FALSE, NULL);
    if (gInjectionHandle != NULL)
        FwpsInjectionHandleDestroy0(gInjectionHandle);
    if (gNblPool != NULL)
        NdisFreeNetBufferListPool(gNblPool);
    if (gNdisObject != NULL)
        NdisFreeGenericObject(gNdisObject);
    IoDeleteSymbolicLink(&gSymbolicLink);
    if (gDeviceObject != NULL)
        IoDeleteDevice(gDeviceObject);
}

NTSTATUS DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    UNICODE_STRING deviceName;
    FWPS_CALLOUT0 callout;
    NET_BUFFER_LIST_POOL_PARAMETERS poolParameters;
    NTSTATUS status;
    ULONG index;
    UNREFERENCED_PARAMETER(RegistryPath);

    ExInitializeDriverRuntime(DrvRtPoolNxOptIn);
    InitializeListHead(&gPendingReads);
    InitializeListHead(&gPacketQueue);
    InitializeListHead(&gFlowList);
    KeInitializeSpinLock(&gReadLock);
    KeInitializeSpinLock(&gPacketLock);
    KeInitializeSpinLock(&gFlowLock);
    KeInitializeSpinLock(&gStateLock);
    KeInitializeEvent(&gFlowChanged, NotificationEvent, FALSE);
    KeInitializeEvent(&gInjectionsDrained, NotificationEvent, TRUE);
    status = IoCsqInitialize(&gReadCsq, QnpCsqInsertIrp, QnpCsqRemoveIrp, QnpCsqPeekNextIrp,
        QnpCsqAcquireLock, QnpCsqReleaseLock, QnpCsqCompleteCanceledIrp);
    if (!NT_SUCCESS(status))
        return status;

    RtlInitUnicodeString(&deviceName, L"\\Device\\QriosoNoPingWfp");
    RtlInitUnicodeString(&gSymbolicLink, L"\\DosDevices\\QriosoNoPingWfp");
    status = IoCreateDeviceSecure(DriverObject, 0, &deviceName, FILE_DEVICE_NETWORK, FILE_DEVICE_SECURE_OPEN,
        FALSE, &SDDL_DEVOBJ_SYS_ALL_ADM_ALL, &QNP_WFP_DEVICE_CLASS_GUID, &gDeviceObject);
    if (!NT_SUCCESS(status))
        return status;
    status = IoCreateSymbolicLink(&gSymbolicLink, &deviceName);
    if (!NT_SUCCESS(status))
        goto Failure;

    for (index = 0; index <= IRP_MJ_MAXIMUM_FUNCTION; ++index)
        DriverObject->MajorFunction[index] = QnpDispatchUnsupported;
    DriverObject->MajorFunction[IRP_MJ_CREATE] = QnpDispatchCreateClose;
    DriverObject->MajorFunction[IRP_MJ_CLOSE] = QnpDispatchCreateClose;
    DriverObject->MajorFunction[IRP_MJ_CLEANUP] = QnpDispatchCleanup;
    DriverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL] = QnpDispatchDeviceControl;
    DriverObject->DriverUnload = QnpDriverUnload;

    gNdisObject = NdisAllocateGenericObject(DriverObject, QNP_POOL_TAG, 0);
    if (gNdisObject == NULL)
    {
        status = STATUS_INSUFFICIENT_RESOURCES;
        goto Failure;
    }
    RtlZeroMemory(&poolParameters, sizeof(poolParameters));
    poolParameters.Header.Type = NDIS_OBJECT_TYPE_DEFAULT;
    poolParameters.Header.Revision = NET_BUFFER_LIST_POOL_PARAMETERS_REVISION_1;
    poolParameters.Header.Size = NDIS_SIZEOF_NET_BUFFER_LIST_POOL_PARAMETERS_REVISION_1;
    poolParameters.fAllocateNetBuffer = TRUE;
    poolParameters.PoolTag = QNP_POOL_TAG;
    gNblPool = NdisAllocateNetBufferListPool(gNdisObject, &poolParameters);
    if (gNblPool == NULL)
    {
        status = STATUS_INSUFFICIENT_RESOURCES;
        goto Failure;
    }
    status = FwpsInjectionHandleCreate0(AF_INET, FWPS_INJECTION_TYPE_NETWORK, &gInjectionHandle);
    if (!NT_SUCCESS(status))
        goto Failure;

    RtlZeroMemory(&callout, sizeof(callout));
    callout.calloutKey = QNP_WFP_ALE_CALLOUT_KEY;
    callout.classifyFn = QnpAleClassify;
    callout.notifyFn = QnpNotify;
    status = FwpsCalloutRegister0(gDeviceObject, &callout, &gAleCalloutId);
    if (!NT_SUCCESS(status))
        goto Failure;
    RtlZeroMemory(&callout, sizeof(callout));
    callout.calloutKey = QNP_WFP_TRANSPORT_CALLOUT_KEY;
    callout.classifyFn = QnpTransportClassify;
    callout.notifyFn = QnpNotify;
    callout.flowDeleteFn = QnpFlowDelete;
    status = FwpsCalloutRegister0(gDeviceObject, &callout, &gTransportCalloutId);
    if (!NT_SUCCESS(status))
        goto Failure;

    gDeviceObject->Flags &= ~DO_DEVICE_INITIALIZING;
    return STATUS_SUCCESS;

Failure:
    InterlockedExchange(&gUnloading, 1);
    if (gAleCalloutId != 0)
        FwpsCalloutUnregisterById0(gAleCalloutId);
    if (gTransportCalloutId != 0)
        FwpsCalloutUnregisterById0(gTransportCalloutId);
    if (gInjectionHandle != NULL)
        FwpsInjectionHandleDestroy0(gInjectionHandle);
    if (gNblPool != NULL)
        NdisFreeNetBufferListPool(gNblPool);
    if (gNdisObject != NULL)
        NdisFreeGenericObject(gNdisObject);
    IoDeleteSymbolicLink(&gSymbolicLink);
    if (gDeviceObject != NULL)
        IoDeleteDevice(gDeviceObject);
    return status;
}
