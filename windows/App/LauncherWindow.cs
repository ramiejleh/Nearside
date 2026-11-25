using System.Collections.ObjectModel;
using System.Text.Json;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Nearside.Engine;

namespace Nearside;

/// The phone's apps, to open one in a window on this PC: type to find one, Enter opens the first.
/// The whole phone screen is the first entry. Closes when it loses focus, as Start does.
public sealed class LauncherWindow : Window
{
    public sealed record AppEntry(string Id, string? Package, string? Activity, string Label, long LastUsed);

    private static readonly List<AppEntry> Apps = [];
    private static readonly Dictionary<string, (string Path, bool Adaptive)> Icons = [];
    private static bool listed;

    private readonly TextBox search = new() { PlaceholderText = "Search your phone's apps", FontSize = 15 };
    private readonly GridView grid = new() { SelectionMode = ListViewSelectionMode.None, IsItemClickEnabled = true, Padding = new Thickness(12, 4, 12, 12) };
    private readonly TextBlock status = new() { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 40, 0, 0), Foreground = Blocks.Secondary };
    private readonly ObservableCollection<AppEntry> shown = [];

    public LauncherWindow()
    {
        Title = "Nearside apps";
        SystemBackdrop = new DesktopAcrylicBackdrop();
        var presenter = OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(hasBorder: true, hasTitleBar: false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;

        grid.ItemsSource = shown;
        grid.ItemTemplate = (DataTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load(
            """
            <DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
                <StackPanel Width="96" Padding="4,8" Spacing="6">
                    <Border Width="48" Height="48" CornerRadius="12" HorizontalAlignment="Center" />
                    <TextBlock FontSize="12" TextAlignment="Center" TextTrimming="CharacterEllipsis" MaxLines="2" TextWrapping="Wrap" />
                </StackPanel>
            </DataTemplate>
            """);
        grid.ContainerContentChanging += (_, e) => Fill((StackPanel)e.ItemContainer.ContentTemplateRoot, (AppEntry)e.Item);
        grid.ItemClick += (_, e) => Launch((AppEntry)e.ClickedItem);
        search.TextChanged += (_, _) => Filter();
        search.KeyDown += OnSearchKey;

        var root = new Grid { Padding = new Thickness(16, 16, 16, 0) };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(search);
        Grid.SetRow(grid, 1);
        Grid.SetRow(status, 1);
        root.Children.Add(grid);
        root.Children.Add(status);
        root.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Escape) Close();
        };
        Content = root;
        Activated += (_, e) =>
        {
            if (e.WindowActivationState == WindowActivationState.Deactivated) Close();
        };
        EngineHost.Event += OnEvent;
        Closed += (_, _) => EngineHost.Event -= OnEvent;

        Filter();
        if (!listed) status.Text = "Asking your phone for its apps…";
        EngineHost.Command("listApps"); // fresh each time (apps come and go); the shown list stays meanwhile
    }

    public void ShowCentered()
    {
        var scale = Win32.GetDpiForWindow(Microsoft.UI.Win32Interop.GetWindowFromWindowId(AppWindow.Id)) / 96.0;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(660 * scale), (int)(520 * scale)));
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Move(new Windows.Graphics.PointInt32(area.X + (area.Width - AppWindow.Size.Width) / 2,
                                                         area.Y + (area.Height - AppWindow.Size.Height) / 3));
        Activate();
        Win32.SetForegroundWindow(Microsoft.UI.Win32Interop.GetWindowFromWindowId(AppWindow.Id));
        search.Focus(FocusState.Programmatic);
    }

    private void OnEvent(string name, JsonElement e)
    {
        if (name == "apps")
        {
            if (e.TryGetProperty("failed", out _))
            {
                if (!listed) status.Text = "Your phone didn't answer. Try again in a moment.";
                return;
            }
            Apps.Clear();
            foreach (var app in e.GetProperty("apps").EnumerateArray())
            {
                Apps.Add(new AppEntry(app.GetProperty("id").GetString()!, app.GetProperty("package").GetString(),
                    app.GetProperty("activity").GetString(), app.GetProperty("label").GetString() ?? "",
                    app.TryGetProperty("lastUsed", out var used) ? used.GetInt64() : 0));
            }
            Apps.Sort((a, b) => string.Compare(a.Label, b.Label, StringComparison.CurrentCultureIgnoreCase));
            listed = true;
            Log.Info($"launcher: {Apps.Count} apps");
            Filter();
        }
        else if (name == "appIcons")
        {
            foreach (var icon in e.GetProperty("icons").EnumerateObject())
            {
                Icons[icon.Name] = (icon.Value.GetProperty("path").GetString()!, icon.Value.GetProperty("adaptive").GetBoolean());
            }
            Log.Info($"launcher: {Icons.Count} icons");
            // Redraw the shown ones that just got theirs.
            foreach (var item in grid.ItemsPanelRoot?.Children.OfType<GridViewItem>() ?? [])
            {
                if (item.Content is AppEntry entry && item.ContentTemplateRoot is StackPanel panel) Fill(panel, entry);
            }
        }
    }

    private void Filter()
    {
        var query = search.Text.Trim();
        var phone = new AppEntry("phone", null, null, "Phone screen", long.MaxValue);
        // With no search: the most recently used first (up to 8), then all by name.
        var matches = query.Length == 0
            ? Apps.Where(a => a.LastUsed > 0).OrderByDescending(a => a.LastUsed).Take(8)
                .Concat(Apps.Where(a => !Apps.Where(r => r.LastUsed > 0).OrderByDescending(r => r.LastUsed).Take(8).Contains(a)))
                .Prepend(phone)
            : Apps.Where(a => a.Label.Contains(query, StringComparison.CurrentCultureIgnoreCase))
                .OrderBy(a => !a.Label.StartsWith(query, StringComparison.CurrentCultureIgnoreCase));
        shown.Clear();
        foreach (var app in matches) shown.Add(app);
        if (listed) status.Text = shown.Count == 0 ? $"No app called “{query}”" : "";
    }

    private static void Fill(StackPanel panel, AppEntry app)
    {
        var border = (Border)panel.Children[0];
        ((TextBlock)panel.Children[1]).Text = app.Label;
        ToolTipService.SetToolTip(panel, app.Label);
        if (app.Package == null)
        {
            border.Background = (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"];
            border.Child = new FontIcon { Glyph = "", FontSize = 22 };
        }
        else if (Icons.TryGetValue(app.Id, out var icon))
        {
            border.Child = null;
            // Adaptive icons are full-bleed: shown in the tile's rounded shape. Others as drawn.
            border.CornerRadius = new CornerRadius(icon.Adaptive ? 12 : 0);
            border.Background = new ImageBrush { ImageSource = new BitmapImage(new Uri(icon.Path)), Stretch = Stretch.UniformToFill };
        }
        else
        {
            border.Child = null;
            border.Background = (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"];
        }
    }

    private void OnSearchKey(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter && shown.Count > 0)
        {
            Launch(shown[0]);
            e.Handled = true;
        }
        else if (e.Key == Windows.System.VirtualKey.Down && shown.Count > 0)
        {
            grid.Focus(FocusState.Keyboard);
            e.Handled = true;
        }
    }

    private void Launch(AppEntry app)
    {
        Close();
        _ = PhoneWindow.OpenAsync(app.Package, app.Activity, app.Package == null ? null : app.Label);
    }
}
