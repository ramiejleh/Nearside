using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using Nearside.Engine;

namespace Nearside.Video;

/// Where a session's video goes: a window, or the virtual camera.
public interface IVideoSink : IDisposable
{
    bool Configure(int codec, ReadOnlySpan<byte> parameterSets, uint gen);
    void Decode(ReadOnlySpan<byte> annexB, uint gen, long pts, long received);
    void Invalidate();
}

/// A phone window's video: decoded, drawn, and each frame reported back to the session.
public sealed class PhoneStream(long id, VideoView view) : IVideoSink
{
    private readonly Decoder decoder = new();
    private readonly object counts = new();
    private int frames;
    private long decodeTicks, drawTicks;

    /// Frames shown and their average decode and draw times (ms) since the last call.
    public (int Frames, double DecodeMs, double DrawMs) TakeStats()
    {
        lock (counts)
        {
            double Ms(long ticks) => frames > 0 ? ticks * 1000.0 / System.Diagnostics.Stopwatch.Frequency / frames : 0;
            var result = (frames, Ms(decodeTicks), Ms(drawTicks));
            frames = 0;
            decodeTicks = drawTicks = 0;
            return result;
        }
    }

    public bool Configure(int codec, ReadOnlySpan<byte> parameterSets, uint gen) => decoder.Configure(codec, parameterSets, gen);

    public void Decode(ReadOnlySpan<byte> annexB, uint gen, long pts, long received)
    {
        var started = System.Diagnostics.Stopwatch.GetTimestamp();
        var pictures = decoder.Decode(annexB, gen, pts);
        var decoded = System.Diagnostics.Stopwatch.GetTimestamp();
        foreach (var picture in pictures)
        {
            view.Show(picture);
            Native.SessionFrame(id, gen, pts, received, picture.IsBlack() ? 1 : 0);
        }
        lock (counts)
        {
            frames += pictures.Count;
            decodeTicks += decoded - started;
            drawTicks += System.Diagnostics.Stopwatch.GetTimestamp() - decoded;
        }
    }

    public void Invalidate() => decoder.Invalidate();

    public void Dispose() => decoder.Dispose();
}

/// Hands each session's video (from the engine's reading threads) to its window's stream.
public static unsafe class VideoRouter
{
    private static readonly ConcurrentDictionary<long, IVideoSink> Streams = new();
    private static long lastId;

    public static void Install()
    {
        Decoder.Load();
        Native.SetVideo(&OnVideo);
    }

    public static long NextId() => Interlocked.Increment(ref lastId);

    public static void Add(long id, IVideoSink stream) => Streams[id] = stream;

    public static PhoneStream? Get(long id) => Get<PhoneStream>(id);

    public static T? Get<T>(long id) where T : class => Streams.TryGetValue(id, out var stream) ? stream as T : null;

    public static void Remove(long id)
    {
        if (Streams.TryRemove(id, out var stream)) stream.Dispose();
    }

    [UnmanagedCallersOnly]
    private static int OnVideo(long session, int kind, int codec, byte* data, int length, uint gen, long pts, long received)
    {
        try
        {
            if (!Streams.TryGetValue(session, out var stream)) return 0;
            var bytes = new ReadOnlySpan<byte>(data, length);
            switch (kind)
            {
                case 0: return stream.Configure(codec, bytes, gen) ? 1 : 0;
                case 1: stream.Decode(bytes, gen, pts, received); return 1;
                case 2: stream.Invalidate(); return 1;
            }
        }
        catch (Exception e)
        {
            Log.Error($"video: {e.GetType().Name}: {e.Message}"); // never into the engine's thread
        }
        return 0;
    }
}
