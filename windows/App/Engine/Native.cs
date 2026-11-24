using System.Runtime.InteropServices;

namespace Nearside.Engine;

/// The engine's C API (NearsideBridge.dll, windows/Sources/NearsideBridge). Call it on the UI thread
/// only: it is the engine's main thread.
internal static unsafe partial class Native
{
    private const string Dll = "NearsideBridge.dll";

    /// Starts the engine. `onEvent` gets each event as UTF-8 JSON, on the UI thread.
    [LibraryImport(Dll, EntryPoint = "nearside_start", StringMarshalling = StringMarshalling.Utf8)]
    public static partial void Start(string? apkPath, delegate* unmanaged<byte*, void> onEvent);

    /// Signalled when the engine has work queued for the UI thread.
    [LibraryImport(Dll, EntryPoint = "nearside_wake_handle")]
    public static partial nint WakeHandle();

    /// Runs the engine's due work, without waiting.
    [LibraryImport(Dll, EntryPoint = "nearside_pump")]
    public static partial void Pump();

    [LibraryImport(Dll, EntryPoint = "nearside_snapshot")]
    public static partial byte* SnapshotJson();

    /// Phone windows' video: (session, kind, codec, data, length, gen, pts, received) → 1 if usable.
    [LibraryImport(Dll, EntryPoint = "nearside_set_video")]
    public static partial void SetVideo(delegate* unmanaged<long, int, int, byte*, int, uint, long, long, int> video);

    [LibraryImport(Dll, EntryPoint = "nearside_session_open", StringMarshalling = StringMarshalling.Utf8)]
    public static partial byte* SessionOpen(string json);

    [LibraryImport(Dll, EntryPoint = "nearside_session_command", StringMarshalling = StringMarshalling.Utf8)]
    public static partial void SessionCommand(long id, string json);

    [LibraryImport(Dll, EntryPoint = "nearside_session_frame")]
    public static partial void SessionFrame(long id, uint gen, long pts, long received, int black);

    [LibraryImport(Dll, EntryPoint = "nearside_debug")]
    public static partial byte* Debug();

    [LibraryImport(Dll, EntryPoint = "nearside_free")]
    public static partial void Free(byte* text);

    [LibraryImport(Dll, EntryPoint = "nearside_command", StringMarshalling = StringMarshalling.Utf8)]
    public static partial void Command(string json);
}
