using System.Numerics;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml.Controls;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace Nearside.Video;

/// Draws pictures into a SwapChainPanel with Direct3D 11, into a swap chain the size of the video,
/// which the compositor scales to fit the panel (keeping its shape). Decoded textures (on this
/// view's device, see `DevicePointer`) go through the graphics card's video processor, which
/// converts their colours into the swap chain: nothing comes back to memory. BGRA pictures (the
/// processor-decoded fallback) are copied in. Pictures come from the decoding thread; layout
/// changes from the UI thread; both under one lock.
public sealed unsafe class VideoView : IDisposable
{
    private readonly SwapChainPanel panel;
    private readonly object gate = new();
    private ID3D11Device? device;
    private ID3D11DeviceContext? context;
    private IDXGISwapChain2? swapChain;
    private int videoWidth, videoHeight;
    /// The swap chain's height: the picture's less the crop when it was made.
    private int chainHeight;
    /// Rows at the top of each picture not shown (the phone's status bar).
    private int crop;
    private double panelWidth, panelHeight;
    /// The video processor and what it was made for (input and output sizes).
    private ID3D11VideoDevice? videoDevice;
    private ID3D11VideoContext1? videoContext;
    private ID3D11VideoProcessorEnumerator? processorKinds;
    private ID3D11VideoProcessor? processor;
    private (int W, int H, int OutH) processorSize;
    /// Views of the decoder's texture slices and of the swap chain's buffers, made once each.
    private readonly Dictionary<(nint Texture, int Slice), ID3D11VideoProcessorInputView> inputs = [];
    private readonly Dictionary<nint, ID3D11VideoProcessorOutputView> outputs = [];
    private ColorSpaceType inputColors = (ColorSpaceType)(-1);
    /// A 16×16 copy now and then, to tell an all-black picture (an app blocking capture).
    private ID3D11Texture2D? probe, probeRead;
    private ID3D11VideoProcessorOutputView? probeView;
    private long lastProbe;

    /// Whether the last picture drawn from a texture was all black (checked a few times a second).
    public bool LastBlack { get; private set; }

    public VideoView(SwapChainPanel panel)
    {
        this.panel = panel;
        // A GPU with video support if there is one (to draw decoded textures), else one without,
        // else Windows' software renderer (a VM).
        var levels = new[] { FeatureLevel.Level_11_0, FeatureLevel.Level_10_0 };
        if (D3D11.D3D11CreateDevice(null, DriverType.Hardware, DeviceCreationFlags.BgraSupport | DeviceCreationFlags.VideoSupport, levels, out device, out context).Success)
        {
            videoDevice = device!.QueryInterfaceOrNull<ID3D11VideoDevice>();
            videoContext = context!.QueryInterfaceOrNull<ID3D11VideoContext1>();
            // FFmpeg decodes on this device while the window draws: Direct3D guards its context.
            using var guard = device.QueryInterfaceOrNull<ID3D11Multithread>();
            guard?.SetMultithreadProtected(true);
        }
        else if (D3D11.D3D11CreateDevice(null, DriverType.Hardware, DeviceCreationFlags.BgraSupport, levels, out device, out context).Failure)
        {
            D3D11.D3D11CreateDevice(null, DriverType.Warp, DeviceCreationFlags.BgraSupport, levels, out device, out context).CheckError();
        }
        panel.SizeChanged += (_, e) => Layout(e.NewSize.Width, e.NewSize.Height);
    }

    /// The device to decode on, when this view can draw its textures; else 0.
    public nint DevicePointer => videoDevice != null && videoContext != null ? device!.NativePointer : 0;

    public int Crop
    {
        set
        {
            lock (gate) crop = Math.Max(0, value);
        }
    }

    /// Where the picture is within the panel (DIPs): for mapping the pointer onto it.
    public (double X, double Y, double Width, double Height) PictureRect
    {
        get
        {
            lock (gate) return Fit(videoWidth, videoHeight - crop);
        }
    }

    public void Show(Picture picture)
    {
        lock (gate)
        {
            if (device == null || context == null) return;
            DropOutputs(); // copied into directly now (views of the buffers would block a resize)
            var shownHeight = picture.Height - crop;
            if (shownHeight <= 0) return;
            if (swapChain == null || picture.Width != videoWidth || picture.Height != videoHeight || shownHeight != chainHeight)
            {
                videoWidth = picture.Width;
                videoHeight = picture.Height;
                chainHeight = shownHeight;
                Recreate(picture.Width, shownHeight);
            }
            using var back = swapChain!.GetBuffer<ID3D11Texture2D>(0);
            fixed (byte* bgra = picture.Bgra)
            {
                // The rows under the status bar only.
                context.UpdateSubresource(back, 0u, (Vortice.Mathematics.Box?)null, (nint)(bgra + crop * picture.Width * 4), (uint)(picture.Width * 4), 0u);
            }
            swapChain.Present(0, PresentFlags.None);
        }
    }

    /// Slice `slice` of a decoded texture (NV12 or P010, on this view's device), `width`×`height`,
    /// drawn without leaving the card. False if the processor can't (the caller copies instead).
    public bool ShowTexture(nint texture, int slice, int width, int height, ColorSpaceType colors)
    {
        lock (gate)
        {
            if (videoDevice == null || videoContext == null || device == null || context == null) return false;
            var shownHeight = height - crop;
            if (shownHeight <= 0) return true;
            try
            {
                if (swapChain == null || width != videoWidth || height != videoHeight || shownHeight != chainHeight)
                {
                    videoWidth = width;
                    videoHeight = height;
                    chainHeight = shownHeight;
                    DropOutputs();
                    Recreate(width, shownHeight);
                }
                if (processor == null || processorSize != (width, height, shownHeight)) MakeProcessor(width, height, shownHeight);
                if (inputs.Count > 0 && !inputs.ContainsKey((texture, slice)) && inputs.Keys.First().Texture != texture) DropInputs(); // a new pool
                if (!inputs.TryGetValue((texture, slice), out var input))
                {
                    Marshal.AddRef(texture);
                    using var resource = new ID3D11Texture2D(texture); // releases the reference just taken
                    videoDevice.CreateVideoProcessorInputView(resource, processorKinds!, new VideoProcessorInputViewDescription
                    {
                        ViewDimension = VideoProcessorInputViewDimension.Texture2D,
                        Texture2D = new Texture2DVideoProcessorInputView { MipSlice = 0, ArraySlice = (uint)slice },
                    }, out input).CheckError();
                    inputs[(texture, slice)] = input;
                }
                if (colors != inputColors)
                {
                    videoContext.VideoProcessorSetStreamColorSpace1(processor!, 0, colors);
                    inputColors = colors;
                }
                using var back = swapChain!.GetBuffer<ID3D11Texture2D>(0);
                if (!outputs.TryGetValue(back.NativePointer, out var output))
                {
                    videoDevice.CreateVideoProcessorOutputView(back, processorKinds!, new VideoProcessorOutputViewDescription
                    {
                        ViewDimension = VideoProcessorOutputViewDimension.Texture2D,
                        Texture2D = new Texture2DVideoProcessorOutputView { MipSlice = 0 },
                    }, out output).CheckError();
                    outputs[back.NativePointer] = output;
                }
                // The rows under the status bar, into the whole buffer.
                Blt(input, output, width, height, width, shownHeight);
                swapChain.Present(0, PresentFlags.None);
                Probe(input, width, height);
                return true;
            }
            catch (Exception e)
            {
                Log.Info($"video: drawing on the graphics card failed ({e.Message}); copying pictures instead");
                return false;
            }
        }
    }

    private void Blt(ID3D11VideoProcessorInputView input, ID3D11VideoProcessorOutputView output, int width, int height, int outW, int outH)
    {
        videoContext!.VideoProcessorSetStreamSourceRect(processor!, 0, true, new Vortice.RawRect(0, crop, width, height));
        videoContext.VideoProcessorSetStreamDestRect(processor!, 0, true, new Vortice.RawRect(0, 0, outW, outH));
        videoContext.VideoProcessorSetOutputTargetRect(processor!, true, new Vortice.RawRect(0, 0, outW, outH));
        videoContext.VideoProcessorBlt(processor!, output, 0, 1, [new VideoProcessorStream { Enable = true, InputSurface = input }]);
    }

    private void MakeProcessor(int width, int height, int outHeight)
    {
        processor?.Dispose();
        processorKinds?.Dispose();
        DropInputs();
        DropOutputs();
        probeView?.Dispose();
        probeView = null;
        var description = new VideoProcessorContentDescription
        {
            InputFrameFormat = VideoFrameFormat.Progressive,
            InputWidth = (uint)width, InputHeight = (uint)height,
            OutputWidth = (uint)width, OutputHeight = (uint)outHeight,
            InputFrameRate = new Rational(60, 1), OutputFrameRate = new Rational(60, 1),
            Usage = VideoUsage.PlaybackNormal,
        };
        videoDevice!.CreateVideoProcessorEnumerator(ref description, out processorKinds).CheckError();
        videoDevice.CreateVideoProcessor(processorKinds!, 0, out processor).CheckError();
        // Exactly the picture: no denoising or "enhancement" the driver might add on its own.
        videoContext!.VideoProcessorSetStreamAutoProcessingMode(processor!, 0, false);
        videoContext.VideoProcessorSetOutputColorSpace1(processor!, ColorSpaceType.RgbFullG22NoneP709);
        inputColors = (ColorSpaceType)(-1);
        processorSize = (width, height, outHeight);
    }

    /// A few times a second: the picture shrunk to 16×16 and read back, black or not (as the Mac
    /// samples 64 points). Reading waits for the card, so not every frame.
    private void Probe(ID3D11VideoProcessorInputView input, int width, int height)
    {
        var now = Environment.TickCount64;
        if (now - lastProbe < 250) return;
        lastProbe = now;
        if (probe == null)
        {
            var description = new Texture2DDescription
            {
                Width = 16, Height = 16, MipLevels = 1, ArraySize = 1, Format = Format.B8G8R8A8_UNorm,
                SampleDescription = new SampleDescription(1, 0), Usage = ResourceUsage.Default, BindFlags = BindFlags.RenderTarget,
            };
            probe = device!.CreateTexture2D(description);
            description.Usage = ResourceUsage.Staging;
            description.BindFlags = BindFlags.None;
            description.CPUAccessFlags = CpuAccessFlags.Read;
            probeRead = device.CreateTexture2D(description);
        }
        if (probeView == null)
        {
            videoDevice!.CreateVideoProcessorOutputView(probe, processorKinds!, new VideoProcessorOutputViewDescription
            {
                ViewDimension = VideoProcessorOutputViewDimension.Texture2D,
                Texture2D = new Texture2DVideoProcessorOutputView { MipSlice = 0 },
            }, out probeView).CheckError();
        }
        Blt(input, probeView!, width, height, 16, 16);
        context!.CopyResource(probeRead!, probe);
        var mapped = context.Map(probeRead!, 0, MapMode.Read);
        try
        {
            var black = true;
            for (var y = 1; y < 16 && black; y += 2)
            {
                var row = (byte*)mapped.DataPointer + y * mapped.RowPitch;
                for (var x = 1; x < 16; x += 2)
                {
                    var p = row + x * 4;
                    if (p[0] >= 24 || p[1] >= 24 || p[2] >= 24) { black = false; break; }
                }
            }
            LastBlack = black;
        }
        finally
        {
            context.Unmap(probeRead!, 0);
        }
    }

    private void DropInputs()
    {
        foreach (var view in inputs.Values) view.Dispose();
        inputs.Clear();
    }

    private void DropOutputs()
    {
        foreach (var view in outputs.Values) view.Dispose();
        outputs.Clear();
    }

    private void Recreate(int width, int height)
    {
        if (swapChain != null)
        {
            swapChain.ResizeBuffers(2, (uint)width, (uint)height, Format.Unknown, SwapChainFlags.None).CheckError();
            Transform();
            return;
        }
        using var dxgiDevice = device!.QueryInterface<IDXGIDevice>();
        using var adapter = dxgiDevice.GetAdapter();
        using var factory = adapter.GetParent<IDXGIFactory2>();
        var description = new SwapChainDescription1
        {
            Width = (uint)width,
            Height = (uint)height,
            Format = Format.B8G8R8A8_UNorm,
            BufferCount = 2,
            BufferUsage = Usage.RenderTargetOutput,
            SampleDescription = new SampleDescription(1, 0),
            Scaling = Scaling.Stretch,
            SwapEffect = SwapEffect.FlipSequential,
            AlphaMode = AlphaMode.Ignore,
        };
        using var created = factory.CreateSwapChainForComposition(device, description);
        swapChain = created.QueryInterface<IDXGISwapChain2>();
        Transform();
        // Attached on the UI thread (the panel is a XAML object).
        var chain = swapChain.NativePointer;
        Marshal.AddRef(chain);
        panel.DispatcherQueue.TryEnqueue(() =>
        {
            Attach(chain);
            Marshal.Release(chain);
        });
    }

    /// ISwapChainPanelNative::SetSwapChain, through the panel's COM interface.
    private void Attach(nint chain)
    {
        var iid = new Guid("63aad0b8-7c24-40ff-85a8-640d944cc325");
        var unknown = ((WinRT.IWinRTObject)panel).NativeObject.ThisPtr;
        if (Marshal.QueryInterface(unknown, in iid, out var native) != 0) return;
        try
        {
            var setSwapChain = (delegate* unmanaged[Stdcall]<nint, nint, int>)(*(nint**)native)[3];
            setSwapChain(native, chain);
        }
        finally
        {
            Marshal.Release(native);
        }
    }

    private void Layout(double width, double height)
    {
        lock (gate)
        {
            panelWidth = width;
            panelHeight = height;
            if (swapChain != null) Transform();
        }
    }

    /// The swap chain's pixels are DIPs to the panel: scale and centre them to fit.
    private void Transform()
    {
        var (x, y, w, h) = Fit(videoWidth, videoHeight - crop);
        if (w <= 0 || h <= 0) return;
        swapChain!.MatrixTransform = Matrix3x2.CreateScale((float)(w / videoWidth), (float)(h / (videoHeight - crop)))
            * Matrix3x2.CreateTranslation((float)x, (float)y);
    }

    private (double X, double Y, double Width, double Height) Fit(int width, int height)
    {
        if (width <= 0 || height <= 0 || panelWidth <= 0 || panelHeight <= 0) return (0, 0, panelWidth, panelHeight);
        var scale = Math.Min(panelWidth / width, panelHeight / height);
        double w = width * scale, h = height * scale;
        return ((panelWidth - w) / 2, (panelHeight - h) / 2, w, h);
    }

    public void Dispose()
    {
        lock (gate)
        {
            DropInputs();
            DropOutputs();
            probeView?.Dispose();
            probe?.Dispose();
            probeRead?.Dispose();
            processor?.Dispose();
            processorKinds?.Dispose();
            videoContext?.Dispose();
            videoDevice?.Dispose();
            swapChain?.Dispose();
            context?.Dispose();
            device?.Dispose();
            swapChain = null;
            context = null;
            device = null;
        }
    }
}
