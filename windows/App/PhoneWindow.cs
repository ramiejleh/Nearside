using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Nearside.Engine;
using Nearside.Video;

namespace Nearside;

/// A phone window: the phone's home screen, or one app, streamed from the phone. The mouse (or a
/// finger, or a pen) works as a finger; the wheel scrolls; typing goes to the app.
public sealed class PhoneWindow : Window
{
    private static readonly Dictionary<long, PhoneWindow> Open = [];
    private const double ToolbarHeight = 40;

    private readonly long id;
    private readonly SwapChainPanel panel = new();
    private readonly VideoView view;
    private readonly Border overlay = new() { Visibility = Visibility.Collapsed };
    private readonly TextBlock overlayText = new() { TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, MaxWidth = 280 };
    private readonly ProgressRing overlayRing = new() { IsActive = true, Width = 28, Height = 28 };
    /// Pointers down on the picture, as the phone's pointer numbers (0 for the mouse).
    private readonly Dictionary<uint, byte> fingers = [];
    private bool closing;

    /// Opens the phone's home screen (no `app`) or an app; null if the phone isn't connected.
    public static PhoneWindow? Show(string? package = null, string? activity = null, string? label = null)
    {
        var id = VideoRouter.NextId();
        var window = new PhoneWindow(id, label ?? "Phone");
        VideoRouter.Add(id, new PhoneStream(id, window.view));
        var request = JsonSerializer.Serialize(new { id, size = "phone", package, activity, label });
        var reply = OpenSession(request);
        if (reply == null)
        {
            VideoRouter.Remove(id);
            window.closing = true;
            window.Close();
            return null;
        }
        Open[id] = window;
        window.Place(reply.Value.GetProperty("shownWidthDp").GetDouble(), reply.Value.GetProperty("shownHeightDp").GetDouble());
        window.Activate();
        return window;
    }

    private static unsafe JsonElement? OpenSession(string request)
    {
        var p = Native.SessionOpen(request);
        if (p == null) return null;
        try
        {
            return JsonDocument.Parse(Marshal.PtrToStringUTF8((nint)p)!).RootElement.Clone();
        }
        finally
        {
            Native.Free(p);
        }
    }

    /// A session event (from EngineHost), for its window.
    public static void Route(JsonElement e)
    {
        if (Open.TryGetValue(e.GetProperty("id").GetInt64(), out var window)) window.Handle(e);
    }

    private PhoneWindow(long id, string title)
    {
        this.id = id;
        Title = title;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Nearside.ico"));
        view = new VideoView(panel);

        var toolbar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Padding = new Thickness(6, 4, 6, 4), Height = ToolbarHeight };
        toolbar.Children.Add(ToolButton("", "Back (Esc)", () => Command("back")));
        toolbar.Children.Add(ToolButton("", "Home", () => Command("home")));
        toolbar.Children.Add(ToolButton("", "Open on the phone", () => Command("openOnPhone")));

        overlay.Background = (Brush)Application.Current.Resources["SolidBackgroundFillColorBaseBrush"];
        overlay.Child = new StackPanel
        {
            Spacing = 12, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center,
            Children = { overlayRing, overlayText },
        };
        var stage = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Black) };
        stage.Children.Add(panel);
        stage.Children.Add(overlay);
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(toolbar);
        Grid.SetRow(stage, 1);
        root.Children.Add(stage);
        Content = root;
        ShowOverlay("Opening…", busy: true);

        panel.PointerPressed += OnPressed;
        panel.PointerMoved += OnMoved;
        panel.PointerReleased += OnReleased;
        panel.PointerCanceled += OnCanceled;
        panel.PointerCaptureLost += OnCanceled;
        panel.PointerExited += (_, e) => { if (e.Pointer.PointerDeviceType == PointerDeviceType.Mouse) Mouse(1, e); };
        panel.PointerWheelChanged += OnWheel;
        root.KeyDown += OnKey;
        root.CharacterReceived += (_, e) =>
        {
            if (e.Character >= ' ' && e.Character != '\u007f') Command("text", new { text = e.Character.ToString() });
        };

        Activated += (_, e) => Command("visibility", new { v = e.WindowActivationState == WindowActivationState.Deactivated ? 2 : 0 });
        AppWindow.Changed += (_, _) =>
        {
            // Minimised: no video until it's back (activating it again says so).
            if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized }) Command("visibility", new { v = 1 });
        };
        // Frame rate and decode time in the log while open (no picture content).
        var statsTimer = DispatcherQueue.CreateTimer();
        statsTimer.Interval = TimeSpan.FromSeconds(5);
        statsTimer.Tick += (_, _) =>
        {
            if (VideoRouter.Get(id)?.TakeStats() is { Frames: > 0 } stats)
            {
                Log.Info($"phone window {id}: {stats.Frames / 5.0:0.#} fps, {stats.DecodeMs:0.0} ms to decode, {stats.DrawMs:0.0} ms to draw");
            }
        };
        statsTimer.Start();
        Closed += (_, _) =>
        {
            statsTimer.Stop();
            if (!closing) Command("close");
            Open.Remove(id);
            VideoRouter.Remove(id);
            view.Dispose();
        };
    }

    /// Sized to the phone's shown screen at 1 dp = 1 DIP, or smaller to fit the screen.
    private void Place(double widthDp, double heightDp)
    {
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var scale = Win32.GetDpiForWindow(Microsoft.UI.Win32Interop.GetWindowFromWindowId(AppWindow.Id)) / 96.0;
        double screenW = area.Width / scale, screenH = area.Height / scale;
        var zoom = Math.Min(1, Math.Min(screenW * 0.92 / widthDp, (screenH * 0.9 - ToolbarHeight) / heightDp));
        zoom = Math.Max(0.3, Math.Floor(zoom * 20) / 20);
        AppWindow.ResizeClient(new Windows.Graphics.SizeInt32((int)(widthDp * zoom * scale), (int)((heightDp * zoom + ToolbarHeight) * scale)));
    }

    private void Handle(JsonElement e)
    {
        switch (e.GetProperty("kind").GetString())
        {
            case "state":
                var state = e.GetProperty("state").GetString();
                Log.Info($"phone window {id}: {state}");
                switch (state)
                {
                    case "showing": overlay.Visibility = Visibility.Collapsed; break;
                    case "opening": ShowOverlay("Opening…", busy: true); break;
                    case "reconnecting": ShowOverlay("Reconnecting…", busy: true); break;
                    case "exited": ShowOverlay("The app was closed on your phone.", busy: false); break;
                    case "busy": ShowOverlay("Your phone can't show another window right now. Close one and try again.", busy: false); break;
                    case "failed": ShowOverlay(e.TryGetProperty("message", out var m) ? m.GetString() ?? "" : "Couldn't open.", busy: false); break;
                    case "movedToPhone":
                    case "closed":
                        closing = true;
                        Close();
                        break;
                }
                break;
            case "crop":
                view.Crop = e.GetProperty("rows").GetInt32();
                break;
            case "secure":
                if (e.GetProperty("on").GetBoolean()) ShowOverlay("This app doesn't allow its screen to be shown elsewhere.", busy: false);
                else overlay.Visibility = Visibility.Collapsed;
                break;
        }
    }

    private void ShowOverlay(string text, bool busy)
    {
        overlayText.Text = text;
        overlayRing.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        overlay.Visibility = Visibility.Visible;
    }

    private void Command(string name, object? fields = null)
    {
        var json = JsonSerializer.SerializeToNode(fields ?? new { })!.AsObject();
        json["c"] = name;
        Native.SessionCommand(id, json.ToJsonString());
    }

    private static Button ToolButton(string glyph, string tip, Action action)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 14 },
            Style = (Style)Application.Current.Resources["SubtleButtonStyle"],
            Width = 36, Height = 32, Padding = new Thickness(0),
        };
        ToolTipService.SetToolTip(button, tip);
        button.Click += (_, _) => action();
        return button;
    }

    // MARK: Input

    /// The pointer within the picture, 0…1 (it may be outside while dragging).
    private (float X, float Y) Normalised(PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(panel).Position;
        var (x, y, w, h) = view.PictureRect;
        return ((float)((point.X - x) / w), (float)((point.Y - y) / h));
    }

    private static bool Inside((float X, float Y) p) => p.X is >= 0 and <= 1 && p.Y is >= 0 and <= 1;

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        var point = Normalised(e);
        if (!Inside(point)) return;
        var properties = e.GetCurrentPoint(panel).Properties;
        if (e.Pointer.PointerDeviceType == PointerDeviceType.Mouse && properties.IsRightButtonPressed)
        {
            Mouse(2, e);
            return;
        }
        var finger = e.Pointer.PointerDeviceType == PointerDeviceType.Mouse ? (byte)0 : NextFinger();
        fingers[e.Pointer.PointerId] = finger;
        panel.CapturePointer(e.Pointer);
        Command("touch", new { a = 0, p = finger, x = point.X, y = point.Y });
        e.Handled = true;
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        var point = Normalised(e);
        if (fingers.TryGetValue(e.Pointer.PointerId, out var finger))
        {
            Command("touch", new { a = 2, p = finger, x = Math.Clamp(point.X, 0, 1), y = Math.Clamp(point.Y, 0, 1) });
        }
        else if (e.Pointer.PointerDeviceType == PointerDeviceType.Mouse && Inside(point))
        {
            Command("mouse", new { a = 0, x = point.X, y = point.Y }); // hover
        }
    }

    private void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        var point = Normalised(e);
        if (fingers.Remove(e.Pointer.PointerId, out var finger))
        {
            Command("touch", new { a = 1, p = finger, x = Math.Clamp(point.X, 0, 1), y = Math.Clamp(point.Y, 0, 1) });
            panel.ReleasePointerCapture(e.Pointer);
        }
        else if (e.Pointer.PointerDeviceType == PointerDeviceType.Mouse)
        {
            Mouse(3, e);
        }
    }

    private void OnCanceled(object sender, PointerRoutedEventArgs e)
    {
        if (!fingers.Remove(e.Pointer.PointerId, out var finger)) return;
        var point = Normalised(e);
        Command("touch", new { a = 3, p = finger, x = Math.Clamp(point.X, 0, 1), y = Math.Clamp(point.Y, 0, 1) });
    }

    private byte NextFinger()
    {
        byte n = 1;
        while (fingers.ContainsValue(n)) n++;
        return n;
    }

    private void Mouse(int action, PointerRoutedEventArgs e)
    {
        var point = Normalised(e);
        Command("mouse", new { a = action, x = Math.Clamp(point.X, 0, 1), y = Math.Clamp(point.Y, 0, 1) });
    }

    private void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        var point = Normalised(e);
        if (!Inside(point)) return;
        var properties = e.GetCurrentPoint(panel).Properties;
        var notches = properties.MouseWheelDelta / 120f;
        // Windows: + is up (vertical) and right (horizontal), as the phone wants.
        if (properties.IsHorizontalMouseWheel) Command("scroll", new { x = point.X, y = point.Y, h = notches, v = 0f });
        else Command("scroll", new { x = point.X, y = point.Y, h = 0f, v = notches });
        e.Handled = true;
    }

    private void OnKey(object sender, KeyRoutedEventArgs e)
    {
        var modifiers = (byte)((Down(Windows.System.VirtualKey.Shift) ? 1 : 0) | (Down(Windows.System.VirtualKey.Control) ? 2 : 0)
                               | (Down(Windows.System.VirtualKey.Menu) ? 4 : 0));
        switch (Native.SessionKey(id, (ushort)e.Key, modifiers))
        {
            case 0: return; // text: it arrives as characters
            case 2: _ = PasteAsync(); break;
        }
        e.Handled = true;
    }

    private static bool Down(Windows.System.VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    /// Ctrl+V: this PC's clipboard text, pasted in the app.
    private async Task PasteAsync()
    {
        var content = Windows.ApplicationModel.DataTransfer.Clipboard.GetContent();
        string? text = null;
        if (content.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.Text)) text = await content.GetTextAsync();
        Command("paste", new { text });
    }
}
