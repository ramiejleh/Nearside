using System.Text.Json;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Nearside.Engine;

namespace Nearside;

/// Settings → Notifications → Apps: a page of its own (its long list is built only while open),
/// with a switch per phone app. A muted app's notifications never reach this PC (the phone
/// doesn't send them); its calls still ring. Apps that have sent notifications come first.
internal sealed class NotificationApps
{
    /// The row in Settings that opens the page.
    public Button Entry { get; }
    public Grid Page { get; } = new();

    private readonly TextBlock entryText = new() { FontSize = 12.5, TextWrapping = TextWrapping.Wrap };
    private readonly TextBox search = new() { PlaceholderText = "Search apps" };
    private readonly StackPanel list = new() { Spacing = 2 };
    private readonly TextBlock empty = new() { FontSize = 12.5, TextWrapping = TextWrapping.Wrap };
    private readonly Action<bool> show;
    /// The phone's apps (package → name) and icon files (package → path), from "apps" and "appIcons".
    private readonly Dictionary<string, string> phoneApps = [];
    private readonly Dictionary<string, string> idToPackage = [];
    private readonly Dictionary<string, (string Path, bool Adaptive)> icons = [];
    /// The phone's icons have started to come (or waited long enough): rows wait for them, so
    /// they don't show one kind of icon and then switch to another.
    private bool iconsReady;
    private bool open;
    private string shown = "";
    /// The rows' switches, by package: muting one only updates the switches, never rebuilds the list.
    private readonly Dictionary<string, ToggleSwitch> toggles = [];

    /// `show(true)` swaps Settings for the page, `show(false)` back.
    public NotificationApps(Action<bool> show)
    {
        this.show = show;
        entryText.Foreground = Blocks.Secondary;
        empty.Foreground = Blocks.Secondary;
        var words = new StackPanel { Spacing = 3, Children = { new TextBlock { Text = "Apps", FontSize = 14 }, entryText } };
        var grid = new Grid { ColumnSpacing = 14 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(words);
        var chevron = new FontIcon { Glyph = "", FontSize = 12, Foreground = Blocks.Secondary, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(chevron, 1);
        grid.Children.Add(chevron);
        Entry = new Button
        {
            Content = grid, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(14), CornerRadius = new CornerRadius(10),
            Background = (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"], BorderThickness = new Thickness(0),
        };
        Entry.Click += (_, _) => Open();

        var back = new Button
        {
            Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { new FontIcon { Glyph = "", FontSize = 12 }, new TextBlock { Text = "Settings" } } },
            Style = (Style)Application.Current.Resources["SubtleButtonStyle"],
        };
        back.Click += (_, _) => Close();
        var top = new StackPanel
        {
            Spacing = 8, Padding = new Thickness(28, 16, 28, 8),
            Children =
            {
                back,
                new TextBlock { Text = "Notifications from apps", FontSize = 22, FontWeight = FontWeights.SemiBold },
                new TextBlock { Text = "Turn an app off and its notifications never come to this PC. Its calls still ring.", FontSize = 12.5, Foreground = Blocks.Secondary, TextWrapping = TextWrapping.Wrap },
                search,
            },
        };
        Page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Page.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Page.Children.Add(top);
        var scroller = new ScrollViewer { Content = new StackPanel { Padding = new Thickness(28, 4, 28, 28), Children = { empty, list } } };
        Grid.SetRow(scroller, 1);
        Page.Children.Add(scroller);
        Page.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Escape) { Close(); e.Handled = true; } };
        search.TextChanged += (_, _) => Render(EngineHost.Current, force: true);
        EngineHost.Event += OnEvent;
    }

    public void Detach() => EngineHost.Event -= OnEvent;

    public void Open()
    {
        open = true;
        if (phoneApps.Count == 0) EngineHost.Command("listApps");
        if (!iconsReady)
        {
            var wait = Page.DispatcherQueue.CreateTimer();
            wait.Interval = TimeSpan.FromSeconds(2);
            wait.IsRepeating = false;
            wait.Tick += (_, _) =>
            {
                if (iconsReady) return;
                iconsReady = true;
                if (open) Render(EngineHost.Current, force: true);
            };
            wait.Start();
        }
        show(true);
        Render(EngineHost.Current, force: true);
    }

    private void Close()
    {
        open = false;
        list.Children.Clear(); // nothing of it kept while closed
        toggles.Clear();
        shown = "";
        show(false);
    }

    private void OnEvent(string name, JsonElement e)
    {
        if (name == "apps" && e.TryGetProperty("apps", out var apps))
        {
            foreach (var app in apps.EnumerateArray())
            {
                var package = app.GetProperty("package").GetString() ?? "";
                if (package.Length == 0) continue;
                phoneApps.TryAdd(package, app.GetProperty("label").GetString() ?? package);
                idToPackage[app.GetProperty("id").GetString() ?? ""] = package;
            }
            if (open) Render(EngineHost.Current, force: true);
        }
        else if (name == "appIcons")
        {
            foreach (var icon in e.GetProperty("icons").EnumerateObject())
            {
                if (idToPackage.TryGetValue(icon.Name, out var package))
                {
                    icons.TryAdd(package, (icon.Value.GetProperty("path").GetString() ?? "", icon.Value.GetProperty("adaptive").GetBoolean()));
                }
            }
            iconsReady = true;
            if (open) Render(EngineHost.Current, force: true);
        }
    }

    public void Render(Snapshot s, bool force = false)
    {
        Entry.IsEnabled = s.Settings.MirrorNotifications;
        entryText.Text = s.MutedApps.Count == 0
            ? "Choose which apps' notifications show on this PC."
            : $"{s.MutedApps.Count} muted on this PC. Their calls still ring.";
        if (!open) return;
        if (!iconsReady && s.Connected)
        {
            empty.Text = "Loading your phone's apps…";
            empty.Visibility = Visibility.Visible;
            list.Children.Clear();
            toggles.Clear();
            shown = "";
            return;
        }
        var names = new Dictionary<string, string>(phoneApps);
        foreach (var (package, name) in s.NotifyingApps) names[package] = names.GetValueOrDefault(package) ?? name;
        foreach (var package in s.MutedApps) names.TryAdd(package, package);
        var query = search.Text.Trim();
        var rows = names
            .Where(n => query.Length == 0 || n.Value.Contains(query, StringComparison.CurrentCultureIgnoreCase) || n.Key.Contains(query, StringComparison.OrdinalIgnoreCase))
            .OrderBy(n => n.Value, StringComparer.CurrentCultureIgnoreCase)
            .ToList();
        var signature = string.Join("|", rows.Select(r => r.Key)) + "#" + string.Join(",", rows.Where(r => s.NotifyingApps.ContainsKey(r.Key)).Select(r => r.Key)) + "#" + icons.Count;
        if (!force && signature == shown)
        {
            // The same rows: only the switches follow (a mute from here, or from the Mac's list).
            foreach (var (package, toggle) in toggles) toggle.IsOn = !s.MutedApps.Contains(package);
            return;
        }
        shown = signature;
        empty.Text = query.Length > 0 ? "No app matches." : "Your phone's apps show here once it's connected.";
        empty.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        list.Children.Clear();
        toggles.Clear();
        void Section(string title, IEnumerable<KeyValuePair<string, string>> part)
        {
            var items = part.ToList();
            if (items.Count == 0) return;
            list.Children.Add(new TextBlock { Text = title, FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = Blocks.Secondary, Margin = new Thickness(0, 10, 0, 4) });
            foreach (var (package, name) in items) list.Children.Add(Row(package, name, !s.MutedApps.Contains(package)));
        }
        Section("Have sent notifications", rows.Where(r => s.NotifyingApps.ContainsKey(r.Key)));
        Section("Other apps", rows.Where(r => !s.NotifyingApps.ContainsKey(r.Key)));
    }

    private UIElement Row(string package, string name, bool on)
    {
        var grid = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 3, 0, 3) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        // The launcher's icon (adaptive ones in the same rounded shape as the launcher shows them);
        // the notification's only for an app the launcher doesn't list.
        var icon = new Border { Width = 24, Height = 24, CornerRadius = new CornerRadius(6), Background = (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"] };
        string? path = null;
        if (icons.TryGetValue(package, out var launcher) && File.Exists(launcher.Path))
        {
            path = launcher.Path;
            if (!launcher.Adaptive) icon.CornerRadius = new CornerRadius(0);
        }
        else if (!phoneApps.ContainsKey(package))
        {
            path = Notifications.IconFile(package);
        }
        if (path != null) icon.Background = new ImageBrush { ImageSource = new BitmapImage(new Uri(path)) { DecodePixelWidth = 48 }, Stretch = Stretch.UniformToFill };
        grid.Children.Add(icon);
        var label = new TextBlock { Text = name, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        Grid.SetColumn(label, 1);
        grid.Children.Add(label);
        var toggle = new ToggleSwitch { IsOn = on, OnContent = "", OffContent = "", MinWidth = 0 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(toggle, $"Notifications from {name}");
        toggle.Toggled += (_, _) =>
        {
            // Only a change the snapshot doesn't already have (setting IsOn from it toggles too).
            var muted = !toggle.IsOn;
            if (EngineHost.Current.MutedApps.Contains(package) != muted) EngineHost.Command("setAppMuted", new { package, muted });
        };
        toggles[package] = toggle;
        Grid.SetColumn(toggle, 2);
        grid.Children.Add(toggle);
        return grid;
    }
}
