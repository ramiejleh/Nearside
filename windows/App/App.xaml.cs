using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Nearside.Engine;

namespace Nearside;

/// The app lives in the tray: the icon opens the panel; nothing else shows unless asked for.
/// Setup opens by itself until the phone is paired.
public partial class App : Application
{
    private TrayIcon? tray;
    private PanelWindow? panel;
    private SetupWindow? setup;
    private SettingsWindow? settings;
    private Notifications? notifications;
    private CallCard? calls;
    private Video.CameraFeed? camera;
    private DispatcherQueue? queue;

    public App()
    {
        InitializeComponent();
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        UnhandledException += (_, e) => Log.Error($"unhandled: {e.Exception}");
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        queue = DispatcherQueue.GetForCurrentThread();
        panel = new PanelWindow();
        panel.SetupRequested += OpenSetup;
        panel.SettingsRequested += OpenSettings;
        panel.PhoneRequested += OpenLauncher;
        panel.MessagesRequested += OpenMessages;
        tray = new TrayIcon(onSelect: TogglePanel, onSettings: OpenSettings, onQuit: Quit) { OnHotKey = OpenLauncher };
        if (Updates.Available) tray.OnCheckForUpdates = Updates.Check;
        tray.OnLink = OpenLink;
        EngineHost.Changed += snapshot =>
        {
            tray.Update(snapshot);
            if (!snapshot.Connected) launcher?.Close(); // nothing of the phone's while it's out of reach
        };
        SingleInstance.OnShowRequested(() => queue.TryEnqueue(() => panel.ShowNearTray(tray)));
        Log.Info($"started: version {Updates.Version}, build {(Updates.Build.Length > 0 ? Updates.Build : "dev")}");

        var line = Arguments();
        if (line.Contains("--demo"))
        {
            RunDemo(line);
            return;
        }
        notifications = new Notifications(queue);
        calls = new CallCard();
        arrival = new ArrivalCard();
        var apk = Path.Combine(AppContext.BaseDirectory, "phone-app.apk");
        EngineHost.Start(queue, File.Exists(apk) ? apk : null);
        Video.VideoRouter.Install();
        Audio.SoundRouter.Install();
        Audio.MicRouter.Install();
        camera = new Video.CameraFeed(queue) { TestPattern = line.Contains("--camera-test") };
        camera.Start();
        Updates.Start(queue, Quit);
#if NEARSIDE_UPDATE_TEST
        if (line.Contains("--install-update")) Updates.CheckAndInstall();
#endif
        EngineHost.Event += (name, e) =>
        {
            if (name == "session") PhoneWindow.Route(e);
            else if (name == "openApp")
            {
                Log.Info("link: opening it");
                _ = PhoneWindow.OpenAsync(e.GetProperty("package").GetString(), e.GetProperty("activity").GetString(), e.GetProperty("label").GetString());
            }
            else if (name == "openInWindow")
            {
                _ = PhoneWindow.OpenAsync(e.GetProperty("package").GetString(), null, e.GetProperty("app").GetString(), e.GetProperty("key").GetString());
            }
        };
        PhoneAppShortcuts.Start();
        if (LinkArgument() is { } startLink) OpenLink(startLink);
        if (EngineHost.Current.NeedsSetup) OpenSetup();
        // --open-phone: the phone window opens once connected (for testing).
        if (line.Contains("--open-phone"))
        {
            void OpenOnce(Snapshot s)
            {
                if (!s.Connected || !s.AppLinked) return;
                EngineHost.Changed -= OpenOnce;
                if (line.Contains("--launcher")) OpenLauncher();
                else _ = PhoneWindow.OpenAsync();
            }
            EngineHost.Changed += OpenOnce;
        }
    }

    /// --demo [--setup <page> | --settings] [--muted] [--shot <file.png>]: made-up content in the panel (or a
    /// setup page, or settings);
    /// --shot saves the window as drawn, then quits. For screenshots: nothing personal shows.
    private void RunDemo(string[] line)
    {
        string? Value(string flag) => Array.IndexOf(line, flag) is var i and > 0 && i + 1 < line.Length ? line[i + 1] : null;
        var page = Value("--setup");
        EngineHost.StartDemo(setup: page != null, muted: line.Contains("--muted"), away: line.Contains("--away"), photos: line.Contains("--photos"));
        Task saved = Task.CompletedTask;
        var shot = Value("--shot");
        if (line.Contains("--call"))
        {
            calls = new CallCard();
            EngineHost.StartDemo(setup: false); // the card shows itself on the snapshot
            if (shot != null && calls.Window is { } card) saved = Shots.SaveAsync(card, card.Content, shot);
        }
        else if (line.Contains("--arrival"))
        {
            arrival = new ArrivalCard();
            arrival.Show(EngineHost.Current.History.First(c => c.FromPhone), EngineHost.Current.PhoneName);
            if (shot != null && arrival.Window is { } card) saved = Shots.SaveAsync(card, card.Content, shot);
        }
        else if (line.Contains("--update"))
        {
            // The update window, with sample notes (nothing is fetched or installed).
            UpdateWindow.Show(new Updates.Release("0.3.3", 999, [
                "Each phone app gets its own taskbar button with its own icon, and can be pinned there.",
                "Opening an app on the phone keeps its window, with Bring Back.",
                "Typing in a phone app's window always reaches the app.",
            ]));
            if (shot != null && UpdateWindow.Current is { } update) saved = Shots.SaveAsync(update, update.Content, shot);
        }
        else if (line.Contains("--messages"))
        {
            OpenMessages();
            if (shot != null) saved = Shots.SaveAsync(messages!, messages!.Content, shot);
        }
        else if (line.Contains("--launcher"))
        {
            OpenLauncher();
            // Its apps and icons arrive just after it opens.
            if (shot != null)
            {
                saved = Task.Delay(1500).ContinueWith(_ =>
                {
                    var done = new TaskCompletionSource();
                    queue!.TryEnqueue(async () =>
                    {
                        await Shots.SaveAsync(launcher!, launcher!.Content, shot);
                        done.SetResult();
                    });
                    return done.Task;
                }).Unwrap();
            }
        }
        else if (line.Contains("--settings"))
        {
            OpenSettings();
            if (shot != null) saved = Shots.SaveAsync(settings!, settings!.Content, shot);
        }
        else if (page != null)
        {
            OpenSetup();
            setup!.ShowPage(page);
            if (shot != null) saved = Shots.SaveAsync(setup, setup.Content, shot);
        }
        else
        {
            panel!.ShowNearTray(tray!);
            if (shot != null) saved = Shots.SaveAsync(panel, panel.Content, shot);
        }
        if (shot != null) saved.ContinueWith(_ => queue!.TryEnqueue(Quit));
    }

    private void OpenSetup()
    {
        panel?.HidePanel();
        if (setup == null)
        {
            setup = new SetupWindow();
            setup.Closed += (_, _) => setup = null;
        }
        setup.ShowCentered();
    }

    private LauncherWindow? launcher;
    private MessagesWindow? messages;

    private void OpenMessages()
    {
        if (messages == null)
        {
            messages = new MessagesWindow();
            messages.Closed += (_, _) => messages = null;
        }
        messages.ShowCentered();
    }

    private void OpenLauncher()
    {
        if (!EngineHost.Current.Connected) return;
        if (launcher == null)
        {
            launcher = new LauncherWindow();
            launcher.Closed += (_, _) => launcher = null;
        }
        launcher.ShowCentered();
    }

    private void OpenSettings()
    {
        panel?.HidePanel();
        if (settings == null)
        {
            settings = new SettingsWindow();
            settings.SetupRequested += OpenSetup;
            settings.Closed += (_, _) => settings = null;
        }
        settings.ShowCentered();
    }

    private ArrivalCard? arrival;

    /// The `nearside:` link Nearside was started with (`Nearside.exe --link <link>`: a Start-menu
    /// shortcut, or Windows for a link), if any. Nothing else on such a command line counts.
    public static string? LinkArgument()
    {
        var args = Environment.GetCommandLineArgs();
        return args.Length == 3 && args[1] == "--link" && args[2].StartsWith("nearside:", StringComparison.OrdinalIgnoreCase) ? args[2] : null;
    }

    /// The command line's switches (--demo, --open-phone...), none when started for a link: a
    /// link comes from elsewhere, and must not be able to carry switches.
    private static string[] Arguments()
    {
        var args = Environment.GetCommandLineArgs();
        return args.Length > 1 && args[1] == "--link" ? [] : args;
    }

    private string? pendingPackage;

    /// nearside://open?package=<package>: that phone app in a window, once connected (the bridge
    /// opens it only if it's one of the phone's apps).
    private void OpenLink(string link)
    {
        if (PhoneAppShortcuts.PackageFrom(link) is not { } package)
        {
            Log.Info("link: not a phone-app link; ignored");
            return;
        }
        Log.Info("link: a phone app"); // which one stays out of the log
        if (EngineHost.Current.Connected && EngineHost.Current.AppLinked)
        {
            EngineHost.Command("openPackage", new { package });
            return;
        }
        var first = pendingPackage == null;
        pendingPackage = package;
        if (!first) return;
        void WhenConnected(Snapshot s)
        {
            if (!s.Connected || !s.AppLinked || pendingPackage == null) return;
            EngineHost.Changed -= WhenConnected;
            EngineHost.Command("openPackage", new { package = pendingPackage });
            pendingPackage = null;
        }
        EngineHost.Changed += WhenConnected;
    }

    private void TogglePanel()
    {
        if (panel!.IsShown) panel.HidePanel();
        else panel.ShowNearTray(tray!);
    }

    private void Quit()
    {
        tray?.Dispose();
        notifications?.Unregister();
        camera?.Dispose(); // the camera goes with the app
        Updates.Stop();
        Log.Info("quit");
        // The engine's threads (network, sound) don't end by themselves: the process does, now.
        Environment.Exit(0);
    }
}
