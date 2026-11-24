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

/// H.264 or HEVC with FFmpeg's software decoder, frames converted to BGRA. Used from the session's
/// reading thread; a reconnecting window's old reader may still be decoding while the new one
/// configures, so FFmpeg's state is only touched under the lock.
public sealed unsafe class Decoder : IDisposable
{
    public const int Hevc = 0, H264 = 1; // DisplayWire.Codec

    private readonly object gate = new();
    private AVCodecContext* context;
    private AVPacket* packet = ffmpeg.av_packet_alloc();
    private AVFrame* frame = ffmpeg.av_frame_alloc();
    private AVFrame* converted = ffmpeg.av_frame_alloc();
    private SwsContext* scaler;
    private byte[]? pendingConfig;
    private uint gen;

    /// Where FFmpeg's DLLs are (next to the app).
    public static void Load() => ffmpeg.RootPath = AppContext.BaseDirectory;

    /// New parameter sets: a fresh decoder for them. False if unusable.
    public bool Configure(int codec, ReadOnlySpan<byte> parameterSets, uint newGen)
    {
        lock (gate)
        {
            FreeContext();
            var decoder = ffmpeg.avcodec_find_decoder(codec == H264 ? AVCodecID.AV_CODEC_ID_H264 : AVCodecID.AV_CODEC_ID_HEVC);
            if (decoder == null) return false;
            var c = ffmpeg.avcodec_alloc_context3(decoder);
            if (c == null) return false;
            c->flags |= ffmpeg.AV_CODEC_FLAG_LOW_DELAY;
            // Slices in parallel, never whole frames (that would hold each frame back by one).
            c->thread_count = 0;
            c->thread_type = ffmpeg.FF_THREAD_SLICE;
            if (ffmpeg.avcodec_open2(c, decoder, null) != 0)
            {
                ffmpeg.avcodec_free_context(&c);
                return false;
            }
            context = c;
            gen = newGen;
            pendingConfig = parameterSets.ToArray(); // sent ahead of the next frame
            return true;
        }
    }

    /// The pictures in one access unit (usually one).
    public List<Picture> Decode(ReadOnlySpan<byte> annexB, uint frameGen, long pts)
    {
        var pictures = new List<Picture>(1);
        lock (gate)
        {
            if (frameGen != gen || context == null) return pictures;
            var length = annexB.Length + (pendingConfig?.Length ?? 0);
            if (ffmpeg.av_new_packet(packet, length) != 0) return pictures;
            var target = new Span<byte>(packet->data, length);
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
            if (sent != 0) return pictures;
            while (ffmpeg.avcodec_receive_frame(context, frame) == 0)
            {
                if (Convert() is { } picture) pictures.Add(picture);
                ffmpeg.av_frame_unref(frame);
            }
        }
        return pictures;
    }

    private Picture? Convert()
    {
        int w = frame->width, h = frame->height;
        scaler = ffmpeg.sws_getCachedContext(scaler, w, h, (AVPixelFormat)frame->format, w, h, AVPixelFormat.AV_PIX_FMT_BGRA,
            (int)SwsFlags.SWS_POINT, null, null, null);
        ffmpeg.av_frame_unref(converted);
        converted->width = w;
        converted->height = h;
        converted->format = (int)AVPixelFormat.AV_PIX_FMT_BGRA;
        if (scaler == null || ffmpeg.av_frame_get_buffer(converted, 0) != 0 || ffmpeg.sws_scale_frame(scaler, converted, frame) < 0) return null;
        var bgra = new byte[w * h * 4];
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
            var c = converted;
            ffmpeg.av_frame_free(&c);
            packet = null;
            frame = null;
            converted = null;
        }
    }
}
