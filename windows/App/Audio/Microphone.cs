using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using Nearside.Engine;

namespace Nearside.Audio;

/// This PC's default microphone, while a phone app records or a call is talked here: captured with
/// WASAPI in the device's own format, then mixed to mono, resampled to 48 kHz and sent as 20 ms
/// chunks of 16-bit samples.
public sealed unsafe class MicCapture : IDisposable
{
    private const int Rate = 48_000, ChunkSamples = Rate / 50;
    private readonly long id;
    private readonly WasapiCapture capture;
    private readonly BufferedWaveProvider incoming;
    private readonly ISampleProvider converted;
    private readonly float[] floats = new float[ChunkSamples];
    private readonly short[] chunk = new short[ChunkSamples];

    /// Throws if there's no microphone, or Windows' privacy settings keep apps from it.
    public MicCapture(long id)
    {
        this.id = id;
        capture = new WasapiCapture(WasapiCapture.GetDefaultCaptureDevice(), useEventSync: true, audioBufferMillisecondsLength: 20);
        incoming = new BufferedWaveProvider(capture.WaveFormat) { DiscardOnBufferOverflow = true, BufferDuration = TimeSpan.FromSeconds(1), ReadFully = false };
        ISampleProvider samples = incoming.ToSampleProvider();
        if (samples.WaveFormat.Channels > 1) samples = new MonoMixer(samples);
        if (samples.WaveFormat.SampleRate != Rate) samples = new WdlResamplingSampleProvider(samples, Rate);
        converted = samples;
        capture.DataAvailable += (_, e) =>
        {
            incoming.AddSamples(e.Buffer, 0, e.BytesRecorded);
            Pump();
        };
        capture.StartRecording();
    }

    private readonly float[] read = new float[ChunkSamples * 4];
    private int filled;

    /// Collects samples and sends each whole 20 ms chunk.
    private void Pump()
    {
        int n;
        while ((n = converted.Read(read, 0, read.Length)) > 0)
        {
            for (var i = 0; i < n; i++)
            {
                floats[filled++] = read[i];
                if (filled < ChunkSamples) continue;
                for (var j = 0; j < ChunkSamples; j++) chunk[j] = (short)Math.Clamp(floats[j] * 32767f, short.MinValue, short.MaxValue);
                fixed (short* p = chunk) Native.MicChunk(id, p, ChunkSamples);
                filled = 0;
            }
        }
    }

    public void Dispose()
    {
        try
        {
            capture.StopRecording();
        }
        catch (Exception e) when (e is COMException or InvalidOperationException)
        {
            // Already stopped (the device went away).
        }
        capture.Dispose();
    }

    /// Averages all channels into one.
    private sealed class MonoMixer(ISampleProvider source) : ISampleProvider
    {
        private float[] buffer = [];
        public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(source.WaveFormat.SampleRate, 1);

        public int Read(float[] output, int offset, int count)
        {
            var channels = source.WaveFormat.Channels;
            if (buffer.Length < count * channels) buffer = new float[count * channels];
            var read = source.Read(buffer, 0, count * channels) / channels;
            for (var i = 0; i < read; i++)
            {
                float sum = 0;
                for (var c = 0; c < channels; c++) sum += buffer[i * channels + c];
                output[offset + i] = sum / channels;
            }
            return read;
        }
    }
}

/// Starts and stops captures for the engine's microphones.
public static unsafe class MicRouter
{
    private static readonly ConcurrentDictionary<long, MicCapture> Captures = new();

    public static void Install() => Native.SetMic(&OnMic);

    [UnmanagedCallersOnly]
    private static int OnMic(long id, int kind)
    {
        try
        {
            if (kind == 0)
            {
                // Made on a pool thread: COM wants an apartment, and the engine's threads have none.
                var capture = Task.Run(() => new MicCapture(id)).GetAwaiter().GetResult();
                Captures[id] = capture;
                Log.Info("microphone: on");
                return 1;
            }
            if (Captures.TryRemove(id, out var stopped))
            {
                stopped.Dispose();
                Log.Info("microphone: off");
            }
            return 1;
        }
        catch (Exception e)
        {
            Log.Error($"microphone: can't start ({e.GetType().Name})"); // the phone's microphone is used instead
            return 0;
        }
    }
}
