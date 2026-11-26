using FFmpeg.AutoGen;

namespace Nearside.Video;

/// A decoded picture: top-down BGRA rows.
public sealed class Picture(byte[] bgra, int width, int height)
{
    public byte[] Bgra { get; } = bgra;
    public int Width { get; } = width;
    public int Height { get; } = height;

    /// 64 points, all near black (an app blocking capture shows black), as the Mac samples it.
    public bool IsBlack()
    {
        for (var i = 0; i < 8; i++)
        {
            for (var j = 0; j < 8; j++)
            {
                int x = Width * (2 * i + 1) / 16, y = Height * (2 * j + 1) / 16;
                var p = (y * Width + x) * 4;
                if (Bgra[p] >= 24 || Bgra[p + 1] >= 24 || Bgra[p + 2] >= 24) return false;
            }
        }
        return true;
    }
}

/// H.264 or HEVC with FFmpeg: on the graphics card (D3D11VA) where it can, else on the processor.
/// A phone window shares its Direct3D device (`SharedDevice`) and keeps pictures on the card
/// (`KeepOnCard`): it draws the decoder's own textures. Otherwise each picture comes back to memory
/// and is converted to BGRA (or filtered, for the camera). Used from the session's reading thread;
/// a reconnecting window's old reader may still be decoding while the new one configures, so
/// FFmpeg's state is only touched under the lock.
public sealed unsafe class Decoder : IDisposable
{
    public const int Hevc = 0, H264 = 1; // DisplayWire.Codec

    /// False once the graphics card couldn't decode (for the rest of the run: it won't start to).
    private static bool hardwareWorks = Environment.GetEnvironmentVariable("NEARSIDE_SOFTWARE_DECODE") != "1";
    private static int loggedPath; // 1 hardware, 2 software: logged once each

    private readonly object gate = new();
    private AVCodecContext* context;
    private AVBufferRef* hardware;
    private AVPacket* packet = ffmpeg.av_packet_alloc();
    private AVFrame* frame = ffmpeg.av_frame_alloc();
    private AVFrame* copied = ffmpeg.av_frame_alloc();
    private AVFrame* converted = ffmpeg.av_frame_alloc();
    private SwsContext* scaler;
    private byte[]? pendingConfig;
    /// The BGRA picture's memory, reused frame to frame (a fresh one each frame kept the garbage
    /// collector busy, and the window stuttered when it ran).
    private byte[]? bgra;

    /// The ID3D11Device to decode on (a window's, so it can draw the textures); 0: one of FFmpeg's.
    public nint SharedDevice { get; set; }
    /// Pictures stay on the graphics card (AV_PIX_FMT_D3D11 frames); false: copied to memory.
    public bool KeepOnCard { get; set; }
    /// The parameter sets, kept to start again in software if the graphics card fails at once.
    private byte[]? config;
    private int codec;
    private bool decodedSinceConfig;
    private uint gen;

    /// Where FFmpeg's DLLs are (next to the app).
    public static void Load() => ffmpeg.RootPath = AppContext.BaseDirectory;

    /// New parameter sets: a fresh decoder for them. False if unusable.
    public bool Configure(int codec, ReadOnlySpan<byte> parameterSets, uint newGen)
    {
        lock (gate)
        {
            this.codec = codec;
            config = parameterSets.ToArray();
            gen = newGen;
            return Open(hardwareWorks) || (hardwareWorks && Open(false));
        }
    }

    /// A fresh decoder for `config`, on the graphics card if `onCard` and it has one that can.
    private bool Open(bool onCard)
    {
        FreeContext();
        var decoder = ffmpeg.avcodec_find_decoder(codec == H264 ? AVCodecID.AV_CODEC_ID_H264 : AVCodecID.AV_CODEC_ID_HEVC);
        if (decoder == null) return false;
        var c = ffmpeg.avcodec_alloc_context3(decoder);
        if (c == null) return false;
        c->flags |= ffmpeg.AV_CODEC_FLAG_LOW_DELAY;
        if (onCard)
        {
            var device = SharedDevice != 0 ? OnDevice(SharedDevice) : null;
            if (device == null) KeepOnCard = false; // FFmpeg's own device: its textures can't be drawn here
            if (device == null && ffmpeg.av_hwdevice_ctx_create(&device, AVHWDeviceType.AV_HWDEVICE_TYPE_D3D11VA, null, null, 0) < 0)
            {
                ffmpeg.avcodec_free_context(&c);
                hardwareWorks = false;
                Log.Info("video: no decoding on the graphics card here; decoding on the processor");
                return false;
            }
            // FFmpeg's default format choice then picks D3D11 surfaces.
            c->hw_device_ctx = ffmpeg.av_buffer_ref(device);
            hardware = device;
        }
        else
        {
            // Slices in parallel, never whole frames (that would hold each frame back by one).
            c->thread_count = 0;
            c->thread_type = ffmpeg.FF_THREAD_SLICE;
        }
        if (ffmpeg.avcodec_open2(c, decoder, null) != 0)
        {
            ffmpeg.avcodec_free_context(&c);
            FreeContext();
            return false;
        }
        context = c;
        pendingConfig = config; // sent ahead of the next frame
        decodedSinceConfig = false;
        return true;
    }

    /// FFmpeg's D3D11VA device on `d3d11Device` (AVD3D11VADeviceContext's first field is the
    /// device; FFmpeg fills in the rest and releases the reference it's given). Null if refused.
    private static AVBufferRef* OnDevice(nint d3d11Device)
    {
        var buffer = ffmpeg.av_hwdevice_ctx_alloc(AVHWDeviceType.AV_HWDEVICE_TYPE_D3D11VA);
        if (buffer == null) return null;
        var context = (AVHWDeviceContext*)buffer->data;
        System.Runtime.InteropServices.Marshal.AddRef(d3d11Device);
        *(nint*)context->hwctx = d3d11Device;
        if (ffmpeg.av_hwdevice_ctx_init(buffer) < 0)
        {
            ffmpeg.av_buffer_unref(&buffer); // releases the device reference too
            return null;
        }
        return buffer;
    }

    /// Each decoded frame in memory (valid during the call, under the decoder's lock).
    public void DecodeFrames(ReadOnlySpan<byte> annexB, uint frameGen, long pts, Action<nint> each)
    {
        lock (gate)
        {
            if (frameGen != gen || context == null) return;
            if (DecodeOnce(annexB, pts, each) || hardware == null || decodedSinceConfig) return;
            // The graphics card failed on the first picture (a keyframe, right after the
            // parameter sets): the processor from now on, starting with this same packet.
            hardwareWorks = false;
            Log.Info("video: the graphics card couldn't decode this; decoding on the processor");
            if (Open(false)) DecodeOnce(annexB, pts, each);
        }
    }

    /// False if FFmpeg refused the packet or a picture couldn't come back from the graphics card.
    private bool DecodeOnce(ReadOnlySpan<byte> annexB, long pts, Action<nint> each)
    {
        var length = annexB.Length + (pendingConfig?.Length ?? 0);
        if (ffmpeg.av_new_packet(packet, length) != 0) return true; // out of memory: not the card's fault
        var target = new Span<byte>(packet->data, length);
        var withConfig = pendingConfig;
        if (pendingConfig != null)
        {
            pendingConfig.CopyTo(target);
            target = target[pendingConfig.Length..];
            pendingConfig = null;
        }
        annexB.CopyTo(target);
        packet->pts = pts;
        var sent = ffmpeg.avcodec_send_packet(context, packet);
        ffmpeg.av_packet_unref(packet);
        if (sent != 0)
        {
            pendingConfig ??= withConfig; // a retry sends them again
            return false;
        }
        int received;
        while ((received = ffmpeg.avcodec_receive_frame(context, frame)) == 0)
        {
            var picture = frame;
            if (frame->hw_frames_ctx != null && !KeepOnCard)
            {
                ffmpeg.av_frame_unref(copied);
                if (ffmpeg.av_hwframe_transfer_data(copied, frame, 0) < 0)
                {
                    ffmpeg.av_frame_unref(frame);
                    return false;
                }
                copied->pts = frame->pts;
                picture = copied;
            }
            LogPath(picture != frame);
            decodedSinceConfig = true;
            each((nint)picture);
            ffmpeg.av_frame_unref(frame);
        }
        // EAGAIN: wants more input; anything else before the first picture counts as a failure.
        return received == ffmpeg.AVERROR(ffmpeg.EAGAIN) || received == ffmpeg.AVERROR_EOF || decodedSinceConfig;
    }

    private static void LogPath(bool onCard)
    {
        var path = onCard ? 1 : 2;
        if (Interlocked.Exchange(ref loggedPath, path) != path)
        {
            Log.Info(onCard ? "video: decoding on the graphics card (D3D11VA)" : "video: decoding on the processor");
        }
    }

    /// A frame in memory as BGRA, in memory reused by the next call (shown before then).
    public Picture? Convert(AVFrame* frame)
    {
        int w = frame->width, h = frame->height;
        // Bilinear: the colour planes are half size, and point sampling left blocky edges.
        scaler = ffmpeg.sws_getCachedContext(scaler, w, h, (AVPixelFormat)frame->format, w, h, AVPixelFormat.AV_PIX_FMT_BGRA,
            (int)SwsFlags.SWS_BILINEAR, null, null, null);
        ffmpeg.av_frame_unref(converted);
        converted->width = w;
        converted->height = h;
        converted->format = (int)AVPixelFormat.AV_PIX_FMT_BGRA;
        if (scaler == null || ffmpeg.av_frame_get_buffer(converted, 0) != 0 || ffmpeg.sws_scale_frame(scaler, converted, frame) < 0) return null;
        if (bgra?.Length != w * h * 4) bgra = new byte[w * h * 4];
        var stride = converted->linesize[0];
        fixed (byte* output = bgra)
        {
            for (var y = 0; y < h; y++) Buffer.MemoryCopy(converted->data[0] + y * stride, output + y * w * 4, w * 4, w * 4);
        }
        return new Picture(bgra, w, h);
    }

    public void Invalidate()
    {
        lock (gate) FreeContext();
    }

    private void FreeContext()
    {
        if (context != null)
        {
            var c = context;
            ffmpeg.avcodec_free_context(&c);
            context = null;
        }
        if (hardware != null)
        {
            var h = hardware;
            ffmpeg.av_buffer_unref(&h);
            hardware = null;
        }
        if (scaler != null)
        {
            ffmpeg.sws_freeContext(scaler);
            scaler = null;
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            FreeContext();
            var p = packet;
            ffmpeg.av_packet_free(&p);
            var f = frame;
            ffmpeg.av_frame_free(&f);
            var t = copied;
            ffmpeg.av_frame_free(&t);
            var c = converted;
            ffmpeg.av_frame_free(&c);
            packet = null;
            frame = null;
            copied = null;
            converted = null;
        }
    }
}
