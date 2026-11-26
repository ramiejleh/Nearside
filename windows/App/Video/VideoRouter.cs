using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using FFmpeg.AutoGen;
using Nearside.Engine;
using Vortice.DXGI;

namespace Nearside.Video;

/// Where a session's video goes: a window, or the virtual camera.
public interface IVideoSink : IDisposable
{
    bool Configure(int codec, ReadOnlySpan<byte> parameterSets, uint gen);
    void Decode(ReadOnlySpan<byte> annexB, uint gen, long pts, long received);
    void Invalidate();
}

/// A phone window's video: decoded, drawn, and each frame reported back to the session. Decoded on
/// the window's own graphics device and drawn from there, when it can; else copied through memory.
public sealed unsafe class PhoneStream : IVideoSink
{
    private readonly long id;
    private readonly VideoView view;
    private readonly Decoder decoder = new();

    public PhoneStream(long id, VideoView view)
    {
        this.id = id;
        this.view = view;
        decoder.SharedDevice = view.DevicePointer;
        decoder.KeepOnCard = decoder.SharedDevice != 0;
    }
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
        long drawing = 0;
        var shown = 0;
        decoder.DecodeFrames(annexB, gen, pts, f =>
        {
            var frame = (AVFrame*)f;
            var drawStart = System.Diagnostics.Stopwatch.GetTimestamp();
            bool black;
            if (frame->format == (int)AVPixelFormat.AV_PIX_FMT_D3D11)
            {
                if (!view.ShowTexture((nint)frame->data[0], (int)(nint)frame->data[1], frame->width, frame->height, Colors(frame)))
                {
                    decoder.KeepOnCard = false; // from the next picture on, through memory
                    return;
                }
                black = view.LastBlack;
            }
            else if (decoder.Convert(frame) is { } picture)
            {
                view.Show(picture);
                black = picture.IsBlack();
            }
            else return;
            drawing += System.Diagnostics.Stopwatch.GetTimestamp() - drawStart;
            shown++;
            Native.SessionFrame(id, gen, pts, received, black ? 1 : 0);
        });
        lock (counts)
        {
            frames += shown;
            decodeTicks += System.Diagnostics.Stopwatch.GetTimestamp() - started - drawing;
            drawTicks += drawing;
        }
    }

    /// The picture's colours as the phone's encoder marked them; BT.709 when it didn't say.
    private static ColorSpaceType Colors(AVFrame* frame)
    {
        var sd = frame->colorspace is AVColorSpace.AVCOL_SPC_BT470BG or AVColorSpace.AVCOL_SPC_SMPTE170M;
        return frame->color_range == AVColorRange.AVCOL_RANGE_JPEG
            ? (sd ? ColorSpaceType.YcbcrFullG22LeftP601 : ColorSpaceType.YcbcrFullG22LeftP709)
            : (sd ? ColorSpaceType.YcbcrStudioG22LeftP601 : ColorSpaceType.YcbcrStudioG22LeftP709);
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
