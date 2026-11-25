using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Nearside.Engine;

namespace Nearside;

/// Text messages (SMS): conversations on the left, the selected one on the right. Nothing is kept
/// on this PC: it's all fetched from the phone while the window is open.
public sealed class MessagesWindow : Window
{
    private readonly ListView threads = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly TextBlock conversationTitle = new() { FontSize = 15, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBlock conversationAddress = new() { FontSize = 12, Foreground = Blocks.Secondary };
    private readonly ScrollViewer scroller = new() { Padding = new Thickness(16, 8, 16, 8) };
    private readonly StackPanel bubbles = new() { Spacing = 2 };
    private readonly TextBox compose = new() { PlaceholderText = "Text message", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 120 };
    private readonly Button send = new() { Content = new FontIcon { Glyph = "", FontSize = 14 }, VerticalAlignment = VerticalAlignment.Bottom };
    private readonly TextBlock sendError = new() { FontSize = 12, Foreground = new SolidColorBrush(Microsoft.UI.Colors.IndianRed), TextWrapping = TextWrapping.Wrap };
    private readonly Grid conversation = new();
    private readonly StackPanel notice = new() { Spacing = 10, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, MaxWidth = 340 };
    private readonly Grid split = new();
    private List<MessageThread> shownThreads = [];
    private List<TextMessage> shownMessages = [];
    private long? selected;
    private bool updatingSelection;
    /// Unsent text per conversation: the box always belongs to the one shown, so a draft can never
    /// go to whoever is selected next.
    private readonly Dictionary<long, string> drafts = [];
    /// The conversation the text in the box was typed for.
    private long? composeThread;

    public MessagesWindow()
    {
        Title = "Messages";
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Nearside.ico"));
        SystemBackdrop = new MicaBackdrop();

        // Left: the conversations.
        var newMessage = new Button { Content = new FontIcon { Glyph = "", FontSize = 14 }, Style = (Style)Application.Current.Resources["SubtleButtonStyle"] };
        ToolTipService.SetToolTip(newMessage, "New message");
        newMessage.Click += async (_, _) => await NewMessageAsync();
        var listHeader = new Grid { Padding = new Thickness(16, 12, 8, 8) };
        listHeader.Children.Add(new TextBlock { Text = "Messages", FontSize = 20, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        newMessage.HorizontalAlignment = HorizontalAlignment.Right;
        listHeader.Children.Add(newMessage);
        threads.SelectionChanged += (_, _) =>
        {
            if (updatingSelection || threads.SelectedIndex < 0 || threads.SelectedIndex >= shownThreads.Count) return;
            EngineHost.Command("messagesSelect", new { thread = shownThreads[threads.SelectedIndex].Id });
        };
        var left = new Grid { BorderThickness = new Thickness(0, 0, 1, 0), BorderBrush = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"] };
        left.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        left.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        left.Children.Add(listHeader);
        Grid.SetRow(threads, 1);
        left.Children.Add(threads);

        // Right: the selected conversation.
        var header = new StackPanel { Padding = new Thickness(16, 12, 16, 8), Children = { conversationTitle, conversationAddress } };
        scroller.Content = bubbles;
        send.Click += (_, _) => Send();
        compose.KeyDown += OnComposeKey;
        var composer = new Grid { ColumnSpacing = 8, Padding = new Thickness(16, 8, 16, 12) };
        composer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        composer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        composer.Children.Add(compose);
        Grid.SetColumn(send, 1);
        composer.Children.Add(send);
        var bottom = new StackPanel { Children = { sendError, composer } };
        sendError.Margin = new Thickness(16, 4, 16, 0);
        conversation.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        conversation.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        conversation.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        conversation.Children.Add(header);
        Grid.SetRow(scroller, 1);
        conversation.Children.Add(scroller);
        Grid.SetRow(bottom, 2);
        conversation.Children.Add(bottom);

        split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(300) });
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        split.Children.Add(left);
        Grid.SetColumn(conversation, 1);
        split.Children.Add(conversation);
        Grid.SetColumn(notice, 1);
        split.Children.Add(notice);
        Content = split;

        Activated += (_, e) => EngineHost.Command("messagesActive", new { active = e.WindowActivationState != WindowActivationState.Deactivated });
        Closed += (_, _) =>
        {
            EngineHost.Changed -= Render;
            EngineHost.Command("messagesActive", new { active = false });
            EngineHost.Command("messagesOpen", new { open = false });
        };
        EngineHost.Changed += Render;
        EngineHost.Command("messagesOpen", new { open = true }); // fetches the conversations
        Render(EngineHost.Current);
    }

    public void ShowCentered()
    {
        var scale = Win32.GetDpiForWindow(Microsoft.UI.Win32Interop.GetWindowFromWindowId(AppWindow.Id)) / 96.0;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(900 * scale), (int)(640 * scale)));
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Move(new Windows.Graphics.PointInt32(area.X + (area.Width - AppWindow.Size.Width) / 2,
                                                         area.Y + (area.Height - AppWindow.Size.Height) / 2));
        Activate();
    }

    private void Render(Snapshot s)
    {
        var view = s.Messages;
        // Why there's nothing to show, if so.
        string? why = null, action = null;
        if (!s.Settings.TextMessages)
        {
            why = "Text messages are off. Turn them on to read and send SMS from this PC.";
            action = "Turn on";
        }
        else if (!s.Connected) why = "Texts appear once the phone is back on the same Wi-Fi.";
        else if (view?.Problem is { } problem) why = problem;
        else if (view is { Loaded: true, Threads.Count: 0 }) why = "No texts yet. SMS conversations show up here.";
        else if (view?.Selected == null) why = view?.Loaded == true ? "Plain SMS only: RCS chats stay in Google Messages (reply to those from their notifications)." : null;
        notice.Children.Clear();
        if (why != null)
        {
            notice.Children.Add(new TextBlock { Text = why, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Foreground = Blocks.Secondary });
            if (action != null)
            {
                var turnOn = new Button { Content = action, Style = (Style)Application.Current.Resources["AccentButtonStyle"], HorizontalAlignment = HorizontalAlignment.Center };
                turnOn.Click += (_, _) => EngineHost.Command("set", new { key = "textMessages", value = true });
                notice.Children.Add(turnOn);
            }
        }
        else if (view is { Loaded: false })
        {
            notice.Children.Add(new ProgressRing { IsActive = true });
        }
        notice.Visibility = notice.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        conversation.Visibility = notice.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
        if (view == null) return;

        if (!view.Threads.SequenceEqual(shownThreads))
        {
            shownThreads = view.Threads;
            updatingSelection = true;
            threads.Items.Clear();
            foreach (var t in shownThreads) threads.Items.Add(ThreadRow(t));
            updatingSelection = false;
        }
        var index = shownThreads.FindIndex(t => t.Id == view.Selected);
        if (threads.SelectedIndex != index)
        {
            updatingSelection = true;
            threads.SelectedIndex = index;
            updatingSelection = false;
        }

        var thread = shownThreads.FirstOrDefault(t => t.Id == view.Selected);
        conversationTitle.Text = thread?.Title ?? "";
        conversationAddress.Text = thread != null && thread.Name != null ? thread.Address : "";
        sendError.Text = view.SendError ?? "";
        sendError.Visibility = view.SendError != null ? Visibility.Visible : Visibility.Collapsed;
        if (view.Selected != selected || !view.Conversation.SequenceEqual(shownMessages))
        {
            var atEnd = scroller.VerticalOffset >= scroller.ScrollableHeight - 24 || view.Selected != selected;
            if (view.Selected != selected) SwapDraft(view.Selected);
            selected = view.Selected;
            shownMessages = view.Conversation;
            bubbles.Children.Clear();
            foreach (var m in shownMessages) Bubble(m);
            if (atEnd)
            {
                bubbles.UpdateLayout();
                scroller.ChangeView(null, scroller.ScrollableHeight, null, disableAnimation: true);
            }
        }
    }

    private void SwapDraft(long? next)
    {
        if (composeThread is { } previous)
        {
            if (string.IsNullOrEmpty(compose.Text)) drafts.Remove(previous);
            else drafts[previous] = compose.Text;
        }
        compose.Text = next is { } id && drafts.TryGetValue(id, out var draft) ? draft : "";
        composeThread = next;
    }

    private static UIElement ThreadRow(MessageThread t)
    {
        var grid = new Grid { Padding = new Thickness(0, 6, 0, 6), ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var words = new StackPanel { Spacing = 2 };
        words.Children.Add(new TextBlock { Text = t.Title, FontWeight = t.Unread > 0 ? FontWeights.SemiBold : FontWeights.Normal, TextTrimming = TextTrimming.CharacterEllipsis });
        words.Children.Add(new TextBlock
        {
            Text = (t.Outgoing ? "You: " : "") + t.Snippet.Replace('\n', ' '), FontSize = 12, Foreground = Blocks.Secondary,
            TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 2, TextWrapping = TextWrapping.Wrap,
        });
        grid.Children.Add(words);
        var side = new StackPanel { Spacing = 4, HorizontalAlignment = HorizontalAlignment.Right };
        side.Children.Add(new TextBlock { Text = Short(t.When), FontSize = 11, Foreground = Blocks.Secondary, HorizontalAlignment = HorizontalAlignment.Right });
        if (t.Unread > 0)
        {
            side.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(8), Padding = new Thickness(6, 0, 6, 1), HorizontalAlignment = HorizontalAlignment.Right,
                Background = (Brush)Application.Current.Resources["AccentFillColorDefaultBrush"],
                Child = new TextBlock { Text = t.Unread.ToString(), FontSize = 11, Foreground = (Brush)Application.Current.Resources["TextOnAccentFillColorPrimaryBrush"] },
            });
        }
        Grid.SetColumn(side, 1);
        grid.Children.Add(side);
        return grid;
    }

    private void Bubble(TextMessage m)
    {
        if (m.Header)
        {
            bubbles.Children.Add(new TextBlock
            {
                Text = m.When.LocalDateTime.ToString(m.When.LocalDateTime.Date == DateTime.Today ? "t" : "g"),
                FontSize = 11, Foreground = Blocks.Secondary, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 12, 0, 6),
            });
        }
        // Rounded, with the corners toward the next/previous bubble of the same run tighter.
        double big = 16, small = 4;
        var corners = m.Outgoing
            ? new CornerRadius(big, m.First ? big : small, m.Last ? big : small, big)
            : new CornerRadius(m.First ? big : small, big, big, m.Last ? big : small);
        var bubble = new Border
        {
            CornerRadius = corners, Padding = new Thickness(12, 7, 12, 8), MaxWidth = 420,
            HorizontalAlignment = m.Outgoing ? HorizontalAlignment.Right : HorizontalAlignment.Left,
            Margin = new Thickness(0, m.First ? 6 : 0, 0, 0),
            Background = (Brush)Application.Current.Resources[m.Outgoing ? "AccentFillColorDefaultBrush" : "SubtleFillColorSecondaryBrush"],
            Child = new TextBlock
            {
                Text = m.Body, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
                Foreground = (Brush)Application.Current.Resources[m.Outgoing ? "TextOnAccentFillColorPrimaryBrush" : "TextFillColorPrimaryBrush"],
            },
            Opacity = m.Pending ? 0.6 : 1,
        };
        ToolTipService.SetToolTip(bubble, m.When.LocalDateTime.ToString("f"));
        bubbles.Children.Add(bubble);
        if (m.Failed || (m.Pending && m.Last))
        {
            bubbles.Children.Add(new TextBlock
            {
                Text = m.Failed ? "Not sent" : "Sending…", FontSize = 11, HorizontalAlignment = HorizontalAlignment.Right,
                Foreground = m.Failed ? new SolidColorBrush(Microsoft.UI.Colors.IndianRed) : Blocks.Secondary,
            });
        }
    }

    private static string Short(DateTimeOffset when)
    {
        var local = when.LocalDateTime;
        if (local.Date == DateTime.Today) return local.ToString("t");
        if (local.Date > DateTime.Today.AddDays(-7)) return local.ToString("ddd");
        return local.ToString("d");
    }

    private void OnComposeKey(object sender, KeyRoutedEventArgs e)
    {
        // Enter sends; Shift+Enter is a new line.
        if (e.Key != Windows.System.VirtualKey.Enter) return;
        var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Shift)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        if (shift) return;
        Send();
        e.Handled = true;
    }

    private void Send()
    {
        var thread = shownThreads.FirstOrDefault(t => t.Id == selected);
        // Only to the conversation the text was typed in.
        if (thread == null || composeThread != thread.Id || string.IsNullOrWhiteSpace(compose.Text)) return;
        EngineHost.Command("messagesSend", new { text = compose.Text, address = thread.Address });
        compose.Text = "";
        drafts.Remove(thread.Id);
    }

    private async Task NewMessageAsync()
    {
        var to = new TextBox { Header = "To", PlaceholderText = "Phone number", InputScope = new InputScope { Names = { new InputScopeName(InputScopeNameValue.TelephoneNumber) } } };
        var text = new TextBox { Header = "Message", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 80 };
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "New message",
            Content = new StackPanel { Spacing = 10, Width = 340, Children = { to, text } },
            PrimaryButtonText = "Send",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        if (to.Text.Trim().Length > 0 && text.Text.Trim().Length > 0) EngineHost.Command("messagesSend", new { text = text.Text, address = to.Text.Trim() });
    }
}
