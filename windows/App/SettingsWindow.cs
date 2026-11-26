using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Nearside.Engine;

namespace Nearside;

/// Nearside's settings, in sections. Only what works on Windows so far is here: settings for calls,
/// text messages, photos and phone apps arrive with those features.
public sealed class SettingsWindow : Window
{
    // Features: each one's own switch (what the panel shows and Nearside does).
    private readonly Choice clipboard = new()
    {
        Title = "Clipboard",
        Text = "Copy on one device, paste on the other, with a history in the panel.",
    };
    private readonly Choice mirror = new()
    {
        Title = "Notifications",
        Text = "Your phone's notifications on this PC and in the panel. Clearing one here dismisses it on the phone.",
    };
    private readonly Choice texts = new()
    {
        Title = "Text messages",
        Text = "Read and send SMS in the Messages window. RCS chats stay in Google Messages.",
    };
    private readonly Choice calls = new()
    {
        Title = "Calls",
        Text = "Answer or decline phone and app calls here.",
    };
    private readonly Choice ring = new()
    {
        Title = "Ring on this PC",
        Text = "A soft ring while a call comes in.",
    };
    private readonly Choice screenshots = new()
    {
        Title = "New phone screenshots go to this PC",
        Text = "Each one lands in Downloads.",
    };
    private readonly Choice recentPhotos = new()
    {
        Title = "Photos",
        Text = "The phone's newest photos in the panel, while it's open. Click one to open it here.",
    };
    private readonly Choice screenshotsToPhone = new()
    {
        Title = "PC screenshots go to the phone",
        Text = "Into Pictures/Nearside, where the phone's gallery shows them.",
    };
    private readonly ComboBox historyLimit = new() { MinWidth = 130 };
    private readonly ComboBox hello = new() { MinWidth = 220 };
    private readonly ComboBox frameRate = new() { MinWidth = 130 };
    private readonly NotificationApps notificationApps;
    private ScrollViewer? settingsPage;
    private static readonly int[] FrameRates = [60, 90, 120];
    private readonly ComboBox cameraSide = new() { MinWidth = 130, Items = { "Back", "Front" } };
    private static readonly string[] HelloModes = ["Never", "After this PC wakes or unlocks", "Every time an app opens"];
    private readonly Choice startup = new()
    {
        Title = "Start at sign-in",
        Text = "Start Nearside when you sign in to Windows, so syncing is always on.",
    };
    private readonly Choice arrival = new()
    {
        Title = "Show a card when a clip arrives",
        Text = "A small card above the taskbar for a few seconds, with the start of what was copied on your phone.",
    };
    private readonly Choice startMenu = new()
    {
        Title = "Phone apps in the Start menu",
        Text = "A shortcut for each app on your phone, in \u201CNearside Phone Apps\u201D: search for an app in Start to open it in a window.",
    };
    private readonly Choice toast = new()
    {
        Title = "Hide “pasted from your clipboard” on the phone",
        Text = "Android's own phone-wide switch: with it off, you also won't see when other apps read your clipboard.",
    };
    private readonly Choice battery = new()
    {
        Title = "Notify when the battery is low",
        Text = "Once, at 20%, unless it's charging.",
    };
    private readonly TextBlock pairedWith = new() { FontSize = 13 };
    private readonly TextBlock appLinked = new() { FontSize = 13 };
    private readonly Button forget = new() { Content = "Set up a phone again…" };
    private static readonly int[] Limits = [50, 200, 500];

    /// The user asked to set up a phone again (after forgetting this one).
    public event Action? SetupRequested;

    public SettingsWindow()
    {
        notificationApps = new NotificationApps(open => Content = open ? notificationApps!.Page : settingsPage);
        Title = "Nearside settings";
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Nearside.ico"));
        SystemBackdrop = new MicaBackdrop();
        if (AppWindow.Presenter is OverlappedPresenter presenter) presenter.IsMaximizable = false;

        mirror.Toggled += on => EngineHost.Command("set", new { key = "mirrorNotifications", value = on });
        clipboard.Toggled += on => EngineHost.Command("set", new { key = "clipboardSync", value = on });
        texts.Toggled += on => EngineHost.Command("set", new { key = "textMessages", value = on });
        calls.Toggled += on => EngineHost.Command("set", new { key = "showCalls", value = on });
        ring.Toggled += on => EngineHost.Command("set", new { key = "ringHere", value = on });
        screenshots.Toggled += on => EngineHost.Command("set", new { key = "screenshotsToPC", value = on });
        recentPhotos.Toggled += on => EngineHost.Command("set", new { key = "recentPhotos", value = on });
        screenshotsToPhone.Toggled += on => EngineHost.Command("set", new { key = "screenshotsToPhone", value = on });
        startup.Toggled += on => Startup.IsOn = on;
        startMenu.IsOn = PhoneAppShortcuts.On;
        startMenu.Toggled += PhoneAppShortcuts.SetOn;
        arrival.IsOn = ArrivalCard.On;
        arrival.Toggled += on => ArrivalCard.On = on;
        toast.Toggled += on => EngineHost.Command("setClipboardToastHidden", new { hidden = on });
        battery.Toggled += on => EngineHost.Command("set", new { key = "lowBatteryAlert", value = on });
        foreach (var limit in Limits) historyLimit.Items.Add($"{limit} items");
        historyLimit.SelectionChanged += (_, _) =>
        {
            var limit = Limits[Math.Max(0, historyLimit.SelectedIndex)];
            if (limit != EngineHost.Current.Settings.HistoryLimit) EngineHost.Command("set", new { key = "historyLimit", value = limit });
        };
        foreach (var fps in FrameRates) frameRate.Items.Add($"{fps} fps");
        frameRate.SelectedIndex = Math.Max(0, Array.IndexOf(FrameRates, EngineHost.Current.Settings.FrameRate));
        frameRate.SelectionChanged += (_, _) =>
            EngineHost.Command("set", new { key = "frameRate", value = FrameRates[Math.Max(0, frameRate.SelectedIndex)] });
        cameraSide.SelectedIndex = Video.CameraFeed.Front ? 1 : 0;
        cameraSide.SelectionChanged += (_, _) => Video.CameraFeed.Front = cameraSide.SelectedIndex == 1;
        foreach (var mode in HelloModes) hello.Items.Add(mode);
        hello.SelectedIndex = (int)AuthGate.Current;
        hello.SelectionChanged += async (_, _) =>
        {
            var wanted = (AuthGate.Mode)Math.Max(0, hello.SelectedIndex);
            if (wanted == AuthGate.Current) return;
            // Less protection only with Hello's say-so.
            if (wanted < AuthGate.Current
                && !await AuthGate.ConfirmAsync(Microsoft.UI.Win32Interop.GetWindowFromWindowId(AppWindow.Id), "Change when Nearside asks for Windows Hello"))
            {
                hello.SelectedIndex = (int)AuthGate.Current;
                return;
            }
            AuthGate.Current = wanted;
        };
        forget.Click += async (_, _) =>
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Content.XamlRoot,
                Title = $"Forget {EngineHost.Current.PhoneName}?",
                Content = "This PC stops syncing with it until you set it up again.",
                PrimaryButtonText = "Forget",
                CloseButtonText = "Cancel",
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            EngineHost.Command("resetSetup");
            Close();
            SetupRequested?.Invoke();
        };

        var page = new StackPanel { Spacing = 8, Padding = new Thickness(28, 20, 28, 28), MaxWidth = 720 };
        page.Children.Add(new TextBlock { Text = "Settings", FontSize = 28, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 8) });
        page.Children.Add(Header("Features"));
        page.Children.Add(clipboard);
        page.Children.Add(mirror);
        page.Children.Add(recentPhotos);
        page.Children.Add(texts);
        page.Children.Add(calls);
        page.Children.Add(new TextBlock
        {
            Text = "Turned off, a feature leaves the panel and nothing of it crosses between your devices.",
            FontSize = 12, Foreground = Blocks.Secondary, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(2, 2, 0, 0),
        });
        page.Children.Add(Header("Notifications"));
        page.Children.Add(notificationApps.Entry);
        page.Children.Add(Header("Calls"));
        page.Children.Add(ring);
        page.Children.Add(Header("Screenshots"));
        page.Children.Add(screenshots);
        page.Children.Add(screenshotsToPhone);
        page.Children.Add(Header("Phone apps"));
        page.Children.Add(Row("Ask for Windows Hello", "Phone apps work while your phone is locked, so this PC asks before showing them.", hello));
        page.Children.Add(Row("Open the launcher", "From anywhere: Ctrl+Alt+N.", new TextBlock()));
        page.Children.Add(startMenu);
        page.Children.Add(Row("Frame rate", "Above 60, scrolling is smoother on a fast screen; it needs good Wi-Fi and Android 14 or later. For windows opened from now on.", frameRate));
        page.Children.Add(Header("Phone camera"));
        page.Children.Add(Row("Camera", "Apps on this PC can use your phone as a webcam: choose \u201CNearside Camera\u201D. The back camera is the better one; this takes effect the next time an app starts it.", cameraSide));
        page.Children.Add(Header("Clipboard"));
        page.Children.Add(Row("Keep in history", "Older items are removed as new ones arrive.", historyLimit));
        page.Children.Add(arrival);
        page.Children.Add(toast);
        page.Children.Add(Header("Phone"));
        page.Children.Add(Row("Paired with", null, pairedWith));
        page.Children.Add(Row("Phone app", null, appLinked));
        page.Children.Add(battery);
        page.Children.Add(Row("Use another phone, or pair again", null, forget));
        page.Children.Add(Header("General"));
        page.Children.Add(startup);
        var version = typeof(SettingsWindow).Assembly.GetName().Version;
        page.Children.Add(new TextBlock { Text = $"Nearside {version?.ToString(3) ?? "dev"}", FontSize = 12, Foreground = Blocks.Secondary, Margin = new Thickness(0, 12, 0, 0) });
        settingsPage = new ScrollViewer { Content = page };
        Content = settingsPage;
        if (EngineHost.IsDemo && Environment.GetCommandLineArgs().Contains("--apps")) notificationApps.Open(); // its screenshot

        EngineHost.Changed += Render;
        Closed += (_, _) => { EngineHost.Changed -= Render; notificationApps.Detach(); };
        Render(EngineHost.Current);
    }

    public void ShowCentered()
    {
        var hwnd = Microsoft.UI.Win32Interop.GetWindowFromWindowId(AppWindow.Id);
        var scale = Win32.GetDpiForWindow(hwnd) / 96.0;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(640 * scale), (int)(720 * scale)));
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Move(new Windows.Graphics.PointInt32(area.X + (area.Width - AppWindow.Size.Width) / 2,
                                                         area.Y + (area.Height - AppWindow.Size.Height) / 2));
        Activate();
    }

    private void Render(Snapshot s)
    {
        mirror.IsOn = s.Settings.MirrorNotifications;
        clipboard.IsOn = s.Settings.ClipboardSync;
        texts.IsOn = s.Settings.TextMessages;
        calls.IsOn = s.Settings.ShowCalls;
        calls.CanChange = s.Settings.MirrorNotifications; // calls come from the phone's call notification
        ring.IsOn = s.Settings.RingHere;
        ring.CanChange = s.Settings.MirrorNotifications && s.Settings.ShowCalls;
        historyLimit.IsEnabled = arrival.CanChange = s.Settings.ClipboardSync;
        notificationApps.Render(s);
        screenshots.IsOn = s.Settings.ScreenshotsToPC;
        recentPhotos.IsOn = s.Settings.RecentPhotos;
        screenshotsToPhone.IsOn = s.Settings.ScreenshotsToPhone;
        battery.IsOn = s.Settings.LowBatteryAlert;
        startup.IsOn = Startup.IsOn;
        var limit = Array.IndexOf(Limits, s.Settings.HistoryLimit);
        if (limit >= 0 && historyLimit.SelectedIndex != limit) historyLimit.SelectedIndex = limit;
        // The phone's own switch: shown once the connected phone has said how it's set.
        toast.Visibility = s.Connected && s.ClipboardToastHidden != null ? Visibility.Visible : Visibility.Collapsed;
        toast.IsOn = s.ClipboardToastHidden ?? false;
        pairedWith.Text = s.NeedsSetup ? "Nothing yet" : s.PhoneName;
        appLinked.Text = !s.Connected ? "Not connected" : s.AppLinked ? "Linked" : "Not linked";
        forget.IsEnabled = !s.NeedsSetup;
    }

    private static TextBlock Header(string text) => new()
    {
        Text = text, FontSize = 14, FontWeight = FontWeights.SemiBold, Margin = new Thickness(2, 14, 0, 2),
    };

    /// A card with a label (and a line of explanation) and a control on the right.
    private static Border Row(string title, string? text, FrameworkElement control)
    {
        var words = new StackPanel { Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(new TextBlock { Text = title, FontSize = 14, TextWrapping = TextWrapping.Wrap });
        if (text != null) words.Children.Add(new TextBlock { Text = text, FontSize = 12.5, Foreground = Blocks.Secondary, TextWrapping = TextWrapping.Wrap });
        var grid = new Grid { ColumnSpacing = 14 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(words);
        control.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);
        return new Border
        {
            Padding = new Thickness(14),
            CornerRadius = new CornerRadius(10),
            Background = (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"],
            Child = grid,
        };
    }
}
