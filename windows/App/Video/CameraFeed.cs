using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using FFmpeg.AutoGen;
using Microsoft.UI.Dispatching;
using Nearside.Engine;

namespace Nearside.Video;

/// The phone's camera as "Nearside Camera" (NearsideCamera.dll, windows/Camera). The camera exists
/// while Nearside runs; when an app starts it, Windows' camera service (LocalService) loads the
/// DLL, which connects to this pipe: only then is the phone's camera turned on, and it's turned
/// off when the app stops. Frames go upright, cut to 16:9 and scaled to 1920x1080 NV12.
///
/// Both ends check the other: this pipe only serves a client running as LocalService (the camera
/// service), and the DLL only takes frames from a server whose program is in its own folder.
public sealed unsafe partial class CameraFeed : IDisposable
{
    public const int Width = 1920, Height = 1080;
    private const int FrameBytes = Width * Height * 3 / 2;
    private const uint Magic = 0x4643534E; // "NSCF"
    private const string PipeName = "NearsideCamera";
    private const string FrontKey = "WebcamFront";

    private readonly DispatcherQueue ui;
    private nint camera;
    private Thread? server;
    private volatile bool running;
    private NamedPipeServerStream? pipe;
    private long sessionId;

    [LibraryImport("NearsideCamera.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int NearsideCameraCreate(string name, out nint camera);

    [LibraryImport("NearsideCamera.dll")]
    private static partial int NearsideCameraRemove(nint camera);

    /// The phone's front camera (else the back one, the better one).
    public static bool Front
    {
        get => AppSettings.Get(FrontKey) == "1";
        set => AppSettings.Set(FrontKey, value ? "1" : "0");
    }

    /// --camera-test: a generated picture instead of the phone's camera (to test the camera
    /// itself without turning on the phone's), turned as a phone held upright would be.
    public bool TestPattern { get; init; }

    public CameraFeed(DispatcherQueue ui)
    {
        this.ui = ui;
        EngineHost.Event += OnEvent;
    }

    /// Makes the camera appear to this user's apps (if the installer put the DLL in place).
    public void Start()
    {
        if (!File.Exists(Path.Combine(AppContext.BaseDirectory, "NearsideCamera.dll")))
        {
            Log.Info("camera: not installed");
            return;
        }
        var hr = NearsideCameraCreate("Nearside Camera", out camera);
        if (hr != 0)
        {
            Log.Error($"camera: couldn't be created (0x{hr:X8})");
            return;
        }
        running = true;
        server = new Thread(Serve) { IsBackground = true, Name = "Nearside camera pipe" };
        server.Start();
        Log.Info("camera: ready");
    }

    /// One client at a time: the camera service, while an app uses the camera.
    private void Serve()
    {
        while (running)
        {
            try
            {
                using var p = NamedPipeServerStreamAcl.Create(PipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                    PipeOptions.FirstPipeInstance | PipeOptions.Asynchronous, 0, FrameBytes + 16, Security()); // asynchronous: the waiting read mustn't hold up the writes
                pipe = p;
                p.WaitForConnection();
                if (!IsCameraService(p))
                {
                    Log.Error("camera: a client that isn't Windows' camera service was refused");
                    continue;
                }
                var hello = new byte[8];
                if (p.ReadAtLeast(hello, 8, throwOnEndOfStream: false) < 8 || BitConverter.ToUInt32(hello, 0) != Magic) continue;
                var id = VideoRouter.NextId();
                var stream = new CameraStream(this, p);
                VideoRouter.Add(id, stream);
                Interlocked.Exchange(ref sessionId, id);
                var front = Front;
                if (TestPattern) StartPattern(stream, p);
                else ui.TryEnqueue(() => EngineHost.Command("cameraStart", new { id, front }));
                Log.Info($"camera: an app started it; {(TestPattern ? "test picture" : "phone camera")} on");
                // Until the camera service lets go (the app stopped the camera).
                var buffer = new byte[64];
                while (running && p.IsConnected && p.Read(buffer, 0, buffer.Length) > 0) { }
                Interlocked.CompareExchange(ref sessionId, 0, id);
                ui.TryEnqueue(() => EngineHost.Command("cameraStop"));
                VideoRouter.Remove(id);
                Log.Info("camera: stopped; phone camera off");
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or ObjectDisposedException)
            {
                // Taken by something else, or closing: look again shortly.
                if (running) Thread.Sleep(1000);
            }
            finally
            {
                pipe = null;
            }
        }
    }

    /// A 1920x1440 picture (as the phone's sensor sends) with bars, turned 90° (held upright).
    private void StartPattern(CameraStream stream, NamedPipeServerStream p)
    {
        stream.Rotation = 90;
        new Thread(() =>
        {
            var frame = ffmpeg.av_frame_alloc();
            frame->width = 1920;
            frame->height = 1440;
            frame->format = (int)AVPixelFormat.AV_PIX_FMT_YUV420P;
            ffmpeg.av_frame_get_buffer(frame, 0);
            for (var n = 0; running && p.IsConnected; n++)
            {
                for (var y = 0; y < 1440; y++)
                {
                    for (var x = 0; x < 1920; x++) frame->data[0][y * frame->linesize[0] + x] = (byte)(x / 240 * 32 + (y < 160 ? 0 : 0));
                }
                // The top rows white, so "up" shows; a moving block, so motion shows.
                for (var y = 0; y < 120; y++) for (var x = 0; x < 1920; x++) frame->data[0][y * frame->linesize[0] + x] = 235;
                var bx = n * 16 % 1800;
                for (var y = 600; y < 840; y++) for (var x = bx; x < bx + 120; x++) frame->data[0][y * frame->linesize[0] + x] = 16;
                for (var y = 0; y < 720; y++)
                {
                    for (var x = 0; x < 960; x++)
                    {
                        frame->data[1][y * frame->linesize[1] + x] = (byte)(64 + x / 8);
                        frame->data[2][y * frame->linesize[2] + x] = (byte)(192 - y / 6);
                    }
                }
                stream.Push(frame);
                Thread.Sleep(33);
            }
            ffmpeg.av_frame_free(&frame);
        }) { IsBackground = true, Name = "Nearside camera test" }.Start();
    }

    /// This user, and the camera service (LocalService): nobody else may open the pipe.
    private static PipeSecurity Security()
    {
        var security = new PipeSecurity();
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalServiceSid, null), PipeAccessRights.ReadWrite, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User!, PipeAccessRights.FullControl, AccessControlType.Allow));
        return security;
    }

    /// The client runs as LocalService, as Windows' camera service does (an app of this user can't).
    private static bool IsCameraService(NamedPipeServerStream p)
    {
        SecurityIdentifier? user = null;
        try
        {
            p.RunAsClient(() => user = WindowsIdentity.GetCurrent(TokenAccessLevels.Query).User);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
        return user != null && user.IsWellKnown(WellKnownSidType.LocalServiceSid);
    }

    private void OnEvent(string name, System.Text.Json.JsonElement e)
    {
        if (name == "cameraRotation" && VideoRouter.Get<CameraStream>(e.GetProperty("id").GetInt64()) is { } stream)
        {
            stream.Rotation = e.GetProperty("degrees").GetInt32();
        }
        else if (name == "cameraEnded" && e.GetProperty("id").GetInt64() == Interlocked.Read(ref sessionId))
        {
            // Stopped on the phone (or it went away): the camera shows its dark frame until an app
            // starts it again; the phone's choice is honoured.
            Log.Info("camera: the phone's camera stopped");
        }
    }

    public void Dispose()
    {
        running = false;
        try
        {
            pipe?.Dispose();
        }
        catch (IOException)
        {
        }
        if (camera != 0) NearsideCameraRemove(camera);
        camera = 0;
    }

    /// Writes a frame to the camera service (any thread; one at a time).
    private readonly object writing = new();

    internal void Send(NamedPipeServerStream p, byte[] nv12)
    {
        lock (writing)
        {
            try
            {
                Span<uint> header = [Magic, Width, Height, FrameBytes];
                p.Write(MemoryMarshal.AsBytes(header));
                p.Write(nv12, 0, FrameBytes);
            }
            catch (Exception e) when (e is IOException or ObjectDisposedException or InvalidOperationException)
            {
                // The camera service let go: the serving loop notices.
            }
        }
    }
}

/// The phone camera's video: decoded, turned upright, the middle 16:9 cut and scaled to
/// 1920x1080 NV12 (one FFmpeg filter chain, rebuilt when the picture turns), then sent.
public sealed unsafe class CameraStream(CameraFeed feed, NamedPipeServerStream pipe) : IVideoSink
{
    private readonly Decoder decoder = new();
    private readonly byte[] nv12 = new byte[CameraFeed.Width * CameraFeed.Height * 3 / 2];
    private AVFilterGraph* graph;
    private AVFilterContext* source, sink;
    private (int Width, int Height, int Format, int Rotation) built;
    private AVFrame* filtered = ffmpeg.av_frame_alloc();
    private volatile int rotation;

    public int Rotation { get => rotation; set => rotation = value; }

    public bool Configure(int codec, ReadOnlySpan<byte> parameterSets, uint gen) => decoder.Configure(codec, parameterSets, gen);

    public void Decode(ReadOnlySpan<byte> annexB, uint gen, long pts, long received) =>
        decoder.DecodeFrames(annexB, gen, pts, frame => Filter((AVFrame*)frame));

    public void Invalidate() => decoder.Invalidate();

    private readonly object filtering = new();
    private int sent;

    /// A picture from elsewhere than the phone (the test pattern).
    public void Push(AVFrame* frame)
    {
        lock (filtering) Filter(frame);
    }

    private void Filter(AVFrame* frame)
    {
        var want = (frame->width, frame->height, frame->format, rotation);
        if (graph == null || want != built)
        {
            Build(frame);
            built = want;
        }
        if (graph == null || ffmpeg.av_buffersrc_add_frame_flags(source, frame, 8 /* AV_BUFFERSRC_FLAG_KEEP_REF: the decoder keeps its frame */) < 0) return;
        while (ffmpeg.av_buffersink_get_frame(sink, filtered) >= 0)
        {
            // Tightly packed: Y rows, then the interleaved UV rows.
            fixed (byte* outp = nv12)
            {
                for (var y = 0; y < CameraFeed.Height; y++)
                {
                    Buffer.MemoryCopy(filtered->data[0] + y * filtered->linesize[0], outp + y * CameraFeed.Width, CameraFeed.Width, CameraFeed.Width);
                }
                var uv = outp + CameraFeed.Width * CameraFeed.Height;
                for (var y = 0; y < CameraFeed.Height / 2; y++)
                {
                    Buffer.MemoryCopy(filtered->data[1] + y * filtered->linesize[1], uv + y * CameraFeed.Width, CameraFeed.Width, CameraFeed.Width);
                }
            }
            ffmpeg.av_frame_unref(filtered);
            feed.Send(pipe, nv12);
            if (++sent % 300 == 1) Log.Info($"camera: {sent} pictures sent");
        }
    }

    private void Build(AVFrame* frame)
    {
        Free();
        var turn = rotation switch
        {
            90 => "transpose=clock,",
            180 => "hflip,vflip,",
            270 => "transpose=cclock,",
            _ => "",
        };
        var chain = $"{turn}crop=w='min(iw,ih*16/9)':h='min(ih,iw*9/16)',scale={CameraFeed.Width}:{CameraFeed.Height},format=nv12";
        graph = ffmpeg.avfilter_graph_alloc();
        AVFilterContext* src, dst;
        var args = $"video_size={frame->width}x{frame->height}:pix_fmt={frame->format}:time_base=1/1000000:pixel_aspect=1/1";
        if (ffmpeg.avfilter_graph_create_filter(&src, ffmpeg.avfilter_get_by_name("buffer"), "in", args, null, graph) < 0
            || ffmpeg.avfilter_graph_create_filter(&dst, ffmpeg.avfilter_get_by_name("buffersink"), "out", null, null, graph) < 0)
        {
            Free();
            return;
        }
        var outputs = ffmpeg.avfilter_inout_alloc();
        var inputs = ffmpeg.avfilter_inout_alloc();
        outputs->name = ffmpeg.av_strdup("in");
        outputs->filter_ctx = src;
        inputs->name = ffmpeg.av_strdup("out");
        inputs->filter_ctx = dst;
        var ok = ffmpeg.avfilter_graph_parse_ptr(graph, chain, &inputs, &outputs, null) >= 0 && ffmpeg.avfilter_graph_config(graph, null) >= 0;
        ffmpeg.avfilter_inout_free(&inputs);
        ffmpeg.avfilter_inout_free(&outputs);
        if (!ok)
        {
            Log.Error("camera: the picture's filters couldn't be set up");
            Free();
            return;
        }
        source = src;
        sink = dst;
    }

    private void Free()
    {
        if (graph != null)
        {
            var g = graph;
            ffmpeg.avfilter_graph_free(&g);
        }
        graph = null;
        source = sink = null;
    }

    public void Dispose()
    {
        decoder.Dispose(); // waits for a decode underway (its lock), so the graph is free to go
        Free();
        var f = filtered;
        ffmpeg.av_frame_free(&f);
        filtered = null;
    }
}
