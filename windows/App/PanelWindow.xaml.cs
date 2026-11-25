using System.Collections.ObjectModel;
using System.Diagnostics;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Nearside.Engine;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace Nearside;

/// The panel the tray icon opens (the Mac's menu-bar panel). It hides when it loses focus, as the
/// system's own flyouts do.
public sealed partial class PanelWindow : Window
{
    private const int WidthDips = 380, HeightDips = 540;

    public event Action? SetupRequested;
    public event Action? SettingsRequested;
    public event Action? PhoneRequested;
    public event Action? MessagesRequested;
    public bool IsShown { get; private set; }

    private readonly ObservableCollection<ClipRow> clips = [];
    private readonly ObservableCollection<TransferRow> transfers = [];
    private readonly DispatcherTimer clock = new() { Interval = TimeSpan.FromSeconds(30) };
    /// Phone clips unseen when the panel opened: tagged "New" while it stays open.
    private HashSet<string> highlighted = [];
    /// A dialog of ours (the file picker) is up: losing focus to it doesn't close the panel.
    private bool keepOpen;

    public PanelWindow()
    {
        InitializeComponent();
        Title = "Nearside";
        SystemBackdrop = new DesktopAcrylicBackdrop();
        LogoImage.Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Logo.png")));
        HistoryList.ItemsSource = clips;
        TransferList.ItemsSource = transfers;

        var presenter = OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.IsAlwaysOnTop = true;
        presenter.SetBorderAndTitleBar(hasBorder: true, hasTitleBar: false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        AppWindow.Closing += (_, e) =>
        {
            e.Cancel = true; // the panel is reused: closing it only hides it
            HidePanel();
        };
        Activated += (_, e) =>
        {
            if (e.WindowActivationState == WindowActivationState.Deactivated && !keepOpen) HidePanel();
        };
        clock.Tick += (_, _) => Render(EngineHost.Current);
        EngineHost.Changed += Render;
        EngineHost.Event += (name, e) =>
        {
            if (name == "photoFetched") PhotoFetched(e);
        };
        Render(EngineHost.Current);
    }

    internal void ShowNearTray(TrayIcon tray)
    {
        var hwnd = Microsoft.UI.Win32Interop.GetWindowFromWindowId(AppWindow.Id);
        var scale = Win32.GetDpiForWindow(hwnd) / 96.0;
        int width = (int)(WidthDips * scale), height = (int)(HeightDips * scale), margin = (int)(12 * scale);
        // Next to the icon, inside the screen's work area (whichever edge the taskbar is on).
        var icon = tray.Bounds ?? default;
        int cx = (icon.left + icon.right) / 2, cy = (icon.top + icon.bottom) / 2;
        var work = Win32.WorkArea(cx, cy);
        var x = Math.Clamp(cx - width / 2, work.left + margin, work.right - width - margin);
        var y = Math.Clamp(cy - height / 2, work.top + margin, work.bottom - height - margin);
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(x, y, width, height));

        highlighted = [.. EngineHost.Current.Unseen];
        EngineHost.Command("markAllSeen");
        Render(EngineHost.Current);
        EngineHost.Command("panelOpen", new { open = true }); // the phone's recent photos, while it's open
        AppWindow.Show();
        Activate();
        Win32.SetForegroundWindow(hwnd);
        IsShown = true;
        clock.Start();
    }

    public void HidePanel()
    {
        if (IsShown) EngineHost.Command("panelOpen", new { open = false });
        AppWindow.Hide();
        IsShown = false;
        clock.Stop();
        DropOverlay.Visibility = Visibility.Collapsed;
    }

    private void Render(Snapshot s)
    {
        var phone = s.PhoneName.Length > 0 ? s.PhoneName : "your phone";
        // The status pill.
        (Windows.UI.Color color, string text) = s.State switch
        {
            "connected" => (Colors.LimeGreen, s.OverUSB ? $"{phone} (USB)" : phone),
            "searching" when s.InUseOn != null => (Colors.Gray, $"In use on {s.InUseOn}"),
            "searching" => (Colors.Orange, $"Looking for {phone}…"),
            _ => (Colors.Gray, "Not set up"),
        };
        StatusDot.Fill = new SolidColorBrush(color);
        StatusText.Text = text;
        var battery = s.Connected ? s.PhoneStatus : null;
        BatteryText.Visibility = battery != null ? Visibility.Visible : Visibility.Collapsed;
        if (battery != null) BatteryText.Text = $"{battery.Battery}%{(battery.Charging ? " charging" : "")}";
        SendFilesButton.IsEnabled = s.Connected;
        PhoneButton.IsEnabled = s.Connected;
        MessagesButton.IsEnabled = !s.NeedsSetup;

        SetupPrompt.Visibility = s.NeedsSetup ? Visibility.Visible : Visibility.Collapsed;
        Main.Visibility = s.NeedsSetup ? Visibility.Collapsed : Visibility.Visible;
        if (s.NeedsSetup) return;

        InUseBar.IsOpen = s.InUseOn != null && !s.Connected;
        InUseBar.Title = $"{phone} is in use on {s.InUseOn}";
        InUseBar.Message = "This PC reconnects once it's free.";
        ProblemBar.IsOpen = s.PhoneAppProblem != null;
        if (s.PhoneAppProblem is { } problem)
        {
            ProblemBar.Title = $"Nearside on {phone} needs updating";
            ProblemBar.Message = problem.Kind == "otherSignature"
                ? "The installed phone app is from another build, so it can't be updated in place."
                : problem.Message ?? "";
            ReinstallButton.Visibility = problem.Kind == "otherSignature" ? Visibility.Visible : Visibility.Collapsed;
            ReinstallButton.IsEnabled = !s.ReinstallingPhoneApp;
        }

        Sync(transfers, s.Transfers.Select(t => new TransferRow(t, phone)).ToList());
        TransferList.Visibility = transfers.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        RenderPhotos(s);

        var query = SearchBox.Text.Trim();
        var shown = s.History.Where(c => FilterBox.SelectedIndex switch
            {
                1 => !c.FromPhone,
                2 => c.FromPhone,
                _ => true,
            })
            .Where(c => query.Length == 0 || c.Text.Contains(query, StringComparison.CurrentCultureIgnoreCase))
            .Select(c => new ClipRow(c, phone, highlighted.Contains(c.Id)))
            .ToList();
        Sync(clips, shown);
        var filtering = query.Length > 0 || FilterBox.SelectedIndex != 0;
        EmptyHistory.Visibility = shown.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyTitle.Text = filtering ? "Nothing matches" : "Nothing copied yet";
        EmptyText.Text = filtering ? "Try other words, or show everything."
            : $"Copy text on this PC or on your {phone} and it shows up here, ready on both.";
        var count = s.History.Count;
        FooterText.Text = count == 0 ? "" : $"{Items(count)}  ·  Click to copy to both devices";
        ClearButton.IsEnabled = count > 0;
        ClearQuestion.Text = $"Delete all {Items(count)}?";
    }

    // MARK: Photos

    private readonly Dictionary<long, BitmapImage> thumbnails = [];
    private List<long> shownPhotos = [];
    private static readonly HashSet<string> ImageTypes = [".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif", ".bmp", ".avif", ".tif", ".tiff"];

    /// The phone's recent photos and screenshots (newest first): click one to open it here.
    private void RenderPhotos(Snapshot s)
    {
        var items = s.Connected ? s.Photos?.Items ?? [] : [];
        PhotoScroller.Visibility = items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        var ids = items.Select(p => p.Id).ToList();
        var missing = items.Where(p => p.Thumbnail && !thumbnails.ContainsKey(p.Id)).ToList();
        foreach (var photo in missing) LoadThumbnail(photo.Id);
        foreach (var gone in thumbnails.Keys.Except(ids).ToList()) thumbnails.Remove(gone);
        if (ids.SequenceEqual(shownPhotos) && missing.Count == 0) return;
        shownPhotos = ids;
        PhotoStrip.Children.Clear();
        foreach (var photo in items) PhotoStrip.Children.Add(PhotoTile(photo));
    }

    private unsafe void LoadThumbnail(long id)
    {
        var p = Native.PhotoThumbnail(id, out var length);
        if (p == null) return;
        byte[] jpeg;
        try
        {
            jpeg = new ReadOnlySpan<byte>(p, length).ToArray();
        }
        finally
        {
            Native.Free(p);
        }
        var image = new BitmapImage { DecodePixelHeight = 128 };
        thumbnails[id] = image;
        _ = SetSourceAsync(image, jpeg);
    }

    private static async Task SetSourceAsync(BitmapImage image, byte[] jpeg)
    {
        using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
        await stream.WriteAsync(System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsBuffer(jpeg));
        stream.Seek(0);
        await image.SetSourceAsync(stream);
    }

    private UIElement PhotoTile(PhonePhoto photo)
    {
        var tile = new Button
        {
            Width = 64, Height = 64, Padding = new Thickness(0), CornerRadius = new CornerRadius(8),
            Background = thumbnails.TryGetValue(photo.Id, out var image)
                ? new ImageBrush { ImageSource = image, Stretch = Stretch.UniformToFill }
                : (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"],
        };
        ToolTipService.SetToolTip(tile, $"{(photo.IsScreenshot ? "Screenshot" : "Photo")}, {DateTimeOffset.FromUnixTimeMilliseconds(photo.Date).LocalDateTime:g}");
        tile.Click += (_, _) => EngineHost.Command("photoFetch", new { id = photo.Id, @for = "open" });
        var save = new MenuFlyoutItem { Text = "Save to Downloads", Icon = new FontIcon { Glyph = "\uE896" } };
        save.Click += (_, _) => EngineHost.Command("photoFetch", new { id = photo.Id, @for = "save" });
        var open = new MenuFlyoutItem { Text = "Open", Icon = new FontIcon { Glyph = "\uE8A7" } };
        open.Click += (_, _) => EngineHost.Command("photoFetch", new { id = photo.Id, @for = "open" });
        tile.ContextFlyout = new MenuFlyout { Items = { open, save } };
        return tile;
    }

    /// A photo pulled from the phone (marked as downloaded): opened in its app, or kept in Downloads.
    private void PhotoFetched(System.Text.Json.JsonElement e)
    {
        if (!e.TryGetProperty("path", out var p) || p.GetString() is not { } path || !File.Exists(path)) return;
        var explorer = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe");
        if (e.GetProperty("for").GetString() == "save")
        {
            var downloads = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
            var target = Path.Combine(downloads, Path.GetFileName(path));
            for (var n = 2; File.Exists(target); n++)
            {
                target = Path.Combine(downloads, $"{Path.GetFileNameWithoutExtension(path)} ({n}){Path.GetExtension(path)}");
            }
            File.Copy(path, target); // with its Mark of the Web
            Process.Start(explorer, $"/select,\"{target}\"");
        }
        else if (ImageTypes.Contains(Path.GetExtension(path).ToLowerInvariant()))
        {
            // Only pictures open directly (the name comes from the phone): anything else is shown in its folder.
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }
        else
        {
            Process.Start(explorer, $"/select,\"{path}\"");
        }
    }

    private static string Items(int count) => count == 1 ? "1 item" : $"{count} items";

    /// Updates a shown list in place (keeps the scroll position and unchanged rows).
    private static void Sync<T>(ObservableCollection<T> shown, List<T> wanted)
    {
        if (shown.SequenceEqual(wanted)) return;
        for (var i = 0; i < wanted.Count; i++)
        {
            if (i < shown.Count && Equals(shown[i], wanted[i])) continue;
            var existing = shown.IndexOf(wanted[i]);
            if (existing > i) shown.Move(existing, i);
            else if (i < shown.Count) shown[i] = wanted[i];
            else shown.Add(wanted[i]);
        }
        while (shown.Count > wanted.Count) shown.RemoveAt(shown.Count - 1);
    }

    private void OnSearch(object sender, TextChangedEventArgs e) => Render(EngineHost.Current);
    private void OnFilter(object sender, SelectionChangedEventArgs e) => Render(EngineHost.Current);

    private void OnClipClick(object sender, ItemClickEventArgs e) => EngineHost.Command("use", new { id = ((ClipRow)e.ClickedItem).Id });
    private void OnUseClip(object sender, RoutedEventArgs e) => EngineHost.Command("use", new { id = (string)((FrameworkElement)sender).Tag });
    private void OnDeleteClip(object sender, RoutedEventArgs e) => EngineHost.Command("delete", new { id = (string)((FrameworkElement)sender).Tag });

    private void OnClearAll(object sender, RoutedEventArgs e)
    {
        ClearFlyout.Hide();
        EngineHost.Command("clearHistory");
    }

    private void OnUseHere(object sender, RoutedEventArgs e) => EngineHost.Command("useHere");
    private void OnSetUp(object sender, RoutedEventArgs e) => SetupRequested?.Invoke();
    private void OnSettings(object sender, RoutedEventArgs e) => SettingsRequested?.Invoke();

    private void OnMessages(object sender, RoutedEventArgs e)
    {
        HidePanel();
        MessagesRequested?.Invoke();
    }

    private void OnPhone(object sender, RoutedEventArgs e)
    {
        HidePanel();
        PhoneRequested?.Invoke();
    }

    private async void OnReinstall(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Reinstall the phone app?",
            Content = "The phone app is removed and installed again. Its permissions are set up again automatically; nothing on this PC changes.",
            PrimaryButtonText = "Reinstall",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) EngineHost.Command("reinstallPhoneApp");
    }

    private void OnShowTransfer(object sender, RoutedEventArgs e)
    {
        var id = (string)((FrameworkElement)sender).Tag;
        var path = EngineHost.Current.Transfers.FirstOrDefault(t => t.Id == id)?.Path;
        // Explorer by its full path: never one found in the working directory.
        var explorer = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe");
        if (path != null && File.Exists(path)) Process.Start(explorer, $"/select,\"{path}\"");
    }

    private void OnDismissTransfer(object sender, RoutedEventArgs e) =>
        EngineHost.Command("dismissTransfer", new { id = (string)((FrameworkElement)sender).Tag });

    private async void OnSendFiles(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Microsoft.UI.Win32Interop.GetWindowFromWindowId(AppWindow.Id));
        keepOpen = true;
        try
        {
            var files = await picker.PickMultipleFilesAsync();
            if (files.Count > 0) EngineHost.Command("sendFiles", new { paths = files.Select(f => f.Path).ToArray() });
        }
        finally
        {
            keepOpen = false;
        }
    }

    private void OnDragOver(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var connected = EngineHost.Current.Connected;
        e.AcceptedOperation = connected ? DataPackageOperation.Copy : DataPackageOperation.None;
        var phone = EngineHost.Current.PhoneName;
        DropTitle.Text = connected ? $"Drop to send to your {phone}" : $"{phone} isn't connected";
        DropText.Visibility = connected ? Visibility.Visible : Visibility.Collapsed;
        var brush = connected ? new SolidColorBrush(Colors.LimeGreen) : (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        DropBorder.Stroke = brush;
        DropIcon.Foreground = brush;
        DropOverlay.Visibility = Visibility.Visible;
    }

    private void OnDragLeave(object sender, DragEventArgs e) => DropOverlay.Visibility = Visibility.Collapsed;

    private async void OnDrop(object sender, DragEventArgs e)
    {
        DropOverlay.Visibility = Visibility.Collapsed;
        if (!EngineHost.Current.Connected || !e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        var paths = items.OfType<StorageFile>().Select(f => f.Path).Where(p => p.Length > 0).ToArray();
        if (paths.Length > 0) EngineHost.Command("sendFiles", new { paths });
    }
}

/// A clipboard history row.
public sealed record ClipRow(string Id, string Preview, string Meta, string Glyph, Visibility NewVisibility)
{
    public ClipRow(Clip clip, string phone, bool isNew) : this(
        clip.Id,
        clip.Text.Length > 400 ? clip.Text[..400] : clip.Text,
        $"{(clip.FromPhone ? phone : "This PC")}  ·  {Relative(clip.When)}",
        clip.FromPhone ? "\uE8EA" : "\uE7F4",
        isNew ? Visibility.Visible : Visibility.Collapsed)
    { }

    private static string Relative(DateTimeOffset when)
    {
        var ago = DateTimeOffset.Now - when;
        if (ago.TotalMinutes < 1) return "Just now";
        if (ago.TotalHours < 1) return $"{(int)ago.TotalMinutes} min ago";
        if (ago.TotalDays < 1) return $"{(int)ago.TotalHours} h ago";
        return when.LocalDateTime.Date == DateTime.Today.AddDays(-1) ? "Yesterday" : when.LocalDateTime.ToString("d MMM");
    }
}

/// A file going to or coming from the phone.
public sealed record TransferRow(string Id, string Name, string Status, string Glyph,
    Visibility InProgressVisibility, Visibility ShowVisibility, Visibility DismissVisibility)
{
    public TransferRow(Transfer t, string phone) : this(
        t.Id, t.Name,
        (t.Status, t.ToPhone) switch
        {
            ("inProgress", true) => $"Sending to your {phone}…",
            ("inProgress", false) => $"Receiving from your {phone}…",
            ("done", true) => "Sent  ·  in Download/Nearside on the phone",
            ("done", false) => "Saved to Downloads",
            _ => t.Message ?? "Failed",
        },
        t.ToPhone ? "\uE898" : "\uE896",
        t.Status == "inProgress" ? Visibility.Visible : Visibility.Collapsed,
        t.Status == "done" && t.Path != null ? Visibility.Visible : Visibility.Collapsed,
        t.Status == "inProgress" ? Visibility.Collapsed : Visibility.Visible)
    { }
}
