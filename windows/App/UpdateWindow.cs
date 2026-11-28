using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Nearside;

/// Nearside's own "update available" window, in the app's style (WinSparkle's is a classic dialog
/// that doesn't follow dark mode). Shows the new version's notes from the feed; Install hands over
/// to WinSparkle, which downloads, checks the signature and runs the installer.
internal sealed class UpdateWindow : Window
{
    private static UpdateWindow? shown;
    public static UpdateWindow? Current => shown;

    /// One at a time: a new check replaces what an open one says.
    public static void Show(Updates.Release? release, string? error = null)
    {
        shown?.Close();
        shown = new UpdateWindow(release, error);
        shown.Closed += (s, _) => { if (shown == s) shown = null; };
        shown.ShowCentered();
    }

    private UpdateWindow(Updates.Release? release, string? error)
    {
        Title = release != null ? "Nearside update" : "Nearside";
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Nearside.ico"));
        SystemBackdrop = new MicaBackdrop();
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
        }

        var page = new Grid { Padding = new Thickness(28, 24, 28, 24), RowSpacing = 16 };
        page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        page.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var header = new Grid { ColumnSpacing = 16 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.Children.Add(new Image
        {
            Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Logo.png"))),
            Width = 56, Height = 56, VerticalAlignment = VerticalAlignment.Top,
        });
        var titles = new StackPanel { Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(new TextBlock
        {
            Text = release != null ? $"Nearside {release.Version} is available" : error != null ? "Couldn't check for updates" : "Nearside is up to date",
            FontSize = 20, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap,
        });
        titles.Children.Add(new TextBlock
        {
            Text = release != null ? $"You have {Updates.Version}. The update takes a moment, and Nearside opens again by itself."
                : error ?? $"You have the newest version, {Updates.Version}.",
            Foreground = Blocks.Secondary, TextWrapping = TextWrapping.Wrap,
        });
        Grid.SetColumn(titles, 1);
        header.Children.Add(titles);
        page.Children.Add(header);

        if (release != null && release.Notes.Count > 0)
        {
            var notes = new StackPanel { Spacing = 10 };
            notes.Children.Add(new TextBlock { Text = "What's new", FontWeight = FontWeights.SemiBold });
            foreach (var note in release.Notes)
            {
                var row = new Grid { ColumnSpacing = 10 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse
                {
                    Width = 6, Height = 6, Margin = new Thickness(2, 7, 0, 0), VerticalAlignment = VerticalAlignment.Top,
                    Fill = (Brush)Application.Current.Resources["AccentFillColorDefaultBrush"],
                });
                var text = new TextBlock { Text = note, TextWrapping = TextWrapping.Wrap, LineHeight = 20 };
                Grid.SetColumn(text, 1);
                row.Children.Add(text);
                notes.Children.Add(row);
            }
            var card = new Border
            {
                Padding = new Thickness(18, 14, 18, 16), CornerRadius = new CornerRadius(8),
                Background = (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"],
                BorderBrush = (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"], BorderThickness = new Thickness(1),
                Child = new ScrollViewer { Content = notes, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
            };
            Grid.SetRow(card, 1);
            page.Children.Add(card);
        }

        var buttons = new Grid { ColumnSpacing = 8 };
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (release != null)
        {
            var skip = new Button { Content = "Skip This Version" };
            skip.Click += (_, _) => { Updates.Skip(release); Close(); };
            buttons.Children.Add(skip);
            var later = new Button { Content = "Later" };
            later.Click += (_, _) => Close();
            Grid.SetColumn(later, 2);
            buttons.Children.Add(later);
            var install = new Button { Content = "Install and Restart", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
            install.Click += (_, _) => { Close(); Updates.Install(); };
            Grid.SetColumn(install, 3);
            buttons.Children.Add(install);
        }
        else
        {
            var ok = new Button { Content = "OK", MinWidth = 96, Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
            ok.Click += (_, _) => Close();
            Grid.SetColumn(ok, 3);
            buttons.Children.Add(ok);
        }
        Grid.SetRow(buttons, 2);
        page.Children.Add(buttons);
        Content = page;
        height = release != null && release.Notes.Count > 0 ? Math.Min(560, 250 + release.Notes.Count * 46) : 210;
    }

    private readonly int height;

    private void ShowCentered()
    {
        var hwnd = Microsoft.UI.Win32Interop.GetWindowFromWindowId(AppWindow.Id);
        var scale = Win32.GetDpiForWindow(hwnd) / 96.0;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(540 * scale), (int)(height * scale)));
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Move(new Windows.Graphics.PointInt32(area.X + (area.Width - AppWindow.Size.Width) / 2,
                                                         area.Y + (area.Height - AppWindow.Size.Height) / 2));
        Activate();
    }
}
