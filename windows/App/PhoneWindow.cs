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
/// finger, or a pen) works as a finger; the wheel scrolls; typing goes to the app. As on the Mac:
/// a size (Phone, Foldable, Tablet) changes the display on the phone, so the app lays itself out
/// again; dragging the window's edge only zooms the picture (the window keeps the screen's shape),
/// remembered per size; the home screen has Recents (drawn here from the phone's list) and a dock.
public sealed class PhoneWindow : Window
{
    private static readonly Dictionary<long, PhoneWindow> Open = [];
    private static readonly Dictionary<nint, PhoneWindow> ByHandle = [];
    /// The toolbar's width: a strip on the window's right, beside the picture (as on the Mac).
    private const double ToolbarWidth = 44;
    private static readonly string[] Sizes = ["phone", "foldable", "tablet"];

    private readonly long id;
    /// The app in it; null for the phone window (its home screen).
    private readonly string? package;
    private readonly nint hwnd;
    private readonly StackPanel toolbar;
    private readonly Dictionary<string, Button> sizeButtons = [];
    private string size;
    /// The screen shown (the display minus the phone's status bar), in dp.
    private double shownWidthDp = 400, shownHeightDp = 800;
    private readonly Recents recents;
    private readonly SwapChainPanel panel = new();
    private readonly ContentControl keyTarget = new()
    {
        IsTabStop = true, UseSystemFocusVisuals = false,
        HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch,
    };
    private readonly VideoView view;
    private readonly Border overlay = new() { Visibility = Visibility.Collapsed };
    private readonly TextBlock overlayText = new() { TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, MaxWidth = 280 };
    private readonly ProgressRing overlayRing = new() { IsActive = true, Width = 28, Height = 28 };
    /// Reopen (or Bring Back) | Close Window, under the words when the app was closed on the phone
    /// or moved to it (as on the Mac).
    private readonly Button reopenButton = new() { Content = "Reopen" };
    private readonly StackPanel overlayButtons = new() { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
    /// Go Back | Open on Phone, when the app hides the screen it's on (a profile photo): Back
    /// usually leaves that screen, and the rest of the app works here (as on the Mac).
    private readonly StackPanel secureButtons = new() { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, Visibility = Visibility.Collapsed };
    /// A few seconds' message over the picture (dropped files the app couldn't take).
    private readonly Border notice = new()
    {
        Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center,
        Margin = new Thickness(16, 0, 16, 24), Padding = new Thickness(14, 8, 14, 9), CornerRadius = new CornerRadius(16),
        Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0xE6, 0x20, 0x20, 0x24)),
        Child = new TextBlock { Foreground = new SolidColorBrush(Microsoft.UI.Colors.White), TextWrapping = TextWrapping.Wrap },
    };
    private DispatcherTimer? noticeTimer;

    private void ShowNotice(string text)
    {
        ((TextBlock)notice.Child).Text = text;
        notice.Visibility = Visibility.Visible;
        noticeTimer?.Stop();
        noticeTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
        noticeTimer.Tick += (_, _) => { noticeTimer?.Stop(); notice.Visibility = Visibility.Collapsed; };
        noticeTimer.Start();
    }
    /// Pointers down on the picture, as the phone's pointer numbers (0 for the mouse).
    private readonly Dictionary<uint, byte> fingers = [];

    /// Opens the phone's home screen (no `app`) or an app; null if the phone isn't connected.
    /// Opens one after Windows Hello, if asked for (see AuthGate).
    public static async Task<PhoneWindow?> OpenAsync(string? package = null, string? activity = null, string? label = null, string? notification = null)
    {
        var owner = Open.Values.FirstOrDefault();
        var ownerHandle = owner != null ? owner.hwnd : 0;
        if (!await AuthGate.AuthenticateAsync(ownerHandle, opening: true)) return null;
        return Show(package, activity, label, notification);
    }

    /// With `notification`, the app opens at that notification (its call, its chat).
    private static PhoneWindow? Show(string? package = null, string? activity = null, string? label = null, string? notification = null)
    {
        var id = VideoRouter.NextId();
        var window = new PhoneWindow(id, label ?? "Phone", package);
        VideoRouter.Add(id, new PhoneStream(id, window.view));
        var request = JsonSerializer.Serialize(new { id, size = window.size, package, activity, label, notification });
        var reply = OpenSession(request);
        if (reply == null)
        {
            VideoRouter.Remove(id);
            window.Close();
            return null;
        }
        Open[id] = window;
        window.shownWidthDp = reply.Value.GetProperty("shownWidthDp").GetDouble();
        window.shownHeightDp = reply.Value.GetProperty("shownHeightDp").GetDouble();
        window.Place(keepTop: false);
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

    private PhoneWindow(long id, string title, string? package)
    {
        this.id = id;
        this.package = package;
        Title = title;
        hwnd = Microsoft.UI.Win32Interop.GetWindowFromWindowId(AppWindow.Id);
        // An app's window is that app on the taskbar (its own button and icon), not Nearside.
        if (package != null) TaskbarIdentity.Set(hwnd, package, title);
        AppWindow.SetIcon((package != null ? TaskbarIdentity.ExistingIcon(package) : null)
                          ?? Path.Combine(AppContext.BaseDirectory, "Assets", "Nearside.ico"));
        view = new VideoView(panel);
        size = AppSettings.Get(SizeKey) is { } saved && Sizes.Contains(saved) ? saved : "phone";

        toolbar = new StackPanel { Orientation = Orientation.Vertical, Spacing = 4, Padding = new Thickness(4, 8, 4, 8), Width = ToolbarWidth };
        // The phone window: the phone's own buttons, then sizes. An app's window: sizes and moving
        // it to the phone only (Esc is still Back; Back on an app's first screen would close it).
        if (package == null)
        {
            toolbar.Children.Add(ToolButton("\uE72B", "Back (Esc)", GoBack));
            toolbar.Children.Add(ToolButton("\uE80F", "Home", () => { recents?.Hide(); Command("home"); }));
            toolbar.Children.Add(ToolButton("\uE7C4", "Recents", ToggleRecents));
            bellButton = ToolButton("\uEA8F", "Notifications", ToggleNotifications);
            toolbar.Children.Add(bellButton);
            toolbar.Children.Add(Separator());
        }
        foreach (var (name, glyph, tip) in new[] { ("phone", "\uE8EA", "Phone size"), ("foldable", "\uE89A", "Foldable size"), ("tablet", "\uE70A", "Tablet size") })
        {
            var button = ToolButton(glyph, tip, () => SetSize(name));
            sizeButtons[name] = button;
            toolbar.Children.Add(button);
        }
        if (package != null)
        {
            toolbar.Children.Add(Separator());
            toolbar.Children.Add(ToolButton("\uE8A7", "Open on the phone", () => Command("openOnPhone")));
        }
        ShowSize();

        overlay.Background = (Brush)Application.Current.Resources["SolidBackgroundFillColorBaseBrush"];
        overlay.Child = new StackPanel
        {
            Spacing = 12, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center,
            Children = { overlayRing, overlayText, overlayButtons, secureButtons },
        };
        var back = new Button { Content = "Go Back", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        back.Click += (_, _) => Command("back");
        var toPhone = new Button { Content = "Open on Phone" };
        toPhone.Click += (_, _) => Command("openOnPhone");
        secureButtons.Children.Add(back);
        secureButtons.Children.Add(toPhone);
        reopenButton.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        reopenButton.Click += (_, _) =>
        {
            Close();
            _ = OpenAsync(package, null, title);
        };
        var closeWindow = new Button { Content = "Close Window" };
        closeWindow.Click += (_, _) => Close();
        overlayButtons.Children.Add(reopenButton);
        overlayButtons.Children.Add(closeWindow);
        var stage = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Black) };
        recents = new Recents(pick: task => { Command("front", new { task }); }, remove: task => Command("removeTask", new { task }),
                              home: () => Command("home"));
        stage.Children.Add(panel);
        stage.Children.Add(recents.Root);
        // The phone's notifications over the screen (the phone window's bell), as on the Mac.
        notes.OpenHere = note => { HideNotifications(); Command("openNotification", new { key = note.Key }); };
        notesLayer.Children.Add(new Border
        {
            HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Top,
            Padding = new Thickness(0, 12, 0, 0), Child = notesHeader,
        });
        notesLayer.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        notesLayer.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(notes.Root, 1);
        notesLayer.Children.Add(notes.Root);
        notesLayer.Tapped += (_, e) => { if (e.OriginalSource == notesLayer) HideNotifications(); };
        stage.Children.Add(notesLayer);
        stage.Children.Add(overlay);
        stage.Children.Add(notice);
        // Files dropped on the picture: shared with the app on screen (as on the Mac).
        stage.AllowDrop = true;
        stage.DragOver += (_, e) =>
        {
            if (covered || !e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems)) return;
            e.AcceptedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Copy;
            e.DragUIOverride.Caption = package != null ? $"Share with {Title}" : "Share with the app on screen";
        };
        stage.Drop += async (_, e) =>
        {
            if (covered || !e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems)) return;
            var items = await e.DataView.GetStorageItemsAsync();
            var paths = items.OfType<Windows.Storage.StorageFile>().Select(f => f.Path).Where(p => p.Length > 0).ToList();
            if (paths.Count < items.Count) ShowNotice("Folders can't be shared yet");
            if (paths.Count > 0) Command("share", new { paths });
        };
        var root = new Grid();
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        // The picture can't take keyboard focus, so it sits in a control that can: typing reaches
        // the phone whatever was focused before (a button that went away left keys going nowhere).
        keyTarget.Content = stage;
        root.Children.Add(keyTarget);
        Grid.SetColumn(toolbar, 1);
        root.Children.Add(toolbar);
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
            if (recents.Shown) return;
            if (e.Character >= ' ' && e.Character != '\u007f') Command("text", new { text = e.Character.ToString() });
        };

        Activated += (_, e) =>
        {
            if (covered && e.WindowActivationState != WindowActivationState.Deactivated) _ = UncoverAsync();
            if (!covered) Command("visibility", new { v = e.WindowActivationState == WindowActivationState.Deactivated ? 2 : 0 });
            if (e.WindowActivationState != WindowActivationState.Deactivated) FocusKeys();
        };
        AuthGate.Locked += Cover;
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
        ByHandle[hwnd] = this;
        unsafe { Win32.SetWindowSubclass(hwnd, &SizingProc, 1, 0); }
        EngineHost.Changed += NotificationsChanged;
        NotificationsChanged(EngineHost.Current);
        Closed += (_, _) =>
        {
            EngineHost.Changed -= NotificationsChanged;
            unsafe { Win32.RemoveWindowSubclass(hwnd, &SizingProc, 1); }
            ByHandle.Remove(hwnd);
            AuthGate.Locked -= Cover;
            statsTimer.Stop();
            if (package != null) TaskbarIdentity.Clear(hwnd);
            Command("close"); // always (closing twice is harmless): the bridge forgets the window
            Open.Remove(id);
            VideoRouter.Remove(id);
            view.Dispose();
        };
    }

    // MARK: Size and zoom

    /// The size is per app (the phone window has its own), as on the Mac; the zoom per size.
    private string SizeKey => package == null ? "PhoneWindow.size" : $"PhoneApp.size.{package}";
    private string ZoomKey => $"{(package == null ? "PhoneWindow" : "PhoneApp")}.zoom.{size}";

    private double Scale => Win32.GetDpiForWindow(hwnd) / 96.0;

    /// Window DIPs per dp: as saved for this size, else what fits the screen (at most 1).
    private double Zoom
    {
        get
        {
            if (double.TryParse(AppSettings.Get(ZoomKey), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var saved)
                && saved is >= 0.2 and <= 3) return saved;
            var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
            double screenW = area.Width / Scale, screenH = area.Height / Scale;
            var fit = Math.Min(1, Math.Min((screenW * 0.92 - ToolbarWidth) / shownWidthDp, screenH * 0.9 / shownHeightDp));
            return Math.Max(0.3, Math.Floor(fit * 20) / 20);
        }
    }

    /// The window at the zoom; with `keepTop`, where it is (a size change grows it downwards).
    private void Place(bool keepTop)
    {
        var scale = Scale;
        var zoom = Zoom;
        var client = new Windows.Graphics.SizeInt32((int)((shownWidthDp * zoom + ToolbarWidth) * scale), (int)(shownHeightDp * zoom * scale));
        var position = AppWindow.Position;
        AppWindow.ResizeClient(client);
        if (!keepTop) return;
        // Kept on the screen it's on.
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var outer = AppWindow.Size;
        int x = Math.Clamp(position.X, area.X, Math.Max(area.X, area.X + area.Width - outer.Width));
        int y = Math.Clamp(position.Y, area.Y, Math.Max(area.Y, area.Y + area.Height - outer.Height));
        AppWindow.Move(new Windows.Graphics.PointInt32(x, y));
    }

    private void SetSize(string name)
    {
        if (name == size || covered) return;
        size = name;
        AppSettings.Set(SizeKey, name);
        ShowSize();
        recents.Hide();
        Command("resize", new { size = name }); // the "size" event fits the window
    }

    private void ShowSize()
    {
        foreach (var (name, button) in sizeButtons)
        {
            button.Background = name == size ? (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"] : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        }
    }

    /// Dragging an edge: the window keeps the screen's shape (plus the toolbar), and the zoom it
    /// ends at is remembered for this size.
    [System.Runtime.InteropServices.UnmanagedCallersOnly]
    private static unsafe nint SizingProc(nint hwnd, uint message, nint wParam, nint lParam, nuint id, nuint data)
    {
        try
        {
            if (ByHandle.TryGetValue(hwnd, out var window))
            {
                if (message == Win32.WM_SIZING)
                {
                    window.KeepShape((int)wParam, (Win32.RECT*)lParam);
                    return 1;
                }
                if (message == Win32.WM_EXITSIZEMOVE) window.SaveZoom();
            }
        }
        catch (Exception e)
        {
            Log.Info($"phone window sizing: {e.Message}");
        }
        return Win32.DefSubclassProc(hwnd, message, wParam, lParam);
    }

    private unsafe void KeepShape(int edge, Win32.RECT* rect)
    {
        Win32.GetWindowRect(hwnd, out var outer);
        Win32.GetClientRect(hwnd, out var inner);
        int chromeW = outer.right - outer.left - inner.right, chromeH = outer.bottom - outer.top - inner.bottom;
        var toolbar = ToolbarWidth * Scale;
        double width = rect->right - rect->left - chromeW, height = rect->bottom - rect->top - chromeH;
        var ratio = shownHeightDp / shownWidthDp;
        if (edge is Win32.WMSZ_TOP or Win32.WMSZ_BOTTOM)
        {
            width = height / ratio + toolbar; // height leads: the width follows, to the right
            rect->right = rect->left + (int)Math.Round(width) + chromeW;
            return;
        }
        var newHeight = (int)Math.Round(Math.Max(1, width - toolbar) * ratio) + chromeH;
        if (edge is Win32.WMSZ_TOPLEFT or Win32.WMSZ_TOPRIGHT) rect->top = rect->bottom - newHeight;
        else rect->bottom = rect->top + newHeight;
    }

    private void SaveZoom()
    {
        Win32.GetClientRect(hwnd, out var inner);
        var zoom = (inner.right / Scale - ToolbarWidth) / shownWidthDp;
        if (zoom is >= 0.2 and <= 3) AppSettings.Set(ZoomKey, zoom.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture));
    }

    private bool tested;
    private readonly List<Microsoft.UI.Dispatching.DispatcherQueueTimer> testTimers = []; // kept, or they're collected unfired

    /// Test hook: NEARSIDE_TEST_PHONE=recents (Recents, then how many apps and pictures came) or
    /// size:<phone|foldable|tablet> (that size, then the window's size), in the log; no pictures.
    private void TestIfAsked()
    {
        var mode = Environment.GetEnvironmentVariable("NEARSIDE_TEST_PHONE");
        if (mode == null || tested) return;
        tested = true;
        void After(double seconds, Action action)
        {
            var timer = DispatcherQueue.CreateTimer();
            timer.Interval = TimeSpan.FromSeconds(seconds);
            timer.IsRepeating = false;
            timer.Tick += (_, _) => action();
            testTimers.Add(timer);
            timer.Start();
        }
        After(6, () =>
        {
            if (mode == "recents")
            {
                ToggleRecents();
                After(6, () => Log.Info($"test: recents shown {recents.Shown}, {recents.Counts.Apps} apps, {recents.Counts.Pictures} pictures"));
            }
            else if (mode.StartsWith("size:"))
            {
                var before = AppWindow.ClientSize;
                SetSize(mode[5..]);
                After(4, () => Log.Info($"test: size {size}, shown {shownWidthDp:0}x{shownHeightDp:0} dp, window {before.Width}x{before.Height} -> {AppWindow.ClientSize.Width}x{AppWindow.ClientSize.Height} px"));
            }
        });
    }

    // MARK: Navigation and Recents

    private void GoBack()
    {
        if (notesLayer.Visibility == Visibility.Visible) HideNotifications();
        else if (recents.Shown) recents.Hide();
        else Command("back");
    }

    private Button? bellButton;
    private readonly NotificationList notes = new();
    private readonly Grid notesLayer = new()
    {
        Visibility = Visibility.Collapsed, RequestedTheme = ElementTheme.Dark,
        // Opaque: the phone's screen behind made the list hard to read.
        Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0xFF, 0x16, 0x16, 0x18)),
    };
    private readonly TextBlock notesHeader = new()
    {
        Text = "Notifications", FontSize = 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Margin = new Thickness(16, 0, 16, 6),
        Foreground = new SolidColorBrush(Microsoft.UI.Colors.White),
    };

    private void ToggleNotifications()
    {
        if (covered) return;
        if (notesLayer.Visibility == Visibility.Visible) { HideNotifications(); return; }
        recents.Hide();
        notes.Render(EngineHost.Current);
        notesLayer.Visibility = Visibility.Visible;
    }

    private void HideNotifications()
    {
        notesLayer.Visibility = Visibility.Collapsed;
        FocusKeys(); // back to the phone (the reply box had them)
    }

    /// The list follows the phone; the bell shows how many there are.
    private void NotificationsChanged(Snapshot s)
    {
        if (bellButton == null) return;
        var count = s.Connected ? s.Notifications.Count : 0;
        ToolTipService.SetToolTip(bellButton, count > 0 ? $"Notifications ({count})" : "Notifications");
        bellButton.Content = count > 0
            ? new Grid { Children = { new FontIcon { Glyph = "\uEA8F", FontSize = 14 }, new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 7, Height = 7, Fill = (Brush)Application.Current.Resources["AccentFillColorDefaultBrush"], HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, -2, -3, 0) } } }
            : new FontIcon { Glyph = "\uEA8F", FontSize = 14 };
        if (notesLayer.Visibility == Visibility.Visible) notes.Render(s);
    }

    private void ToggleRecents()
    {
        if (covered) return;
        if (recents.Shown)
        {
            recents.Hide();
            return;
        }
        recents.Show();
        Command("recents"); // the "tasks" event lists them, then a "snapshot" each
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
                    case "showing":
                        sessionState = null;
                        Overlay();
                        TestIfAsked();
                        break;
                    case "opening": ShowOverlay("Opening…", busy: true); break;
                    case "reconnecting": ShowOverlay("Reconnecting…", busy: true); break;
                    case "exited":
                        reopenButton.Content = "Reopen";
                        ShowOverlay($"{Title} was closed on your phone.", busy: false, reopen: package != null);
                        break;
                    case "movedToPhone":
                        // Opened on the phone: the window stays, to bring it back (as on the Mac).
                        reopenButton.Content = "Bring Back";
                        ShowOverlay($"{Title} moved to your phone.", busy: false, reopen: package != null);
                        break;
                    case "busy": ShowOverlay("Your phone can't show another window right now. Close one and try again.", busy: false); break;
                    case "failed": ShowOverlay(e.TryGetProperty("message", out var m) ? m.GetString() ?? "" : "Couldn't open.", busy: false); break;
                    case "closed":
                        Close();
                        break;
                }
                break;
            case "shareFailed":
                ShowNotice(e.GetProperty("accepts").GetBoolean() ? $"Couldn't share the files with {Title}" : $"{Title} can't open files like these");
                break;
            case "crop":
                view.SetCrop(e.GetProperty("top").GetInt32(), e.GetProperty("bottom").GetInt32());
                break;
            case "size":
                shownWidthDp = e.GetProperty("shownWidthDp").GetDouble();
                shownHeightDp = e.GetProperty("shownHeightDp").GetDouble();
                Place(keepTop: true);
                break;
            case "tasks":
                Log.Info($"phone window {id}: recents: {e.GetProperty("tasks").GetArrayLength()} apps");
                recents.SetTasks(e.GetProperty("tasks").EnumerateArray().Select(t => new Recents.Entry(
                    t.GetProperty("id").GetInt32(), t.GetProperty("package").GetString() ?? "",
                    t.TryGetProperty("label", out var l) ? l.GetString() : null,
                    t.TryGetProperty("icon", out var i) ? i.GetString() : null)).ToList());
                break;
            case "snapshot":
                _ = recents.SetSnapshotAsync(e.GetProperty("task").GetInt32(), Convert.FromBase64String(e.GetProperty("png").GetString() ?? ""));
                break;
            case "icon":
                if (package != null) _ = SetAppIconAsync(e.GetProperty("path").GetString() ?? "", e.GetProperty("adaptive").GetBoolean());
                break;
            case "secure":
                secure = e.GetProperty("on").GetBoolean();
                Overlay();
                break;
        }
    }

    private async Task SetAppIconAsync(string png, bool adaptive)
    {
        if (package == null || png.Length == 0) return;
        if (await TaskbarIdentity.IconAsync(hwnd, package, png, adaptive) is { } ico && Open.ContainsKey(id)) AppWindow.SetIcon(ico);
    }

    private bool covered;
    /// What the session says (its overlay text and spinner; null while showing) and whether the
    /// app blocks capture: the overlay comes from these and `covered`, in Overlay().
    private (string Text, bool Busy, bool Reopen)? sessionState = ("Opening…", true, false);
    private bool secure;

    /// The PC locked: the window shows nothing, takes no input and gets no video until Windows
    /// Hello says it's you.
    private void Cover()
    {
        // Fingers down are lifted first (nothing reaches the phone once covered).
        foreach (var finger in fingers.Values) Command("touch", new { a = 3, p = finger, x = 0f, y = 0f });
        fingers.Clear();
        covered = true;
        recents.Hide();
        foreach (var button in toolbar.Children.OfType<Control>()) button.IsEnabled = false;
        Command("visibility", new { v = 1 });
        Overlay();
    }

    private async Task UncoverAsync()
    {
        if (!await AuthGate.AuthenticateAsync(Microsoft.UI.Win32Interop.GetWindowFromWindowId(AppWindow.Id), opening: false)) return;
        covered = false;
        foreach (var button in toolbar.Children.OfType<Control>()) button.IsEnabled = true;
        Overlay();
        Command("visibility", new { v = 0 });
    }

    private void ShowOverlay(string text, bool busy, bool reopen = false)
    {
        sessionState = (text, busy, reopen);
        Overlay();
    }

    /// The one place the overlay is decided: the lock first, then a capture-blocking app, then the
    /// session's state.
    private void Overlay()
    {
        (string Text, bool Busy, bool Reopen)? shown = covered ? ("Locked. Click to show it again.", false, false)
            : secure ? ($"{Title} hides this screen from recordings and other displays. Go back to keep using it here, or open it on your phone.", false, false)
            : sessionState;
        overlay.Visibility = shown == null ? Visibility.Collapsed : Visibility.Visible;
        if (shown is { } s)
        {
            overlayText.Text = s.Text;
            overlayRing.Visibility = s.Busy ? Visibility.Visible : Visibility.Collapsed;
            overlayButtons.Visibility = s.Reopen ? Visibility.Visible : Visibility.Collapsed;
        }
        secureButtons.Visibility = !covered && secure ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Command(string name, object? fields = null)
    {
        // Covered: nothing reaches the phone but hiding it and closing it.
        if (covered && name is not ("visibility" or "close")) return;
        var json = JsonSerializer.SerializeToNode(fields ?? new { })!.AsObject();
        json["c"] = name;
        Native.SessionCommand(id, json.ToJsonString());
    }

    /// A short rule between groups of buttons in the toolbar.
    private static Border Separator() => new()
    {
        Height = 1, Width = 24, Margin = new Thickness(0, 4, 0, 4), HorizontalAlignment = HorizontalAlignment.Center,
        Background = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"],
    };

    private static Button ToolButton(string glyph, string tip, Action action)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 14 },
            Style = (Style)Application.Current.Resources["SubtleButtonStyle"],
            Width = 36, Height = 32, Padding = new Thickness(0),
            // Clicking doesn't take the keys from the phone (and a typed space can't press it).
            AllowFocusOnInteraction = false,
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

    /// Keys to the phone, unless the notifications list (its reply box) is up.
    private void FocusKeys()
    {
        if (notesLayer.Visibility != Visibility.Visible) keyTarget.Focus(FocusState.Programmatic);
    }

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        keyTarget.Focus(FocusState.Pointer);
        if (covered)
        {
            _ = UncoverAsync();
            return;
        }
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
        if (covered)
        {
            e.Handled = true;
            return;
        }
        if (notesLayer.Visibility == Visibility.Visible)
        {
            // Keys go to the list (a reply box), not the phone; Esc closes it.
            if (e.Key == Windows.System.VirtualKey.Escape) { HideNotifications(); e.Handled = true; }
            return;
        }
        if (recents.Shown)
        {
            if (e.Key == Windows.System.VirtualKey.Escape) recents.Hide();
            e.Handled = true; // nothing reaches the phone while Recents is up
            return;
        }
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
