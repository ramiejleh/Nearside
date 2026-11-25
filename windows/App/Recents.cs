using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Nearside;

/// The phone window's Recents, drawn here as on the Mac: a card per app open in the window (its
/// last picture, icon and name), newest first. Click a card to switch to it, x to close the app,
/// click outside or Esc to go back.
internal sealed class Recents
{
    public sealed record Entry(int Id, string Package, string? Label, string? Icon);

    public Grid Root { get; } = new()
    {
        Visibility = Visibility.Collapsed,
        Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0xD9, 0x10, 0x10, 0x12)),
    };
    public bool Shown => Root.Visibility == Visibility.Visible;
    /// For the test hook's log: how many apps, and how many have their picture.
    public (int Apps, int Pictures) Counts => (entries.Count, pictures.Values.Count(p => p.Background is ImageBrush));

    private readonly Action<int> pick, remove;
    private readonly Action home;
    private readonly StackPanel cards = new() { Orientation = Orientation.Horizontal, Spacing = 16, VerticalAlignment = VerticalAlignment.Center };
    private readonly ScrollViewer scroller;
    private readonly Dictionary<int, Border> pictures = [];
    private List<Entry> entries = [];

    public Recents(Action<int> pick, Action<int> remove, Action home)
    {
        this.pick = pick;
        this.remove = remove;
        this.home = home;
        scroller = new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, HorizontalScrollMode = ScrollMode.Enabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollMode = ScrollMode.Disabled,
            Content = cards,
        };
        Root.Tapped += (_, e) => { Hide(); e.Handled = true; }; // outside the cards (they handle their own)
        Root.SizeChanged += (_, _) => Layout();
    }

    public void Show()
    {
        entries = [];
        pictures.Clear();
        Root.Children.Clear();
        Root.Children.Add(new ProgressRing { IsActive = true, Width = 28, Height = 28 }); // until the phone answers
        Root.Visibility = Visibility.Visible;
    }

    public void Hide() => Root.Visibility = Visibility.Collapsed;

    public void SetTasks(List<Entry> list)
    {
        if (!Shown) return;
        entries = list;
        pictures.Clear();
        Root.Children.Clear();
        if (list.Count == 0)
        {
            var homeButton = new Button { Content = "Home", HorizontalAlignment = HorizontalAlignment.Center };
            homeButton.Click += (_, _) => { Hide(); home(); };
            Root.Children.Add(new StackPanel
            {
                Spacing = 14, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center,
                Children =
                {
                    new TextBlock { Text = "No recent apps", FontSize = 16, FontWeight = FontWeights.SemiBold, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) },
                    homeButton,
                },
            });
            return;
        }
        Root.Children.Add(scroller);
        Layout();
    }

    public async Task SetSnapshotAsync(int task, byte[] image)
    {
        if (!pictures.TryGetValue(task, out var picture) || image.Length == 0) return;
        try
        {
            using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            await stream.WriteAsync(image.AsBuffer());
            stream.Seek(0);
            var bitmap = new BitmapImage();
            await bitmap.SetSourceAsync(stream);
            picture.Background = new ImageBrush { ImageSource = bitmap, Stretch = Stretch.UniformToFill };
        }
        catch (Exception e)
        {
            Log.Info($"recents: a picture didn't load ({e.GetType().Name})");
        }
    }

    /// Cards as tall as most of the screen, shaped like it, the first one centred.
    private void Layout()
    {
        if (entries.Count == 0) return;
        double width = Root.ActualWidth, height = Root.ActualHeight;
        if (width <= 0 || height <= 0) return;
        var cardHeight = height * 0.62;
        var cardWidth = cardHeight * width / height;
        var keep = pictures.ToDictionary(p => p.Key, p => p.Value.Background);
        cards.Children.Clear();
        pictures.Clear();
        cards.Padding = new Thickness(Math.Max(0, (width - cardWidth) / 2), 0, Math.Max(0, (width - cardWidth) / 2), 0);
        foreach (var entry in entries) cards.Children.Add(Card(entry, cardWidth, cardHeight, keep.GetValueOrDefault(entry.Id)));
    }

    private UIElement Card(Entry entry, double width, double height, Brush? picture)
    {
        var name = entry.Label ?? entry.Package;
        var header = new Grid { Width = width, ColumnSpacing = 6 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (entry.Icon != null && File.Exists(entry.Icon))
        {
            header.Children.Add(new Image { Source = new BitmapImage(new Uri(entry.Icon)), Width = 20, Height = 20 });
        }
        var label = new TextBlock
        {
            Text = name, FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White),
            TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(label, 1);
        header.Children.Add(label);
        var close = new Button
        {
            Content = new FontIcon { Glyph = "", FontSize = 12 }, Padding = new Thickness(6),
            Style = (Style)Application.Current.Resources["SubtleButtonStyle"], Foreground = new SolidColorBrush(Microsoft.UI.Colors.White),
        };
        ToolTipService.SetToolTip(close, $"Close {name}");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(close, $"Close {name}");
        close.Click += (_, _) =>
        {
            remove(entry.Id);
            entries = entries.Where(e => e.Id != entry.Id).ToList();
            if (entries.Count == 0) SetTasks([]); else Layout();
        };
        Grid.SetColumn(close, 2);
        header.Children.Add(close);

        var screen = new Border
        {
            Width = width, Height = height, CornerRadius = new CornerRadius(16),
            Background = picture ?? new SolidColorBrush(Windows.UI.Color.FromArgb(0x14, 0xFF, 0xFF, 0xFF)),
        };
        pictures[entry.Id] = screen;
        screen.Tapped += (_, e) =>
        {
            e.Handled = true;
            Hide();
            pick(entry.Id);
        };
        var card = new StackPanel { Spacing = 8, Children = { header, screen } };
        card.Tapped += (_, e) => e.Handled = true; // the header isn't "outside"
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(screen, name);
        return card;
    }
}
