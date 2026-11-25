using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Nearside.Engine;

namespace Nearside;

/// A small card above the taskbar's corner when a clip arrives from the phone, as the Mac's under
/// the menu bar: who sent it and its start, for four seconds. It never takes focus from what
/// you're doing; click it to dismiss it. Off in Settings ("ShowArrivalCard").
public sealed class ArrivalCard
{
    public const string SettingKey = "ShowArrivalCard";
    public static bool On
    {
        get => AppSettings.Get(SettingKey) != "0";
        set => AppSettings.Set(SettingKey, value ? "1" : "0");
    }

    private Window? window;
    /// The card's window once shown (for the demo's screenshots).
    public Window? Window => window;
    private readonly TextBlock title = new() { FontSize = 12, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBlock text = new() { FontSize = 12, MaxLines = 2, TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(4) };

    public ArrivalCard()
    {
        timer.Tick += (_, _) => Hide();
        EngineHost.Event += (name, e) =>
        {
            if (name != "clip" || !On) return;
            var id = e.GetProperty("id").GetString();
            // The snapshot that has it comes with the same change: look once it's in.
            Soon(() =>
            {
                if (EngineHost.Current.History.FirstOrDefault(c => c.Id == id) is { } clip) Show(clip, EngineHost.Current.PhoneName);
            });
        };
    }

    private static void Soon(Action action)
    {
        var queue = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        queue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => action());
    }

    internal void Show(Clip clip, string phoneName)
    {
        window ??= Make();
        title.Text = $"From {(phoneName.Length > 0 ? phoneName : "your phone")}  ·  copied to this PC";
        text.Text = clip.Text.Trim();
        Place(window);
        window.AppWindow.Show(activateWindow: false);
        timer.Stop();
        timer.Start();
    }

    private void Hide()
    {
        timer.Stop();
        window?.AppWindow.Hide();
    }

    private Window Make()
    {
        var w = new Window { Title = "Copied from your phone", SystemBackdrop = new DesktopAcrylicBackdrop() };
        var presenter = OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.IsAlwaysOnTop = true;
        presenter.SetBorderAndTitleBar(hasBorder: true, hasTitleBar: false);
        w.AppWindow.SetPresenter(presenter);
        w.AppWindow.IsShownInSwitchers = false;
        w.AppWindow.Closing += (_, e) => { e.Cancel = true; Hide(); };
        var icon = new FontIcon { Glyph = "", FontSize = 18, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) };
        var words = new StackPanel { Spacing = 3, Children = { title, text } };
        var grid = new Grid { Padding = new Thickness(13, 11, 13, 11), ColumnSpacing = 11, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(icon);
        Grid.SetColumn(words, 1);
        grid.Children.Add(words);
        grid.Tapped += (_, _) => Hide();
        w.Content = grid;
        return w;
    }

    /// Bottom right, above the taskbar (where the tray is), as the call card.
    private static void Place(Window w)
    {
        var area = DisplayArea.GetFromWindowId(w.AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var scale = Win32.GetDpiForWindow(Microsoft.UI.Win32Interop.GetWindowFromWindowId(w.AppWindow.Id)) / 96.0;
        int width = (int)(340 * scale), height = (int)(78 * scale), margin = (int)(12 * scale);
        w.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(area.X + area.Width - width - margin, area.Y + area.Height - height - margin, width, height));
    }
}
