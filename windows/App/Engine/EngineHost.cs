using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI.Dispatching;
using Microsoft.Win32.SafeHandles;

namespace Nearside.Engine;

/// Runs the engine on the UI thread (its main thread) and hands its snapshots and events to the
/// interface. The engine's queued work runs when its wake handle is signalled; its timers run on a
/// short tick.
public static unsafe class EngineHost
{
    /// The engine's latest state; Changed fires with each new one.
    public static Snapshot Current { get; private set; } = new();
    public static event Action<Snapshot>? Changed;
    /// Every other event: (name, the whole JSON object).
    public static event Action<string, JsonElement>? Event;

    private static DispatcherQueue? queue;
    private static NativeWait? wake;
    private static DispatcherQueueTimer? ticker;
    private static int wakes;
    private static string lastState = "";

    /// Sample content instead of the engine (Nearside.exe --demo), for screenshots: nothing personal.
    public static void StartDemo(bool setup)
    {
        Current = Demo.Snapshot(setup);
        Changed?.Invoke(Current);
    }

    public static void Start(DispatcherQueue uiQueue, string? apkPath)
    {
        queue = uiQueue;
        Native.Start(apkPath, &OnEvent);
        var debug = Native.Debug();
        Log.Info($"engine thread: {Marshal.PtrToStringUTF8((nint)debug)}, UI thread {Environment.CurrentManagedThreadId}");
        Native.Free(debug);
        wake = new NativeWait(Native.WakeHandle());
        Arm();
        // Run-loop timers (the engine's reconnect and keepalive ticks) have no handle to wait on.
        ticker = uiQueue.CreateTimer();
        ticker.Interval = TimeSpan.FromMilliseconds(100);
        ticker.Tick += (_, _) => Native.Pump();
        ticker.Start();
        // How often the engine wakes the UI thread (it should be rare while nothing happens).
        var report = uiQueue.CreateTimer();
        report.Interval = TimeSpan.FromMinutes(1);
        report.Tick += (_, _) =>
        {
            Log.Info($"engine wakes in the last minute: {wakes}");
            wakes = 0;
        };
        report.Start();
    }

    /// Waits (once) on the engine's wake handle, then pumps on the UI thread and waits again.
    private static void Arm()
    {
        ThreadPool.RegisterWaitForSingleObject(wake!, (_, _) => queue!.TryEnqueue(() =>
        {
            wakes++;
            Native.Pump();
            Arm();
        }), null, Timeout.Infinite, executeOnlyOnce: true);
    }

    public static void Command(string name, object? fields = null)
    {
        var json = JsonSerializer.SerializeToNode(fields ?? new { })!.AsObject();
        json["c"] = name;
        Native.Command(json.ToJsonString());
    }

    /// From the engine, during a pump on the UI thread. Handled after the pump returns, so nothing
    /// here runs inside the engine's own call (and no exception can cross back into it).
    [UnmanagedCallersOnly]
    private static void OnEvent(byte* json)
    {
        var text = Marshal.PtrToStringUTF8((nint)json) ?? "{}";
        queue?.TryEnqueue(() => Handle(text));
    }

    private static void Handle(string text)
    {
        using var doc = JsonDocument.Parse(text);
        var name = doc.RootElement.GetProperty("e").GetString() ?? "";
        if (name == "changed")
        {
            Current = ReadSnapshot();
            var state = $"{Current.State}{(Current.AppLinked ? ", phone app linked" : "")}";
            if (state != lastState) Log.Info($"engine: {lastState = state}");
            Changed?.Invoke(Current);
        }
        else
        {
            Event?.Invoke(name, doc.RootElement.Clone());
        }
    }

    private static Snapshot ReadSnapshot()
    {
        var p = Native.SnapshotJson();
        try
        {
            return JsonSerializer.Deserialize<Snapshot>(Marshal.PtrToStringUTF8((nint)p) ?? "{}", Snapshot.Json) ?? new();
        }
        finally
        {
            Native.Free(p);
        }
    }

    /// The engine's event handle (owned by the engine) as a WaitHandle.
    private sealed class NativeWait : WaitHandle
    {
        public NativeWait(nint handle) => SafeWaitHandle = new SafeWaitHandle(handle, ownsHandle: false);
    }
}
