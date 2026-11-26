using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Nearside.Engine;

namespace Nearside;

/// The phone's current notifications as cards, newest first (the panel's Notifications tab and
/// the phone window's list): click one to open it on the phone, use its buttons, reply, "Open on
/// PC", or × to dismiss it (on the phone too). Built in code; redrawn only when the list changes.
internal sealed class NotificationList
{
    public Grid Root { get; } = new();
    /// Opened on the PC (the phone window opens it in itself).
    public Action<PhoneNote>? OpenHere { get; set; }

    private readonly StackPanel cards = new() { Spacing = 8, Padding = new Thickness(12, 4, 12, 12) };
    private readonly ScrollViewer scroller;
    private readonly StackPanel empty = new() { Spacing = 6, VerticalAlignment = VerticalAlignment.Center, Padding = new Thickness(32, 0, 32, 0) };
    private readonly TextBlock emptyTitle = new() { FontSize = 13, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock emptyText = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center };
    private readonly Button turnOn = new() { Content = "Turn on", HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 6, 0, 0) };
    private string shownSignature = "";
    /// The card whose reply box is open (its key, which button), kept across redraws.
    private (string Key, int Index)? replying;

    public NotificationList()
    {
        scroller = new ScrollViewer { Content = cards, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        emptyText.Foreground = Blocks.Secondary;
        empty.Children.Add(new FontIcon { Glyph = "", FontSize = 26, Foreground = Blocks.Secondary, Margin = new Thickness(0, 0, 0, 4) });
        empty.Children.Add(emptyTitle);
        empty.Children.Add(emptyText);
        empty.Children.Add(turnOn);
        turnOn.Click += (_, _) => EngineHost.Command("set", new { key = "mirrorNotifications", value = true });
        Root.Children.Add(scroller);
        Root.Children.Add(empty);
    }

    public void Render(Snapshot s)
    {
        var phone = s.PhoneName.Length > 0 ? s.PhoneName : "your phone";
        var list = s.Notifications;
        var off = !s.Settings.MirrorNotifications;
        empty.Visibility = off || list.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        scroller.Visibility = empty.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
        turnOn.Visibility = off ? Visibility.Visible : Visibility.Collapsed;
        emptyTitle.Text = off ? "Phone notifications are off" : "No notifications";
        emptyText.Text = off ? "Turn them on to see your phone's notifications here." : $"New ones from {phone} show here.";
        // Redrawn when the list changes (and each minute, for the ages), not on every snapshot.
        var signature = string.Join("\n", list.Select(n => $"{n.Key}|{n.Title}|{n.Text}|{n.Actions.Count}")) + $"|{DateTime.Now:HHmm}|{replying}";
        if (signature == shownSignature) return;
        shownSignature = signature;
        if (replying is { } r && !list.Any(n => n.Key == r.Key)) replying = null;
        cards.Children.Clear();
        foreach (var note in list) cards.Children.Add(Card(note));
    }

    private UIElement Card(PhoneNote note)
    {
        var card = new Border
        {
            Padding = new Thickness(12, 10, 8, 10), CornerRadius = new CornerRadius(8),
            Background = (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"],
            BorderBrush = (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"], BorderThickness = new Thickness(1),
        };
        var body = new StackPanel { Spacing = 3 };

        // App icon, name and age, then × at the right.
        var top = new Grid { ColumnSpacing = 6 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (Notifications.IconFile(note.Package) is { } icon)
        {
            top.Children.Add(new Image { Source = new BitmapImage(new Uri(icon)), Width = 16, Height = 16, VerticalAlignment = VerticalAlignment.Center });
        }
        var meta = new TextBlock { Text = $"{note.App}  ·  {Age(note.When)}", FontSize = 11.5, Foreground = Blocks.Secondary, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(meta, 1);
        top.Children.Add(meta);
        var dismiss = new Button
        {
            Content = new FontIcon { Glyph = "", FontSize = 10 }, Padding = new Thickness(6), Style = (Style)Application.Current.Resources["SubtleButtonStyle"],
        };
        ToolTipService.SetToolTip(dismiss, "Dismiss");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(dismiss, $"Dismiss {note.App} notification");
        dismiss.Click += (_, _) => EngineHost.Command("phoneNotifDismiss", new { key = note.Key });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        if (note.Package.Length > 0)
        {
            var mute = new MenuFlyoutItem { Text = $"Mute notifications from {note.App}", Icon = new FontIcon { Glyph = "\uE7ED" } };
            mute.Click += (_, _) => EngineHost.Command("setAppMuted", new { package = note.Package, muted = true });
            var more = new Button
            {
                Content = new FontIcon { Glyph = "\uE712", FontSize = 11 }, Padding = new Thickness(6), Style = (Style)Application.Current.Resources["SubtleButtonStyle"],
                Flyout = new MenuFlyout { Items = { mute } },
            };
            ToolTipService.SetToolTip(more, "More");
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(more, $"More for {note.App} notification");
            buttons.Children.Add(more);
        }
        buttons.Children.Add(dismiss);
        Grid.SetColumn(buttons, 2);
        top.Children.Add(buttons);
        body.Children.Add(top);

        // Title and text: click to open it on the phone.
        var words = new StackPanel { Spacing = 2, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), Margin = new Thickness(0, 0, 4, 0) };
        if (note.Title.Length > 0) words.Children.Add(new TextBlock { Text = note.Title, FontSize = 13, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, MaxLines = 2, TextTrimming = TextTrimming.CharacterEllipsis });
        if (note.Text.Length > 0) words.Children.Add(new TextBlock { Text = note.Text, FontSize = 12.5, TextWrapping = TextWrapping.Wrap, MaxLines = 4, TextTrimming = TextTrimming.CharacterEllipsis });
        words.Tapped += (_, _) => EngineHost.Command("phoneNotifOpen", new { key = note.Key, here = false });
        ToolTipService.SetToolTip(words, "Open on the phone");
        body.Children.Add(words);

        // Its buttons, a reply box when one takes text, and "Open on PC".
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(0, 6, 0, 0) };
        for (var i = 0; i < note.Actions.Count && i < 3; i++)
        {
            var index = i;
            var action = note.Actions[i];
            var button = new Button { Content = action.Title, FontSize = 12, Padding = new Thickness(10, 4, 10, 5) };
            button.Click += (_, _) =>
            {
                if (action.Reply)
                {
                    replying = (note.Key, index);
                    shownSignature = ""; // redraw with the box
                    Render(EngineHost.Current);
                }
                else
                {
                    EngineHost.Command("notifAction", new { key = note.Key, i = index });
                }
            };
            actions.Children.Add(button);
        }
        if (note.Package.Length > 0)
        {
            var here = new Button { Content = "Open on PC", FontSize = 12, Padding = new Thickness(10, 4, 10, 5) };
            here.Click += (_, _) =>
            {
                if (OpenHere != null) OpenHere(note);
                else EngineHost.Command("phoneNotifOpen", new { key = note.Key, here = true });
            };
            actions.Children.Add(here);
        }
        if (replying is { } r && r.Key == note.Key && r.Index < note.Actions.Count)
        {
            body.Children.Add(ReplyBox(note, r.Index));
        }
        else if (actions.Children.Count > 0)
        {
            body.Children.Add(new ScrollViewer
            {
                Content = actions, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, HorizontalScrollMode = ScrollMode.Enabled,
                VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollMode = ScrollMode.Disabled,
            });
        }
        card.Child = body;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(card, $"{note.App}: {note.Title}. {note.Text}");
        return card;
    }

    private UIElement ReplyBox(PhoneNote note, int index)
    {
        var grid = new Grid { ColumnSpacing = 6, Margin = new Thickness(0, 6, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var box = new TextBox { PlaceholderText = note.Actions[index].Title };
        var send = new Button { Content = new FontIcon { Glyph = "", FontSize = 13 }, Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        ToolTipService.SetToolTip(send, "Send");
        void Send()
        {
            if (box.Text.Trim().Length == 0) return;
            EngineHost.Command("notifAction", new { key = note.Key, i = index, text = box.Text });
            replying = null;
            shownSignature = "";
            Render(EngineHost.Current);
        }
        send.Click += (_, _) => Send();
        box.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter) { Send(); e.Handled = true; }
            else if (e.Key == Windows.System.VirtualKey.Escape) { replying = null; shownSignature = ""; Render(EngineHost.Current); e.Handled = true; }
        };
        box.Loaded += (_, _) => box.Focus(FocusState.Programmatic);
        grid.Children.Add(box);
        Grid.SetColumn(send, 1);
        grid.Children.Add(send);
        return grid;
    }

    /// "now", "5m", "3h", else the day ("21 Nov").
    private static string Age(DateTimeOffset when)
    {
        var seconds = (DateTimeOffset.Now - when).TotalSeconds;
        if (seconds < 60) return "now";
        if (seconds < 3600) return $"{(int)(seconds / 60)}m";
        if (seconds < 24 * 3600) return $"{(int)(seconds / 3600)}h";
        return when.LocalDateTime.ToString("d MMM");
    }
}
