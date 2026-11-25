// Nearside's virtual camera for Windows 11: a Media Foundation media source that Windows' camera
// service (Frame Server, running as LocalService) loads for apps that open "Nearside Camera".
// Its frames come from the Nearside app over a named pipe; until then it shows a dark frame.
//
// Security: the DLL lives in Program Files and is registered machine-wide (HKLM), as the camera
// service requires; it only takes frames from a pipe server whose program is in its own folder
// (writable by administrators only), and the app only sends to a client running as LocalService
// (see the app's CameraFeed). Structure after Microsoft's virtual camera documentation and
// VCamSample (MIT, Simon Mourier).
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mferror.h>
#include <mfvirtualcamera.h>
#include <ks.h>
#include <ksproxy.h>
#include <ksmedia.h>
#include <propvarutil.h>
#include <psapi.h>
#include <atomic>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// {6D3A1F52-8B2E-4C67-9A41-5E0B7C2D9F13}
static const GUID CLSID_NearsideCamera = { 0x6d3a1f52, 0x8b2e, 0x4c67, { 0x9a, 0x41, 0x5e, 0x0b, 0x7c, 0x2d, 0x9f, 0x13 } };
/// "\\.\pipe\NearsideCamera-<session>": each signed-in person's Nearside has its own.
static std::wstring PipeName(DWORD session) { return L"\\\\.\\pipe\\NearsideCamera-" + std::to_wstring(session); }
/// The camera service tells the activator which process opened the camera (not in the SDK headers).
static const GUID ClientPid = { 0x5f8d322e, 0x0fe4, 0x43e4, { 0x9e, 0x50, 0xd8, 0x3e, 0xcd, 0x9f, 0xc2, 0xb8 } };
static const UINT32 Width = 1920, Height = 1080, Fps = 30;
static const UINT32 FrameBytes = Width * Height * 3 / 2; // NV12
static const UINT32 Magic = 0x4643534E; // "NSCF"

static HMODULE module;

static void Trace(const wchar_t* format, ...) {
    wchar_t folder[MAX_PATH];
    if (!GetTempPathW(MAX_PATH, folder)) return;
    std::wstring path = std::wstring(folder) + L"NearsideCamera.log";
    wchar_t line[512];
    va_list args;
    va_start(args, format);
    _vsnwprintf_s(line, _TRUNCATE, format, args);
    va_end(args);
    HANDLE file = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, 0, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    LARGE_INTEGER size{};
    if (GetFileSizeEx(file, &size) && size.QuadPart > 1'000'000) { CloseHandle(file); DeleteFileW(path.c_str()); return; }
    SYSTEMTIME t;
    GetLocalTime(&t);
    char out[700];
    int n = snprintf(out, sizeof out, "%02d:%02d:%02d.%03d %ls\r\n", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds, line);
    DWORD written = 0;
    if (n > 0) WriteFile(file, out, (DWORD)min(n, (int)sizeof out - 1), &written, nullptr);
    CloseHandle(file);
}
static std::atomic<long> objects{0};

#define RETURN_IF_FAILED(x) do { HRESULT hr_ = (x); if (FAILED(hr_)) return hr_; } while (0)

template <class T> struct Ptr {
    T* p = nullptr;
    Ptr() = default;
    Ptr(const Ptr&) = delete;
    ~Ptr() { if (p) p->Release(); }
    T** put() { if (p) { p->Release(); p = nullptr; } return &p; }
    T* get() const { return p; }
    T* operator->() const { return p; }
    explicit operator bool() const { return p != nullptr; }
    void reset(T* v = nullptr) { if (v) v->AddRef(); if (p) p->Release(); p = v; }
    T* detach() { T* v = p; p = nullptr; return v; }
};

// MARK: - The latest frame from the app

/// Frames from the Nearside app's pipe, on a reading thread; the stream copies the newest.
struct Feed {
    std::mutex lock;
    std::vector<BYTE> frame; // NV12, Width x Height; empty until the first
    std::atomic<bool> running{false};
    /// The Windows session of the app using the camera; frames only come from that session's
    /// Nearside. Unknown (-1): none are taken.
    std::atomic<long> session{-1};
    std::thread reader;
    HANDLE pipe = INVALID_HANDLE_VALUE;

    void Start() {
        if (running.exchange(true)) return;
        reader = std::thread([this] { Run(); });
    }

    void Stop() {
        if (!running.exchange(false)) return;
        HANDLE p;
        { std::lock_guard<std::mutex> g(lock); p = pipe; }
        if (p != INVALID_HANDLE_VALUE) CancelIoEx(p, nullptr);
        if (reader.joinable()) reader.join();
        std::lock_guard<std::mutex> g(lock);
        frame.clear();
    }

    /// The folder this DLL is in, as an NT path ("\\Device\\HarddiskVolume3\\Program Files\\Nearside\\"):
    /// the app feeding it must be there too.
    static std::wstring OwnFolder() {
        wchar_t path[MAX_PATH];
        if (!GetModuleFileNameW(module, path, MAX_PATH)) return L"";
        HANDLE file = CreateFileW(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
        if (file == INVALID_HANDLE_VALUE) return L"";
        wchar_t nt[MAX_PATH];
        DWORD n = GetFinalPathNameByHandleW(file, nt, MAX_PATH, VOLUME_NAME_NT);
        CloseHandle(file);
        if (n == 0 || n >= MAX_PATH) return L"";
        std::wstring s(nt, n);
        return s.substr(0, s.find_last_of(L'\\') + 1);
    }

    /// A process's image as an NT path, without opening it (this runs as LocalService, which may
    /// not open the user's processes): SystemProcessIdInformation.
    static std::wstring ImageOf(ULONG pid) {
        struct UnicodeString { USHORT Length, MaximumLength; PWSTR Buffer; };
        struct ProcessIdInformation { HANDLE ProcessId; UnicodeString ImageName; };
        using Query = LONG(NTAPI*)(ULONG, PVOID, ULONG, PULONG);
        static auto query = reinterpret_cast<Query>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQuerySystemInformation"));
        if (!query) return L"";
        std::vector<wchar_t> buffer(1024);
        ProcessIdInformation info{ reinterpret_cast<HANDLE>(static_cast<ULONG_PTR>(pid)), { 0, (USHORT)(buffer.size() * sizeof(wchar_t)), buffer.data() } };
        if (query(88 /* SystemProcessIdInformation */, &info, sizeof info, nullptr) < 0) return L"";
        return std::wstring(info.ImageName.Buffer, info.ImageName.Length / sizeof(wchar_t));
    }

    /// The pipe's server is the Nearside app installed next to this DLL (a folder only
    /// administrators can write to).
    static bool TrustedServer(HANDLE p, DWORD session) {
        ULONG serverSession = 0;
        if (!GetNamedPipeServerSessionId(p, &serverSession) || serverSession != session) return false;
        ULONG pid = 0;
        if (!GetNamedPipeServerProcessId(p, &pid) || pid == 0) return false;
        std::wstring image = ImageOf(pid), folder = OwnFolder();
        Trace(L"pipe: server %ls, folder %ls", image.c_str(), folder.c_str());
        if (folder.empty() || image.size() <= folder.size()) return false;
        return CompareStringOrdinal(image.c_str(), (int)folder.size(), folder.c_str(), (int)folder.size(), TRUE) == CSTR_EQUAL
            && image.find(L'\\', folder.size()) == std::wstring::npos // directly in it, not in a subfolder
            && CompareStringOrdinal(image.c_str() + folder.size(), -1, L"Nearside.exe", -1, TRUE) == CSTR_EQUAL;
    }

    static bool ReadAll(HANDLE p, void* into, DWORD count) {
        auto bytes = static_cast<BYTE*>(into);
        while (count > 0) {
            DWORD read = 0;
            if (!ReadFile(p, bytes, count, &read, nullptr) || read == 0) return false;
            bytes += read;
            count -= read;
        }
        return true;
    }

    DWORD lastError = 0;

    void Run() {
        Trace(L"feed: started");
        std::vector<BYTE> incoming(FrameBytes);
        while (running) {
            long s = session;
            if (s < 0) {
                if (lastError != 1) Trace(L"feed: the camera's user is unknown; no frames");
                lastError = 1;
                Sleep(500);
                continue;
            }
            HANDLE p = CreateFileW(PipeName((DWORD)s).c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
            if (p == INVALID_HANDLE_VALUE) {
                DWORD error = GetLastError();
                if (error != lastError) Trace(L"pipe: can't open (%lu)", error);
                lastError = error;
                Sleep(500); // the app isn't running (yet)
                continue;
            }
            lastError = 0;
            if (!TrustedServer(p, (DWORD)s)) {
                Trace(L"pipe: server refused (not Nearside.exe next to this DLL)");
                CloseHandle(p);
                Sleep(2000);
                continue;
            }
            { std::lock_guard<std::mutex> g(lock); pipe = p; }
            Trace(L"pipe: connected to Nearside");
            // Hello: the app starts the phone's camera now.
            UINT32 hello[2] = { Magic, 1 };
            DWORD written = 0;
            WriteFile(p, hello, sizeof hello, &written, nullptr);
            while (running) {
                UINT32 header[4];
                if (!ReadAll(p, header, sizeof header)) break;
                if (header[0] != Magic || header[1] != Width || header[2] != Height || header[3] != FrameBytes) break;
                if (!ReadAll(p, incoming.data(), FrameBytes)) break;
                std::lock_guard<std::mutex> g(lock);
                frame.swap(incoming);
                if (incoming.size() != FrameBytes) incoming.resize(FrameBytes);
            }
            { std::lock_guard<std::mutex> g(lock); pipe = INVALID_HANDLE_VALUE; frame.clear(); }
            CloseHandle(p);
        }
    }

    /// Copies the newest frame into an NV12 buffer with `pitch`; a dark frame when there's none.
    void CopyInto(BYTE* out, LONG pitch) {
        std::lock_guard<std::mutex> g(lock);
        const bool have = frame.size() == FrameBytes;
        for (UINT32 y = 0; y < Height; y++) {
            BYTE* row = out + (size_t)y * pitch;
            if (have) memcpy(row, frame.data() + (size_t)y * Width, Width); else memset(row, 16, Width);
        }
        BYTE* uv = out + (size_t)Height * pitch;
        for (UINT32 y = 0; y < Height / 2; y++) {
            BYTE* row = uv + (size_t)y * pitch;
            if (have) memcpy(row, frame.data() + (size_t)Width * Height + (size_t)y * Width, Width); else memset(row, 128, Width);
        }
    }
};

/// A process's Windows session, without opening it (LocalService may not): from the system's
/// process list. -1 if it isn't running.
static long SessionOf(ULONG pid) {
    struct Process { // the start of SYSTEM_PROCESS_INFORMATION
        ULONG NextEntryOffset, NumberOfThreads;
        BYTE Reserved1[48];
        USHORT NameLength, NameMaximumLength;
        PWSTR Name;
        LONG BasePriority;
        HANDLE UniqueProcessId;
        HANDLE InheritedFromUniqueProcessId;
        ULONG HandleCount, SessionId;
    };
    using Query = LONG(NTAPI*)(ULONG, PVOID, ULONG, PULONG);
    static auto query = reinterpret_cast<Query>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQuerySystemInformation"));
    if (!query) return -1;
    std::vector<BYTE> buffer(1 << 20);
    ULONG needed = 0;
    LONG status;
    while ((status = query(5 /* SystemProcessInformation */, buffer.data(), (ULONG)buffer.size(), &needed)) == (LONG)0xC0000004 /* length mismatch */) {
        buffer.resize(needed + 65536);
    }
    if (status < 0) return -1;
    for (size_t offset = 0;;) {
        auto process = reinterpret_cast<Process*>(buffer.data() + offset);
        if ((ULONG)(ULONG_PTR)process->UniqueProcessId == pid) return (long)process->SessionId;
        if (process->NextEntryOffset == 0) return -1;
        offset += process->NextEntryOffset;
    }
}

// MARK: - IMFAttributes, delegated to an inner store

#define FORWARD_ATTRIBUTES(inner) \
    STDMETHODIMP GetItem(REFGUID k, PROPVARIANT* v) override { return inner->GetItem(k, v); } \
    STDMETHODIMP GetItemType(REFGUID k, MF_ATTRIBUTE_TYPE* t) override { return inner->GetItemType(k, t); } \
    STDMETHODIMP CompareItem(REFGUID k, REFPROPVARIANT v, BOOL* r) override { return inner->CompareItem(k, v, r); } \
    STDMETHODIMP Compare(IMFAttributes* a, MF_ATTRIBUTES_MATCH_TYPE m, BOOL* r) override { return inner->Compare(a, m, r); } \
    STDMETHODIMP GetUINT32(REFGUID k, UINT32* v) override { return inner->GetUINT32(k, v); } \
    STDMETHODIMP GetUINT64(REFGUID k, UINT64* v) override { return inner->GetUINT64(k, v); } \
    STDMETHODIMP GetDouble(REFGUID k, double* v) override { return inner->GetDouble(k, v); } \
    STDMETHODIMP GetGUID(REFGUID k, GUID* v) override { return inner->GetGUID(k, v); } \
    STDMETHODIMP GetStringLength(REFGUID k, UINT32* n) override { return inner->GetStringLength(k, n); } \
    STDMETHODIMP GetString(REFGUID k, LPWSTR s, UINT32 n, UINT32* l) override { return inner->GetString(k, s, n, l); } \
    STDMETHODIMP GetAllocatedString(REFGUID k, LPWSTR* s, UINT32* l) override { return inner->GetAllocatedString(k, s, l); } \
    STDMETHODIMP GetBlobSize(REFGUID k, UINT32* n) override { return inner->GetBlobSize(k, n); } \
    STDMETHODIMP GetBlob(REFGUID k, UINT8* b, UINT32 n, UINT32* l) override { return inner->GetBlob(k, b, n, l); } \
    STDMETHODIMP GetAllocatedBlob(REFGUID k, UINT8** b, UINT32* n) override { return inner->GetAllocatedBlob(k, b, n); } \
    STDMETHODIMP GetUnknown(REFGUID k, REFIID i, LPVOID* p) override { return inner->GetUnknown(k, i, p); } \
    STDMETHODIMP SetItem(REFGUID k, REFPROPVARIANT v) override { return inner->SetItem(k, v); } \
    STDMETHODIMP DeleteItem(REFGUID k) override { return inner->DeleteItem(k); } \
    STDMETHODIMP DeleteAllItems() override { return inner->DeleteAllItems(); } \
    STDMETHODIMP SetUINT32(REFGUID k, UINT32 v) override { return inner->SetUINT32(k, v); } \
    STDMETHODIMP SetUINT64(REFGUID k, UINT64 v) override { return inner->SetUINT64(k, v); } \
    STDMETHODIMP SetDouble(REFGUID k, double v) override { return inner->SetDouble(k, v); } \
    STDMETHODIMP SetGUID(REFGUID k, REFGUID v) override { return inner->SetGUID(k, v); } \
    STDMETHODIMP SetString(REFGUID k, LPCWSTR v) override { return inner->SetString(k, v); } \
    STDMETHODIMP SetBlob(REFGUID k, const UINT8* b, UINT32 n) override { return inner->SetBlob(k, b, n); } \
    STDMETHODIMP SetUnknown(REFGUID k, IUnknown* u) override { return inner->SetUnknown(k, u); } \
    STDMETHODIMP LockStore() override { return inner->LockStore(); } \
    STDMETHODIMP UnlockStore() override { return inner->UnlockStore(); } \
    STDMETHODIMP GetCount(UINT32* n) override { return inner->GetCount(n); } \
    STDMETHODIMP GetItemByIndex(UINT32 i, GUID* k, PROPVARIANT* v) override { return inner->GetItemByIndex(i, k, v); } \
    STDMETHODIMP CopyAllItems(IMFAttributes* d) override { return inner->CopyAllItems(d); }

#define REFCOUNT \
    std::atomic<ULONG> refs{1}; \
    STDMETHODIMP_(ULONG) AddRef() override { return ++refs; } \
    STDMETHODIMP_(ULONG) Release() override { ULONG n = --refs; if (n == 0) delete this; return n; }

static const HRESULT NotFound = HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND);

// MARK: - The stream

struct Source;

struct Stream : IMFMediaStream2, IKsControl {
    REFCOUNT
    Ptr<IMFAttributes> attributes;
    Ptr<IMFMediaEventQueue> queue;
    Ptr<IMFStreamDescriptor> descriptor;
    Ptr<IMFVideoSampleAllocatorEx> allocator;
    IMFMediaSource* source = nullptr; // not owned: the source owns the stream
    MF_STREAM_STATE state = MF_STREAM_STATE_STOPPED;
    std::mutex lock;
    Feed feed;

    Stream() { objects++; }
    ~Stream() { feed.Stop(); objects--; }

    HRESULT Initialize(IMFMediaSource* owner) {
        source = owner;
        RETURN_IF_FAILED(MFCreateAttributes(attributes.put(), 4));
        RETURN_IF_FAILED(attributes->SetGUID(MF_DEVICESTREAM_STREAM_CATEGORY, PINNAME_VIDEO_CAPTURE));
        RETURN_IF_FAILED(attributes->SetUINT32(MF_DEVICESTREAM_STREAM_ID, 0));
        RETURN_IF_FAILED(attributes->SetUINT32(MF_DEVICESTREAM_FRAMESERVER_SHARED, 1));
        RETURN_IF_FAILED(attributes->SetUINT32(MF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES, MFFrameSourceTypes_Color));
        RETURN_IF_FAILED(MFCreateEventQueue(queue.put()));
        Ptr<IMFMediaType> type;
        RETURN_IF_FAILED(MFCreateMediaType(type.put()));
        type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
        type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        type->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
        MFSetAttributeSize(type.get(), MF_MT_FRAME_SIZE, Width, Height);
        type->SetUINT32(MF_MT_DEFAULT_STRIDE, Width);
        MFSetAttributeRatio(type.get(), MF_MT_FRAME_RATE, Fps, 1);
        MFSetAttributeRatio(type.get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
        type->SetUINT32(MF_MT_AVG_BITRATE, FrameBytes * 8 * Fps);
        IMFMediaType* types[] = { type.get() };
        RETURN_IF_FAILED(MFCreateStreamDescriptor(0, 1, types, descriptor.put()));
        Ptr<IMFMediaTypeHandler> handler;
        RETURN_IF_FAILED(descriptor->GetMediaTypeHandler(handler.put()));
        return handler->SetCurrentMediaType(type.get());
    }

    HRESULT Start(IMFMediaType* type) {
        if (!queue || !allocator) return MF_E_SHUTDOWN;
        if (type) RETURN_IF_FAILED(allocator->InitializeSampleAllocator(10, type));
        state = MF_STREAM_STATE_RUNNING;
        feed.Start(); // an app is using the camera: ask Nearside for the phone's
        return queue->QueueEventParamVar(MEStreamStarted, GUID_NULL, S_OK, nullptr);
    }

    HRESULT Stop() {
        if (!queue || !allocator) return MF_E_SHUTDOWN;
        feed.Stop(); // the app's pipe closes: Nearside stops the phone's camera
        allocator->UninitializeSampleAllocator();
        state = MF_STREAM_STATE_STOPPED;
        return queue->QueueEventParamVar(MEStreamStopped, GUID_NULL, S_OK, nullptr);
    }

    void Shutdown() {
        feed.Stop();
        std::lock_guard<std::mutex> g(lock);
        if (queue) queue->Shutdown();
        queue.reset();
        descriptor.reset();
        allocator.reset();
        source = nullptr;
    }

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER;
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IMFMediaEventGenerator) || iid == __uuidof(IMFMediaStream) || iid == __uuidof(IMFMediaStream2)) *out = static_cast<IMFMediaStream2*>(this);
        else if (iid == __uuidof(IKsControl)) *out = static_cast<IKsControl*>(this);
        else if (iid == __uuidof(IMFAttributes) && attributes) return attributes->QueryInterface(iid, out);
        else { *out = nullptr; return E_NOINTERFACE; }
        AddRef();
        return S_OK;
    }

    // IMFMediaEventGenerator
    STDMETHODIMP BeginGetEvent(IMFAsyncCallback* c, IUnknown* s) override { std::lock_guard<std::mutex> g(lock); return queue ? queue->BeginGetEvent(c, s) : MF_E_SHUTDOWN; }
    STDMETHODIMP EndGetEvent(IMFAsyncResult* r, IMFMediaEvent** e) override { std::lock_guard<std::mutex> g(lock); return queue ? queue->EndGetEvent(r, e) : MF_E_SHUTDOWN; }
    STDMETHODIMP GetEvent(DWORD f, IMFMediaEvent** e) override { Ptr<IMFMediaEventQueue> q; { std::lock_guard<std::mutex> g(lock); q.reset(queue.get()); } return q ? q->GetEvent(f, e) : MF_E_SHUTDOWN; }
    STDMETHODIMP QueueEvent(MediaEventType t, REFGUID g2, HRESULT h, const PROPVARIANT* v) override { std::lock_guard<std::mutex> g(lock); return queue ? queue->QueueEventParamVar(t, g2, h, v) : MF_E_SHUTDOWN; }

    // IMFMediaStream
    STDMETHODIMP GetMediaSource(IMFMediaSource** out) override {
        if (!out) return E_POINTER;
        if (!source) return MF_E_SHUTDOWN;
        *out = source;
        source->AddRef();
        return S_OK;
    }
    STDMETHODIMP GetStreamDescriptor(IMFStreamDescriptor** out) override {
        if (!out) return E_POINTER;
        std::lock_guard<std::mutex> g(lock);
        if (!descriptor) return MF_E_SHUTDOWN;
        *out = descriptor.get();
        (*out)->AddRef();
        return S_OK;
    }
    STDMETHODIMP RequestSample(IUnknown* token) override {
        std::lock_guard<std::mutex> g(lock);
        if (!allocator || !queue) return MF_E_SHUTDOWN;
        Ptr<IMFSample> sample;
        RETURN_IF_FAILED(allocator->AllocateSample(sample.put()));
        RETURN_IF_FAILED(sample->SetSampleTime(MFGetSystemTime()));
        RETURN_IF_FAILED(sample->SetSampleDuration(10'000'000 / Fps));
        Ptr<IMFMediaBuffer> buffer;
        RETURN_IF_FAILED(sample->GetBufferByIndex(0, buffer.put()));
        Ptr<IMF2DBuffer2> plane;
        if (SUCCEEDED(buffer->QueryInterface(__uuidof(IMF2DBuffer2), (void**)plane.put()))) {
            BYTE* scan = nullptr; LONG pitch = 0; BYTE* start = nullptr; DWORD length = 0;
            RETURN_IF_FAILED(plane->Lock2DSize(MF2DBuffer_LockFlags_Write, &scan, &pitch, &start, &length));
            if (pitch > 0 && (DWORD)pitch * Height * 3 / 2 <= length) feed.CopyInto(scan, pitch);
            plane->Unlock2D();
        } else {
            BYTE* data = nullptr; DWORD max = 0;
            RETURN_IF_FAILED(buffer->Lock(&data, &max, nullptr));
            if (max >= FrameBytes) feed.CopyInto(data, Width);
            buffer->Unlock();
            buffer->SetCurrentLength(FrameBytes);
        }
        if (token) RETURN_IF_FAILED(sample->SetUnknown(MFSampleExtension_Token, token));
        return queue->QueueEventParamUnk(MEMediaSample, GUID_NULL, S_OK, sample.get());
    }

    // IMFMediaStream2
    STDMETHODIMP SetStreamState(MF_STREAM_STATE value) override {
        if (value == state) return S_OK;
        switch (value) {
        case MF_STREAM_STATE_PAUSED:
            if (state != MF_STREAM_STATE_RUNNING) return MF_E_INVALID_STATE_TRANSITION;
            state = value;
            return S_OK;
        case MF_STREAM_STATE_RUNNING: return Start(nullptr);
        case MF_STREAM_STATE_STOPPED: return Stop();
        default: return MF_E_INVALID_STATE_TRANSITION;
        }
    }
    STDMETHODIMP GetStreamState(MF_STREAM_STATE* value) override { if (!value) return E_POINTER; *value = state; return S_OK; }

    // IKsControl: no controls of our own.
    STDMETHODIMP KsProperty(PKSPROPERTY, ULONG, LPVOID, ULONG, ULONG* returned) override { if (returned) *returned = 0; return NotFound; }
    STDMETHODIMP KsMethod(PKSMETHOD, ULONG, LPVOID, ULONG, ULONG* returned) override { if (returned) *returned = 0; return NotFound; }
    STDMETHODIMP KsEvent(PKSEVENT, ULONG, LPVOID, ULONG, ULONG* returned) override { if (returned) *returned = 0; return NotFound; }
};

// MARK: - The source

struct Source : IMFMediaSourceEx, IMFGetService, IKsControl, IMFSampleAllocatorControl {
    REFCOUNT
    Ptr<IMFAttributes> attributes;
    Ptr<IMFMediaEventQueue> queue;
    Ptr<IMFPresentationDescriptor> descriptor;
    Stream* stream = nullptr; // owned
    std::mutex lock;

    Source() { objects++; }
    ~Source() { if (stream) stream->Release(); objects--; }

    HRESULT Initialize(IMFAttributes* given) {
        RETURN_IF_FAILED(MFCreateAttributes(attributes.put(), 8));
        if (given) RETURN_IF_FAILED(given->CopyAllItems(attributes.get()));
        // Profiles: the Camera app wants them.
        Ptr<IMFSensorProfileCollection> profiles;
        RETURN_IF_FAILED(MFCreateSensorProfileCollection(profiles.put()));
        Ptr<IMFSensorProfile> profile;
        RETURN_IF_FAILED(MFCreateSensorProfile(KSCAMERAPROFILE_Legacy, 0, nullptr, profile.put()));
        RETURN_IF_FAILED(profile->AddProfileFilter(0, L"((RES==;FRT<=30,1;SUT==))"));
        RETURN_IF_FAILED(profiles->AddProfile(profile.get()));
        RETURN_IF_FAILED(attributes->SetUnknown(MF_DEVICEMFT_SENSORPROFILE_COLLECTION, profiles.get()));

        stream = new Stream();
        RETURN_IF_FAILED(stream->Initialize(this));
        IMFStreamDescriptor* streams[1] = {};
        RETURN_IF_FAILED(stream->GetStreamDescriptor(&streams[0]));
        HRESULT hr = MFCreatePresentationDescriptor(1, streams, descriptor.put());
        streams[0]->Release();
        RETURN_IF_FAILED(hr);
        return MFCreateEventQueue(queue.put());
    }

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER;
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IMFMediaEventGenerator) || iid == __uuidof(IMFMediaSource) || iid == __uuidof(IMFMediaSourceEx)) *out = static_cast<IMFMediaSourceEx*>(this);
        else if (iid == __uuidof(IMFGetService)) *out = static_cast<IMFGetService*>(this);
        else if (iid == __uuidof(IKsControl)) *out = static_cast<IKsControl*>(this);
        else if (iid == __uuidof(IMFSampleAllocatorControl)) *out = static_cast<IMFSampleAllocatorControl*>(this);
        else if (iid == __uuidof(IMFAttributes) && attributes) return attributes->QueryInterface(iid, out);
        else { *out = nullptr; return E_NOINTERFACE; }
        AddRef();
        return S_OK;
    }

    // IMFMediaEventGenerator
    STDMETHODIMP BeginGetEvent(IMFAsyncCallback* c, IUnknown* s) override { std::lock_guard<std::mutex> g(lock); return queue ? queue->BeginGetEvent(c, s) : MF_E_SHUTDOWN; }
    STDMETHODIMP EndGetEvent(IMFAsyncResult* r, IMFMediaEvent** e) override { std::lock_guard<std::mutex> g(lock); return queue ? queue->EndGetEvent(r, e) : MF_E_SHUTDOWN; }
    STDMETHODIMP GetEvent(DWORD f, IMFMediaEvent** e) override { Ptr<IMFMediaEventQueue> q; { std::lock_guard<std::mutex> g(lock); q.reset(queue.get()); } return q ? q->GetEvent(f, e) : MF_E_SHUTDOWN; }
    STDMETHODIMP QueueEvent(MediaEventType t, REFGUID g2, HRESULT h, const PROPVARIANT* v) override { std::lock_guard<std::mutex> g(lock); return queue ? queue->QueueEventParamVar(t, g2, h, v) : MF_E_SHUTDOWN; }

    // IMFMediaSource
    STDMETHODIMP CreatePresentationDescriptor(IMFPresentationDescriptor** out) override {
        if (!out) return E_POINTER;
        std::lock_guard<std::mutex> g(lock);
        return descriptor ? descriptor->Clone(out) : MF_E_SHUTDOWN;
    }
    STDMETHODIMP GetCharacteristics(DWORD* c) override { if (!c) return E_POINTER; *c = MFMEDIASOURCE_IS_LIVE; return S_OK; }
    STDMETHODIMP Pause() override { return MF_E_INVALID_STATE_TRANSITION; }
    STDMETHODIMP Shutdown() override {
        std::lock_guard<std::mutex> g(lock);
        if (!queue) return MF_E_SHUTDOWN;
        queue->Shutdown();
        queue.reset();
        if (stream) stream->Shutdown();
        descriptor.reset();
        return S_OK;
    }
    STDMETHODIMP Start(IMFPresentationDescriptor* pd, const GUID* format, const PROPVARIANT* position) override {
        if (!pd || !position) return E_POINTER;
        if (format && *format != GUID_NULL) return MF_E_UNSUPPORTED_TIME_FORMAT;
        std::lock_guard<std::mutex> g(lock);
        if (!queue || !descriptor) return MF_E_SHUTDOWN;
        DWORD count = 0;
        RETURN_IF_FAILED(pd->GetStreamDescriptorCount(&count));
        if (count != 1) return E_INVALIDARG;
        BOOL selected = FALSE;
        Ptr<IMFStreamDescriptor> desc;
        RETURN_IF_FAILED(pd->GetStreamDescriptorByIndex(0, &selected, desc.put()));
        MF_STREAM_STATE state;
        stream->GetStreamState(&state);
        const bool running = state != MF_STREAM_STATE_STOPPED;
        if (selected && !running) {
            RETURN_IF_FAILED(descriptor->SelectStream(0));
            RETURN_IF_FAILED(queue->QueueEventParamUnk(MENewStream, GUID_NULL, S_OK, static_cast<IMFMediaStream2*>(stream)));
            Ptr<IMFMediaTypeHandler> handler;
            Ptr<IMFMediaType> type;
            RETURN_IF_FAILED(desc->GetMediaTypeHandler(handler.put()));
            RETURN_IF_FAILED(handler->GetCurrentMediaType(type.put()));
            RETURN_IF_FAILED(stream->Start(type.get()));
        } else if (!selected && running) {
            RETURN_IF_FAILED(descriptor->DeselectStream(0));
            RETURN_IF_FAILED(stream->Stop());
        }
        PROPVARIANT time;
        InitPropVariantFromInt64(MFGetSystemTime(), &time);
        HRESULT hr = queue->QueueEventParamVar(MESourceStarted, GUID_NULL, S_OK, &time);
        PropVariantClear(&time);
        return hr;
    }
    STDMETHODIMP Stop() override {
        std::lock_guard<std::mutex> g(lock);
        if (!queue || !descriptor) return MF_E_SHUTDOWN;
        stream->Stop();
        descriptor->DeselectStream(0);
        PROPVARIANT time;
        InitPropVariantFromInt64(MFGetSystemTime(), &time);
        HRESULT hr = queue->QueueEventParamVar(MESourceStopped, GUID_NULL, S_OK, &time);
        PropVariantClear(&time);
        return hr;
    }

    // IMFMediaSourceEx
    STDMETHODIMP GetSourceAttributes(IMFAttributes** out) override {
        if (!out) return E_POINTER;
        *out = attributes.get();
        (*out)->AddRef();
        return S_OK;
    }
    STDMETHODIMP GetStreamAttributes(DWORD id, IMFAttributes** out) override {
        if (!out) return E_POINTER;
        if (id != 0 || !stream) return E_FAIL;
        *out = stream->attributes.get();
        (*out)->AddRef();
        return S_OK;
    }
    /// Samples stay in system memory (the frames come from the CPU anyway).
    STDMETHODIMP SetD3DManager(IUnknown*) override { return S_OK; }

    // IMFGetService
    STDMETHODIMP GetService(REFGUID, REFIID, LPVOID* out) override { if (out) *out = nullptr; return MF_E_UNSUPPORTED_SERVICE; }

    // IMFSampleAllocatorControl
    STDMETHODIMP SetDefaultAllocator(DWORD id, IUnknown* allocator) override {
        if (!allocator) return E_POINTER;
        if (id != 0) return E_FAIL;
        std::lock_guard<std::mutex> g(lock);
        stream->allocator.reset();
        return allocator->QueryInterface(__uuidof(IMFVideoSampleAllocatorEx), (void**)stream->allocator.put());
    }
    STDMETHODIMP GetAllocatorUsage(DWORD id, DWORD* input, MFSampleAllocatorUsage* usage) override {
        if (!input || !usage) return E_POINTER;
        if (id != 0) return E_FAIL;
        *input = id;
        *usage = MFSampleAllocatorUsage_UsesProvidedAllocator;
        return S_OK;
    }

    // IKsControl
    STDMETHODIMP KsProperty(PKSPROPERTY, ULONG, LPVOID, ULONG, ULONG* returned) override { if (returned) *returned = 0; return NotFound; }
    STDMETHODIMP KsMethod(PKSMETHOD, ULONG, LPVOID, ULONG, ULONG* returned) override { if (returned) *returned = 0; return NotFound; }
    STDMETHODIMP KsEvent(PKSEVENT, ULONG, LPVOID, ULONG, ULONG* returned) override { if (returned) *returned = 0; return NotFound; }
};

// MARK: - The activator Windows creates

struct Activator : IMFActivate {
    REFCOUNT
    Ptr<IMFAttributes> attributes;
    Source* source = nullptr;

    Activator() { objects++; }
    ~Activator() { if (source) source->Release(); objects--; }

    HRESULT Initialize() {
        RETURN_IF_FAILED(MFCreateAttributes(attributes.put(), 4));
        RETURN_IF_FAILED(attributes->SetUINT32(MF_VIRTUALCAMERA_PROVIDE_ASSOCIATED_CAMERA_SOURCES, 1));
        RETURN_IF_FAILED(attributes->SetGUID(MFT_TRANSFORM_CLSID_Attribute, CLSID_NearsideCamera));
        source = new Source();
        return source->Initialize(attributes.get());
    }

    STDMETHODIMP QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER;
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IMFAttributes) || iid == __uuidof(IMFActivate)) *out = static_cast<IMFActivate*>(this);
        else { *out = nullptr; return E_NOINTERFACE; }
        AddRef();
        return S_OK;
    }
    FORWARD_ATTRIBUTES(attributes)
    STDMETHODIMP ActivateObject(REFIID iid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        // Whose camera this is: the session of the process that opened it.
        UINT32 pid = 0;
        long session = -1;
        if (source && source->stream && SUCCEEDED(attributes->GetUINT32(ClientPid, &pid)) && pid && (session = SessionOf(pid)) >= 0) {
            source->stream->feed.session = session;
            Trace(L"activate: for session %ld", session);
        }
        return source ? source->QueryInterface(iid, out) : MF_E_SHUTDOWN;
    }
    STDMETHODIMP ShutdownObject() override { return S_OK; }
    STDMETHODIMP DetachObject() override {
        if (source) source->Release();
        source = nullptr;
        return S_OK;
    }
};

// MARK: - COM registration

struct Factory : IClassFactory {
    STDMETHODIMP QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER;
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IClassFactory)) { *out = this; return S_OK; }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return 2; }
    STDMETHODIMP_(ULONG) Release() override { return 1; }
    STDMETHODIMP CreateInstance(IUnknown* outer, REFIID iid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (outer) return CLASS_E_NOAGGREGATION;
        auto activator = new Activator();
        HRESULT hr = activator->Initialize();
        if (SUCCEEDED(hr)) hr = activator->QueryInterface(iid, out);
        activator->Release();
        return hr;
    }
    STDMETHODIMP LockServer(BOOL) override { return S_OK; }
};

static Factory factory;

static std::wstring ClsidString() {
    wchar_t s[64];
    StringFromGUID2(CLSID_NearsideCamera, s, 64);
    return s;
}

BOOL APIENTRY DllMain(HMODULE handle, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        module = handle;
        DisableThreadLibraryCalls(handle);
    }
    return TRUE;
}

STDAPI DllCanUnloadNow() { return objects == 0 ? S_OK : S_FALSE; }

STDAPI DllGetClassObject(REFCLSID clsid, REFIID iid, LPVOID* out) {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (clsid != CLSID_NearsideCamera) return CLASS_E_CLASSNOTAVAILABLE;
    return factory.QueryInterface(iid, out);
}

/// Machine-wide, as the camera service needs (the installer runs it, as an administrator).
STDAPI DllRegisterServer() {
    wchar_t path[MAX_PATH];
    DWORD n = GetModuleFileNameW(module, path, MAX_PATH);
    std::wstring key = L"Software\\Classes\\CLSID\\" + ClsidString() + L"\\InprocServer32";
    HKEY hkey;
    LSTATUS s = RegCreateKeyExW(HKEY_LOCAL_MACHINE, key.c_str(), 0, nullptr, 0, KEY_WRITE, nullptr, &hkey, nullptr);
    if (s != ERROR_SUCCESS) return HRESULT_FROM_WIN32(s);
    s = RegSetValueExW(hkey, nullptr, 0, REG_SZ, (const BYTE*)path, (n + 1) * sizeof(wchar_t));
    if (s == ERROR_SUCCESS) s = RegSetValueExW(hkey, L"ThreadingModel", 0, REG_SZ, (const BYTE*)L"Both", 5 * sizeof(wchar_t));
    RegCloseKey(hkey);
    return HRESULT_FROM_WIN32(s);
}

STDAPI DllUnregisterServer() {
    std::wstring key = L"Software\\Classes\\CLSID\\" + ClsidString();
    LSTATUS s = RegDeleteTreeW(HKEY_LOCAL_MACHINE, key.c_str());
    return s == ERROR_FILE_NOT_FOUND ? S_OK : HRESULT_FROM_WIN32(s);
}

// MARK: - For the app: the camera exists while Nearside runs

/// Makes "Nearside Camera" appear to this user's apps (until NearsideCameraRemove, or the app
/// quits). Returns the camera to pass to NearsideCameraRemove, or null.
extern "C" __declspec(dllexport) HRESULT NearsideCameraCreate(LPCWSTR name, void** camera) {
    if (!camera) return E_POINTER;
    *camera = nullptr;
    RETURN_IF_FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE)); // counted: balanced in NearsideCameraRemove
    IMFVirtualCamera* vcam = nullptr;
    auto clsid = ClsidString();
    RETURN_IF_FAILED(MFCreateVirtualCamera(MFVirtualCameraType_SoftwareCameraSource, MFVirtualCameraLifetime_Session,
                                           MFVirtualCameraAccess_CurrentUser, name, clsid.c_str(), nullptr, 0, &vcam));
    HRESULT hr = vcam->Start(nullptr);
    if (FAILED(hr)) {
        vcam->Release();
        MFShutdown();
        return hr;
    }
    *camera = vcam;
    return S_OK;
}

extern "C" __declspec(dllexport) HRESULT NearsideCameraRemove(void* camera) {
    if (!camera) return S_OK;
    auto vcam = static_cast<IMFVirtualCamera*>(camera);
    HRESULT hr = vcam->Remove();
    vcam->Release();
    MFShutdown();
    return hr;
}
