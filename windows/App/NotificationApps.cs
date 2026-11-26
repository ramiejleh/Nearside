using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Nearside.Engine;

namespace Nearside;

/// Settings → Notifications → Apps: a switch per phone app. A muted app's notifications never
/// reach this PC (the phone doesn't send them); its calls still ring. Apps that have sent
/// notifications come first, then the rest of the phone's apps (asked for when it opens).
internal sealed class NotificationApps
{
    public Expander Root { get; } = new() { HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };

    private readonly TextBlock summary = new() { FontSize = 12.5, TextWrapping = TextWrapping.Wrap };
    private readonly TextBox search = new() { PlaceholderText = "Search apps" };
    private readonly StackPanel list = new() { Spacing = 2 };
    private readonly TextBlock empty = new() { FontSize = 12.5, TextWrapping = TextWrapping.Wrap };
    /// The phone's apps (package → name) and icon files (package → path), from "apps" and "appIcons".
    private readonly Dictionary<string, string> phoneApps = [];
    private readonly Dictionary<string, string> idToPackage = [];
    private readonly Dictionary<string, string> icons = [];
    private string shown = "";

    public NotificationApps()
    {
        summary.Foreground = Blocks.Secondary;
        empty.Foreground = Blocks.Secondary;
        Root.Header = new StackPanel
        {
            Spacing = 3, Padding = new Thickness(0, 10, 0, 10),
            Children = { new TextBlock { Text = "Apps", FontSize = 14 }, summary },
        };
        Root.Content = new StackPanel { Spacing = 8, Children = { search, empty, list } };
        search.TextChanged += (_, _) => Render(EngineHost.Current, force: true);
        Root.Expanding += (_, _) => { if (phoneApps.Count == 0) EngineHost.Command("listApps"); };
        EngineHost.Event += OnEvent;
        Root.IsExpanded = EngineHost.IsDemo; // the demo's screenshot shows the list
    }

    public void Detach() => EngineHost.Event -= OnEvent;

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
            Render(EngineHost.Current, force: true);
        }
        else if (name == "appIcons")
        {
            foreach (var icon in e.GetProperty("icons").EnumerateObject())
            {
                if (idToPackage.TryGetValue(icon.Name, out var package)) icons.TryAdd(package, icon.Value.GetProperty("path").GetString() ?? "");
            }
            Render(EngineHost.Current, force: true);
        }
    }

    public void Render(Snapshot s, bool force = false)
    {
        Root.IsEnabled = s.Settings.MirrorNotifications;
        summary.Text = s.MutedApps.Count == 0
            ? "All apps' notifications show here. Turn one off to never see its notifications on this PC."
            : $"{s.MutedApps.Count} muted on this PC. Their calls still ring.";
        var names = new Dictionary<string, string>(phoneApps);
        foreach (var (package, name) in s.NotifyingApps) names.TryAdd(package, name);
        foreach (var package in s.MutedApps) names.TryAdd(package, package);
        var query = search.Text.Trim();
        var rows = names
            .Where(n => query.Length == 0 || n.Value.Contains(query, StringComparison.CurrentCultureIgnoreCase) || n.Key.Contains(query, StringComparison.OrdinalIgnoreCase))
            .OrderBy(n => s.NotifyingApps.ContainsKey(n.Key) ? 0 : 1).ThenBy(n => n.Value, StringComparer.CurrentCultureIgnoreCase)
            .ToList();
        var signature = string.Join("|", rows.Select(r => r.Key)) + "#" + string.Join(",", s.MutedApps) + "#" + icons.Count;
        if (!force && signature == shown) return;
        shown = signature;
        empty.Text = query.Length > 0 ? "No app matches." : "Your phone's apps show here once it's connected.";
        empty.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        list.Children.Clear();
        foreach (var (package, name) in rows) list.Children.Add(Row(package, name, !s.MutedApps.Contains(package)));
    }

    private UIElement Row(string package, string name, bool on)
    {
        var grid = new Grid { ColumnSpacing = 10, Padding = new Thickness(0, 2, 0, 2) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var path = icons.GetValueOrDefault(package) is { Length: > 0 } launcher && File.Exists(launcher) ? launcher : Notifications.IconFile(package);
        UIElement icon = path != null
            ? new Image { Source = new BitmapImage(new Uri(path)), Width = 20, Height = 20 }
            : new Border { Width = 20, Height = 20, CornerRadius = new CornerRadius(5), Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"] };
        grid.Children.Add(icon);
        var label = new TextBlock { Text = name, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        Grid.SetColumn(label, 1);
        grid.Children.Add(label);
        var toggle = new ToggleSwitch { IsOn = on, OnContent = "", OffContent = "", MinWidth = 0 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(toggle, $"Notifications from {name}");
        toggle.Toggled += (_, _) => EngineHost.Command("setAppMuted", new { package, muted = !toggle.IsOn });
        Grid.SetColumn(toggle, 2);
        grid.Children.Add(toggle);
        return grid;
    }
}
