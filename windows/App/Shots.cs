using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;

namespace Nearside;

/// Saves a window's content as drawn, as a PNG (the demo's screenshots: see App.RunDemo).
internal static class Shots
{
    public static async Task SaveAsync(Window window, UIElement root, string path)
    {
        await Task.Delay(1500); // laid out and drawn
        var bitmap = new RenderTargetBitmap();
        await bitmap.RenderAsync(root);
        var pixels = await bitmap.GetPixelsAsync();
        using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        var dpi = Win32.GetDpiForWindow(Microsoft.UI.Win32Interop.GetWindowFromWindowId(window.AppWindow.Id));
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
            (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, dpi, dpi, pixels.ToArray());
        await encoder.FlushAsync();
        using var file = File.Create(path);
        await stream.AsStreamForRead().CopyToAsync(file);
        Log.Info($"saved a shot: {bitmap.PixelWidth}x{bitmap.PixelHeight}");
    }
}
