using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using FFmpeg.AutoGen;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using Nearside.Engine;

namespace Nearside.Audio;

/// Opus packets → interleaved float samples, with FFmpeg's own Opus decoder.
public sealed unsafe class OpusDecoder : IDisposable
{
    private AVCodecContext* context;
    private AVPacket* packet = ffmpeg.av_packet_alloc();
    private AVFrame* frame = ffmpeg.av_frame_alloc();
    public int Channels { get; }

    public OpusDecoder(int sampleRate, int channels)
    {
        Channels = channels;
        var codec = ffmpeg.avcodec_find_decoder(AVCodecID.AV_CODEC_ID_OPUS);
        if (codec == null) return;
        var c = ffmpeg.avcodec_alloc_context3(codec);
        c->sample_rate = sampleRate;
        ffmpeg.av_channel_layout_default(&c->ch_layout, channels);
        if (ffmpeg.avcodec_open2(c, codec, null) != 0)
        {
            ffmpeg.avcodec_free_context(&c);
            return;
        }
        context = c;
    }

    /// Samples written to `output` (frames × channels), or 0.
    public int Decode(ReadOnlySpan<byte> opus, Span<float> output)
    {
        if (context == null || opus.IsEmpty || ffmpeg.av_new_packet(packet, opus.Length) != 0) return 0;
        opus.CopyTo(new Span<byte>(packet->data, opus.Length));
        var sent = ffmpeg.avcodec_send_packet(context, packet);
        ffmpeg.av_packet_unref(packet);
        if (sent != 0) return 0;
        var written = 0;
        while (ffmpeg.avcodec_receive_frame(context, frame) == 0)
        {
            var frames = Math.Min(frame->nb_samples, (output.Length - written) / Channels);
            var planar = (AVSampleFormat)frame->format == AVSampleFormat.AV_SAMPLE_FMT_FLTP;
            for (var i = 0; i < frames; i++)
            {
                for (var ch = 0; ch < Channels; ch++)
                {
                    output[written + i * Channels + ch] = planar
                        ? ((float*)frame->extended_data[ch])[i]
                        : ((float*)frame->extended_data[0])[i * Channels + ch];
                }
            }
            written += frames * Channels;
            ffmpeg.av_frame_unref(frame);
        }
        return written;
    }

    public void Dispose()
    {
        if (context != null)
        {
            var c = context;
            ffmpeg.avcodec_free_context(&c);
            context = null;
        }
        var p = packet;
        ffmpeg.av_packet_free(&p);
        var f = frame;
        ffmpeg.av_frame_free(&f);
    }
}

/// A window's sound playing on this PC's default output: WASAPI pulls from the engine's jitter
/// buffer (nearside_audio_read), which the decoded packets fill.
public sealed unsafe class WindowSound : IWaveProvider, IDisposable
{
    private readonly long session;
    private readonly OpusDecoder decoder;
    private readonly object decoding = new();
    private WasapiOut? output;
    public WaveFormat WaveFormat { get; }

    public WindowSound(long session, int sampleRate, int channels)
    {
        this.session = session;
        decoder = new OpusDecoder(sampleRate, channels);
        WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(sampleRate, channels);
        // Made on a pool thread: COM wants an apartment, and the engine's threads have none.
        Task.Run(() =>
        {
            try
            {
                var o = new WasapiOut(AudioClientShareMode.Shared, useEventSync: true, latency: 30);
                o.Init(this);
                o.Play();
                output = o;
                Log.Info($"sound: {sampleRate} Hz, {channels} channels, playing");
            }
            catch (Exception e)
            {
                Log.Error($"sound: no output ({e.GetType().Name})");
            }
        }).Wait();
    }

    public int Decode(ReadOnlySpan<byte> opus, Span<float> into)
    {
        lock (decoding) return decoder.Decode(opus, into);
    }

    /// WASAPI's thread: the next stretch of sound.
    public int Read(byte[] buffer, int offset, int count)
    {
        var channels = WaveFormat.Channels;
        var frames = count / 4 / channels;
        fixed (byte* bytes = &buffer[offset]) Native.AudioRead(session, (float*)bytes, frames, channels);
        return frames * channels * 4;
    }

    public void Dispose()
    {
        output?.Stop();
        output?.Dispose();
        lock (decoding) decoder.Dispose();
    }
}

/// Hands each session's sound (from the engine's threads) to its WindowSound.
public static unsafe class SoundRouter
{
    private static readonly ConcurrentDictionary<long, WindowSound> Sounds = new();

    public static void Install() => Native.SetAudio(&OnAudio);

    [UnmanagedCallersOnly]
    private static int OnAudio(long session, int kind, byte* data, int length, int sampleRate, int channels, float* output, int capacity)
    {
        try
        {
            switch (kind)
            {
                case 0:
                    if (Sounds.TryRemove(session, out var old)) old.Dispose();
                    Sounds[session] = new WindowSound(session, sampleRate, channels);
                    return 1;
                case 1:
                    return Sounds.TryGetValue(session, out var sound)
                        ? sound.Decode(new ReadOnlySpan<byte>(data, length), new Span<float>(output, capacity))
                        : 0;
                case 3:
                    if (Sounds.TryRemove(session, out var stopped)) stopped.Dispose();
                    return 1;
            }
        }
        catch (Exception e)
        {
            Log.Error($"sound: {e.GetType().Name}: {e.Message}");
        }
        return 0;
    }
}
