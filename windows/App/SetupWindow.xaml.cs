using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Nearside.Engine;
using QRCoder;

namespace Nearside;

/// First-run setup: what Nearside does, preparing the phone, pairing (a QR code, or a code typed
/// in), the main choices, and where to find things afterwards.
public sealed partial class SetupWindow : Window
{
    private enum Page { Welcome, Phone, Pair, Choices, Done }

    private Page page = Page.Welcome;
    private bool useCode;
    private string? shownQr;

    public SetupWindow()
    {
        InitializeComponent();
        Title = "Set up Nearside";
        AppWindow.SetIcon(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "Nearside.ico"));
        SystemBackdrop = new MicaBackdrop();
        LogoImage.Source = new BitmapImage(new Uri(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "Logo.png")));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
        }

        Blocks.Fill(Features,
            Blocks.Feature("\uE8C8", "Shared clipboard", "Copy on one device, paste on the other. With a searchable history."),
            Blocks.Feature("\uEA8F", "Phone notifications", "See, reply to and dismiss them on your PC."),
            Blocks.Feature("\uE8AB", "Files both ways", "Drop files on the Nearside panel, or use Send to computer from Android's share sheet."),
            Blocks.Feature("\uE8BD", "Text messages", "Read and send SMS from a Messages window."));
        PhoneSteps.Children.Add(Blocks.Instruction(1, "On your phone, open **Settings, About phone** and tap **Build number** 7 times. This turns on Developer options. (Skip this if you already have them.)"));
        PhoneSteps.Children.Add(Blocks.Instruction(2, "Open **Settings, System, Developer options** and turn on **Wireless debugging**."));
        PhoneSteps.Children.Add(Blocks.Instruction(3, "When asked, **allow** wireless debugging on this Wi-Fi network."));
        Blocks.Fill(DonePage,
            Blocks.Feature("\uE8EA", "Click the Nearside icon in the taskbar's corner",
                "for your clipboard history, file transfers and settings. If it's hidden, drag it out of the overflow (^) to keep it in sight."),
            Blocks.Feature("\uE898", "Drop files on the panel", "to send them to your phone."),
            Blocks.Feature("\uE72D", "On your phone, use Share, Send to computer", "to put photos and files in this PC's Downloads."));

        MirrorChoice.Toggled += on => EngineHost.Command("set", new { key = "mirrorNotifications", value = on });
        TextsChoice.Toggled += on => EngineHost.Command("set", new { key = "textMessages", value = on });
        LoginChoice.Toggled += on => Startup.IsOn = on;
        ToastChoice.Toggled += on => EngineHost.Command("setClipboardToastHidden", new { hidden = on });

        AppWindow.Closing += (_, _) => EngineHost.Command("qrStop");
        EngineHost.Changed += OnChanged;
        Closed += (_, _) => EngineHost.Changed -= OnChanged;
        Show(Page.Welcome);
    }

    public void ShowCentered()
    {
        var hwnd = Microsoft.UI.Win32Interop.GetWindowFromWindowId(AppWindow.Id);
        var scale = Win32.GetDpiForWindow(hwnd) / 96.0;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(620 * scale), (int)(600 * scale)));
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Move(new Windows.Graphics.PointInt32(area.X + (area.Width - AppWindow.Size.Width) / 2,
                                                         area.Y + (area.Height - AppWindow.Size.Height) / 2));
        Activate();
    }

    /// Opens a page by name (welcome, phone, pair, choices, done): for the demo's screenshots.
    public void ShowPage(string name)
    {
        if (Enum.TryParse<Page>(name, ignoreCase: true, out var p)) Show(p);
    }

    private void OnChanged(Snapshot s)
    {
        // Pairing ends with the phone connecting: move on by itself.
        if (page == Page.Pair && s.Connected && !s.IsPairing) Show(Page.Choices);
        else Render(s);
    }

    private void Show(Page next)
    {
        if (page == Page.Pair && next != Page.Pair) EngineHost.Command("qrStop");
        if (next == Page.Pair && page != Page.Pair) EngineHost.Command("qrStart"); // listen for a scan only here
        page = next;
        WelcomePage.Visibility = Visible(page == Page.Welcome);
        PhonePage.Visibility = Visible(page == Page.Phone);
        PairPage.Visibility = Visible(page == Page.Pair);
        ChoicesPage.Visibility = Visible(page == Page.Choices);
        DonePage.Visibility = Visible(page == Page.Done);
        Scroller.ChangeView(null, 0, null, disableAnimation: true);

        (PageTitle.Text, PageSubtitle.Text) = page switch
        {
            Page.Welcome => ("Welcome to Nearside", "Your Android phone and this PC, working together. A one-time setup of about two minutes."),
            Page.Phone => ("Prepare your phone", "Nearside connects through Android's Wireless debugging, which lives in Developer options."),
            Page.Pair => ("Pair with your phone", "This links your phone and this PC, once. It stays paired after reboots and Wi-Fi changes."),
            Page.Choices => ("Choose what to sync", "You can change all of these later in the panel's settings."),
            _ => ("You're all set", "Nearside lives in the taskbar's corner and works in the background."),
        };
        LogoImage.Visibility = Visible(page == Page.Welcome);
        PageIcon.Visibility = Visible(page != Page.Welcome);
        PageIcon.Glyph = page switch
        {
            Page.Phone => "\uE8EA",
            Page.Pair => "\uED14",
            Page.Choices => "\uE9E9",
            _ => "\uE73E",
        };
        if (page == Page.Choices) LoginChoice.IsOn = Startup.IsOn;

        Dots.Children.Clear();
        foreach (var p in Enum.GetValues<Page>())
        {
            Dots.Children.Add(new Ellipse
            {
                Width = 7, Height = 7,
                Fill = p == page ? Blocks.Accent : (Brush)Application.Current.Resources["ControlStrongFillColorDisabledBrush"],
            });
        }
        // No going back past a finished pairing.
        BackButton.Visibility = Visible(page is Page.Phone or Page.Pair);
        NextButton.Content = page switch
        {
            Page.Pair => "Waiting for your phone…",
            Page.Done => "Start using Nearside",
            _ => "Continue",
        };
        Render(EngineHost.Current);
    }

    private void Render(Snapshot s)
    {
        NextButton.IsEnabled = page != Page.Pair;
        BackButton.IsEnabled = !s.IsPairing;
        if (page == Page.Choices)
        {
            MirrorChoice.IsOn = s.Settings.MirrorNotifications;
            TextsChoice.IsOn = s.Settings.TextMessages;
            ToastChoice.IsOn = s.ClipboardToastHidden ?? false;
            ToastChoice.CanChange = s.ClipboardToastHidden != null; // known once the phone has said
        }
        if (page != Page.Pair) return;

        PairInstruction.Children.Clear();
        PairInstruction.Children.Add(Blocks.Instruction(1, useCode
            ? "In **Wireless debugging**, tap **Pair device with pairing code** and type what it shows below."
            : "In **Wireless debugging**, tap **Pair device with QR code** and scan this code with the scanner that opens. (The Camera app can't read it.)"));
        QrCard.Visibility = Visible(!useCode);
        CodeForm.Visibility = Visible(useCode);
        SwitchMethod.Content = useCode ? "Scan a QR code instead" : "Use a pairing code";
        SwitchMethod.IsEnabled = !s.IsPairing;

        if (s.QrPayload != null && s.QrPayload != shownQr)
        {
            shownQr = s.QrPayload;
            _ = ShowQrAsync(s.QrPayload);
        }
        QrImage.Opacity = s.IsPairing ? 0.15 : 1;
        QrBusy.IsActive = s.IsPairing;
        QrWaiting.Visibility = Visible(!s.IsPairing);
        QrStatus.Text = s.IsPairing ? "Phone found, setting up…" : "Waiting for your phone to scan…";

        HostPortBox.IsEnabled = CodeBox.IsEnabled = !s.IsPairing;
        PairBusy.IsActive = s.IsPairing;
        PairButtonText.Text = s.IsPairing ? "Setting up…" : "Pair and set up";
        PairButton.IsEnabled = !s.IsPairing && HostPortBox.Text.Contains(':') && CodeBox.Text.Trim().Length >= 6;

        StepsCard.Visibility = Visible(s.SetupSteps.Count > 0);
        StepList.Children.Clear();
        foreach (var step in s.SetupSteps) StepList.Children.Add(StepRow(step));
    }

    private static UIElement StepRow(SetupStep step)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        UIElement mark = step.Status switch
        {
            "running" => new ProgressRing { IsActive = true, Width = 14, Height = 14 },
            "done" => new FontIcon { Glyph = "\uE930", FontSize = 14, Foreground = new SolidColorBrush(Microsoft.UI.Colors.LimeGreen) },
            "failed" => new FontIcon { Glyph = "\uEA39", FontSize = 14, Foreground = new SolidColorBrush(Microsoft.UI.Colors.IndianRed) },
            _ => new FontIcon { Glyph = "\uEA3A", FontSize = 14, Foreground = Blocks.Secondary },
        };
        grid.Children.Add(mark);
        var words = new StackPanel { Spacing = 2 };
        words.Children.Add(new TextBlock { Text = step.Title, FontSize = 13, Foreground = step.Status == "pending" ? Blocks.Secondary : (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"], TextWrapping = TextWrapping.Wrap });
        if (step.Status == "failed" && step.Message != null)
        {
            words.Children.Add(new TextBlock { Text = step.Message, FontSize = 12, Foreground = new SolidColorBrush(Microsoft.UI.Colors.IndianRed), TextWrapping = TextWrapping.Wrap });
        }
        Grid.SetColumn(words, 1);
        grid.Children.Add(words);
        return grid;
    }

    private async Task ShowQrAsync(string payload)
    {
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(payload, QRCodeGenerator.ECCLevel.M);
        var png = new PngByteQRCode(data).GetGraphic(8);
        using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
        await stream.WriteAsync(png.AsBuffer());
        stream.Seek(0);
        var image = new BitmapImage();
        await image.SetSourceAsync(stream);
        if (payload == shownQr) QrImage.Source = image;
    }

    private static Visibility Visible(bool on) => on ? Visibility.Visible : Visibility.Collapsed;

    private void OnNext(object sender, RoutedEventArgs e)
    {
        if (page == Page.Done) Close();
        else Show(page + 1);
    }

    private void OnBack(object sender, RoutedEventArgs e) => Show(page - 1);

    private void OnSwitchMethod(object sender, RoutedEventArgs e)
    {
        useCode = !useCode;
        Render(EngineHost.Current);
    }

    private void OnCodeChanged(object sender, TextChangedEventArgs e) => Render(EngineHost.Current);

    private void OnPair(object sender, RoutedEventArgs e) =>
        EngineHost.Command("pair", new { hostPort = HostPortBox.Text.Trim(), code = CodeBox.Text.Trim() });
}
