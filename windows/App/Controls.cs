using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Nearside;

/// A setting with an explanation and a switch, on a soft card.
public sealed class Choice : UserControl
{
    private readonly TextBlock title = new() { FontSize = 14, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock text = new() { FontSize = 12.5, TextWrapping = TextWrapping.Wrap };
    private readonly ToggleSwitch toggle = new() { OnContent = "", OffContent = "", MinWidth = 0, VerticalAlignment = VerticalAlignment.Top };
    private bool updating;

    /// The user flipped the switch.
    public event Action<bool>? Toggled;

    public Choice()
    {
        text.Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        var words = new StackPanel { Spacing = 3, Children = { title, text } };
        var grid = new Grid { ColumnSpacing = 14 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(words);
        Grid.SetColumn(toggle, 1);
        grid.Children.Add(toggle);
        Content = new Border
        {
            Padding = new Thickness(14),
            CornerRadius = new CornerRadius(10),
            Background = (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"],
            Child = grid,
        };
        toggle.Toggled += (_, _) =>
        {
            if (!updating) Toggled?.Invoke(toggle.IsOn);
        };
    }

    public string Title { get => title.Text; set => title.Text = value; }
    public string Text { get => text.Text; set => text.Text = value; }

    /// Shows a value without reporting it as a change.
    public bool IsOn
    {
        get => toggle.IsOn;
        set
        {
            if (toggle.IsOn == value) return;
            updating = true;
            toggle.IsOn = value;
            updating = false;
        }
    }

    public bool CanChange { get => toggle.IsEnabled; set => toggle.IsEnabled = value; }
}

/// Small building blocks shared by the windows.
internal static class Blocks
{
    public static Brush Secondary => (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
    public static Brush Accent => (Brush)Application.Current.Resources["AccentTextFillColorPrimaryBrush"];

    /// An icon in a soft tile, a title and a line of text.
    public static UIElement Feature(string glyph, string title, string text)
    {
        var grid = new Grid { ColumnSpacing = 14 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new Border
        {
            Width = 34, Height = 34, CornerRadius = new CornerRadius(8), VerticalAlignment = VerticalAlignment.Top,
            Background = (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"],
            Child = new FontIcon { Glyph = glyph, FontSize = 16, Foreground = Accent },
        });
        var words = new StackPanel
        {
            Spacing = 2,
            Children =
            {
                new TextBlock { Text = title, FontSize = 14, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap },
                new TextBlock { Text = text, FontSize = 13, Foreground = Secondary, TextWrapping = TextWrapping.Wrap },
            },
        };
        Grid.SetColumn(words, 1);
        grid.Children.Add(words);
        return grid;
    }

    /// A numbered step. `**bold**` parts of the text are set in bold.
    public static UIElement Instruction(int number, string text)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new Border
        {
            Width = 22, Height = 22, CornerRadius = new CornerRadius(11), VerticalAlignment = VerticalAlignment.Top,
            Background = (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"],
            Child = new TextBlock
            {
                Text = number.ToString(), FontSize = 11, FontWeight = FontWeights.Bold, Foreground = Accent,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            },
        });
        var block = new TextBlock { FontSize = 13.5, TextWrapping = TextWrapping.Wrap };
        var parts = text.Split("**");
        for (var i = 0; i < parts.Length; i++)
        {
            var run = new Microsoft.UI.Xaml.Documents.Run { Text = parts[i] };
            if (i % 2 == 1) run.FontWeight = FontWeights.SemiBold;
            block.Inlines.Add(run);
        }
        Grid.SetColumn(block, 1);
        grid.Children.Add(block);
        return grid;
    }

    /// Stacks elements in a grid's rows (the grid's RowSpacing spaces them).
    public static void Fill(Grid grid, params UIElement[] rows)
    {
        grid.Children.Clear();
        grid.RowDefinitions.Clear();
        for (var i = 0; i < rows.Length; i++)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow((FrameworkElement)rows[i], i);
            grid.Children.Add(rows[i]);
        }
    }
}
