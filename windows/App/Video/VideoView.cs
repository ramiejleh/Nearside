using System.Numerics;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml.Controls;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace Nearside.Video;

/// Draws pictures into a SwapChainPanel with Direct3D 11: each one is copied into a swap chain the
/// size of the video, which the compositor scales to fit the panel (keeping its shape). Pictures
/// come from the decoding thread; layout changes from the UI thread; both under one lock.
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

    public VideoView(SwapChainPanel panel)
    {
        this.panel = panel;
        // A GPU if there is one, else Windows' software renderer (a VM).
        var levels = new[] { FeatureLevel.Level_11_0, FeatureLevel.Level_10_0 };
        if (D3D11.D3D11CreateDevice(null, DriverType.Hardware, DeviceCreationFlags.BgraSupport, levels, out device, out context).Failure)
        {
            D3D11.D3D11CreateDevice(null, DriverType.Warp, DeviceCreationFlags.BgraSupport, levels, out device, out context).CheckError();
        }
        panel.SizeChanged += (_, e) => Layout(e.NewSize.Width, e.NewSize.Height);
    }

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
            swapChain?.Dispose();
            context?.Dispose();
            device?.Dispose();
            swapChain = null;
            context = null;
            device = null;
        }
    }
}
