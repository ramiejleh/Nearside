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
        panel.PhoneRequested += () => PhoneWindow.Show();
        tray = new TrayIcon(onSelect: TogglePanel, onSettings: OpenSettings, onQuit: Quit);
        EngineHost.Changed += snapshot => tray.Update(snapshot);
        SingleInstance.OnShowRequested(() => queue.TryEnqueue(() => panel.ShowNearTray(tray)));
        Log.Info("started");

        var line = Environment.GetCommandLineArgs();
        if (line.Contains("--demo"))
        {
            RunDemo(line);
            return;
        }
        notifications = new Notifications(queue);
        var apk = Path.Combine(AppContext.BaseDirectory, "phone-app.apk");
        EngineHost.Start(queue, File.Exists(apk) ? apk : null);
        Video.VideoRouter.Install();
        EngineHost.Event += (name, e) =>
        {
            if (name == "session") PhoneWindow.Route(e);
        };
        if (EngineHost.Current.NeedsSetup) OpenSetup();
        // --open-phone: the phone window opens once connected (for testing).
        if (line.Contains("--open-phone"))
        {
            void OpenOnce(Snapshot s)
            {
                if (!s.Connected || !s.AppLinked) return;
                EngineHost.Changed -= OpenOnce;
                PhoneWindow.Show();
            }
            EngineHost.Changed += OpenOnce;
        }
    }

    /// --demo [--setup <page> | --settings] [--shot <file.png>]: made-up content in the panel (or a
    /// setup page, or settings);
    /// --shot saves the window as drawn, then quits. For screenshots: nothing personal shows.
    private void RunDemo(string[] line)
    {
        string? Value(string flag) => Array.IndexOf(line, flag) is var i and > 0 && i + 1 < line.Length ? line[i + 1] : null;
        var page = Value("--setup");
        EngineHost.StartDemo(setup: page != null);
        Task saved = Task.CompletedTask;
        var shot = Value("--shot");
        if (line.Contains("--settings"))
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

    private void TogglePanel()
    {
        if (panel!.IsShown) panel.HidePanel();
        else panel.ShowNearTray(tray!);
    }

    private void Quit()
    {
        tray?.Dispose();
        notifications?.Unregister();
        Exit();
    }
}
