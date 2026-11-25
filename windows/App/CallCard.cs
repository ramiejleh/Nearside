using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Nearside.Engine;

namespace Nearside;

/// The call in progress, in a small card above the taskbar's corner for as long as it goes on
/// (not while its app is open in a window, which shows the call itself): who, for how long, where
/// it's talked, and Mute and Hang up.
public sealed class CallCard
{
    private Window? window;
    /// The card's window while a call is shown (for the demo's screenshots).
    public Window? Window => window;
    private readonly TextBlock title = new() { FontSize = 14, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBlock detail = new() { FontSize = 12, Foreground = Blocks.Secondary, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly Border photo = new() { Width = 40, Height = 40, CornerRadius = new CornerRadius(20) };
    private readonly Button route = Round("", "Talk on this PC");
    private readonly Button mute = Round("", "Mute");
    private readonly Button hangUp = Round("", "End call");
    private readonly DispatcherTimer clock = new() { Interval = TimeSpan.FromSeconds(1) };
    private string? shownKey;
    private string? shownPhoto = "-"; // nothing drawn yet

    public CallCard()
    {
        hangUp.Background = new SolidColorBrush(Microsoft.UI.Colors.Firebrick);
        hangUp.Foreground = new SolidColorBrush(Microsoft.UI.Colors.White);
        hangUp.Click += (_, _) => { if (shownKey != null) EngineHost.Command("callAct", new { key = shownKey, action = "hangup" }); };
        mute.Click += (_, _) => EngineHost.Command("callMute", new { on = !EngineHost.Current.Calls.Muted });
        route.Click += (_, _) => EngineHost.Command("callAudio", new { here = !EngineHost.Current.Calls.AudioHere });
        clock.Tick += (_, _) => Render(EngineHost.Current);
        EngineHost.Changed += Render;
    }

    private void Render(Snapshot s)
    {
        var calls = s.Calls;
        var call = calls.Show ? calls.List.FirstOrDefault(c => c.Key == calls.Pinned) : null;
        if (call == null)
        {
            shownKey = null;
            clock.Stop();
            window?.AppWindow.Hide();
            return;
        }
        if (window == null) window = Make();
        if (shownKey != call.Key) clock.Start();
        shownKey = call.Key;
        title.Text = call.Title;
        var place = call.IsPhone ? (calls.AudioHere ? "On this PC" : $"On your {s.PhoneName}") : call.Kind;
        detail.Text = call.Since is { } since
            ? $"{place}  ·  {Duration(DateTimeOffset.Now - DateTimeOffset.FromUnixTimeMilliseconds(since))}"
            : place;
        if (call.Photo != shownPhoto)
        {
            shownPhoto = call.Photo;
            photo.Background = call.Photo != null ? Photo(call.Photo) : (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"];
            photo.Child = call.Photo != null ? null : new FontIcon { Glyph = "", FontSize = 18 };
        }
        // A phone call's sound can move here or back (only with this PC's sound and microphone).
        route.Visibility = call.IsPhone ? Visibility.Visible : Visibility.Collapsed;
        ((FontIcon)route.Content).Glyph = calls.AudioHere ? "" : "";
        ToolTipService.SetToolTip(route, calls.AudioHere ? $"Move the call to your {s.PhoneName}" : "Talk on this PC");
        ((FontIcon)mute.Content).Glyph = calls.Muted ? "" : "";
        ToolTipService.SetToolTip(mute, calls.Muted ? "Unmute" : "Mute");
        mute.Background = calls.Muted ? (Brush)Application.Current.Resources["AccentFillColorDefaultBrush"] : (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"];
        hangUp.IsEnabled = call.Can.Contains("hangup");
        if (!window.AppWindow.IsVisible)
        {
            Place(window);
            window.AppWindow.Show(activateWindow: false); // never takes focus from what you're doing
        }
    }

    private Window Make()
    {
        var w = new Window { Title = "Call", SystemBackdrop = new DesktopAcrylicBackdrop() };
        var presenter = OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.IsAlwaysOnTop = true;
        presenter.SetBorderAndTitleBar(hasBorder: true, hasTitleBar: false);
        w.AppWindow.SetPresenter(presenter);
        w.AppWindow.IsShownInSwitchers = false;
        w.AppWindow.Closing += (_, e) => e.Cancel = true; // goes when the call ends

        var grid = new Grid { Padding = new Thickness(12), ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(photo);
        var words = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Spacing = 2, Children = { title, detail } };
        Grid.SetColumn(words, 1);
        grid.Children.Add(words);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center, Children = { route, mute, hangUp } };
        Grid.SetColumn(buttons, 2);
        grid.Children.Add(buttons);
        w.Content = grid;
        return w;
    }

    /// Bottom right, above the taskbar (where the tray is).
    private static void Place(Window w)
    {
        var area = DisplayArea.GetFromWindowId(w.AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var scale = Win32.GetDpiForWindow(Microsoft.UI.Win32Interop.GetWindowFromWindowId(w.AppWindow.Id)) / 96.0;
        int width = (int)(360 * scale), height = (int)(66 * scale), margin = (int)(12 * scale);
        w.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(area.X + area.Width - width - margin, area.Y + area.Height - height - margin, width, height));
    }

    private static Button Round(string glyph, string tip)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 14 },
            Width = 36, Height = 36, Padding = new Thickness(0), CornerRadius = new CornerRadius(18),
            Background = (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"],
        };
        ToolTipService.SetToolTip(button, tip);
        return button;
    }

    /// The caller's photo, through a file (as Windows' notifications show it).
    private static Brush Photo(string base64)
    {
        try
        {
            var bytes = Convert.FromBase64String(base64);
            var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Nearside", "icons");
            Directory.CreateDirectory(folder);
            var path = Path.Combine(folder, $"caller-{Guid.NewGuid():N}.png"); // a new name: the image cache keys on it
            foreach (var old in Directory.GetFiles(folder, "caller-*.png")) File.Delete(old);
            File.WriteAllBytes(path, bytes);
            return new ImageBrush { ImageSource = new BitmapImage(new Uri(path)), Stretch = Stretch.UniformToFill };
        }
        catch (Exception e) when (e is FormatException or IOException or UnauthorizedAccessException)
        {
            return (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"];
        }
    }

    private static string Duration(TimeSpan t) =>
        t.TotalHours >= 1 ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}" : $"{t.Minutes}:{t.Seconds:00}";
}
