using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Nearside.Engine;

namespace Nearside;

/// The app lives in the tray: the icon opens the panel; nothing else shows unless asked for.
public partial class App : Application
{
    private TrayIcon? tray;
    private PanelWindow? panel;

    public App()
    {
        InitializeComponent();
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        UnhandledException += (_, e) => Log.Error($"unhandled: {e.Exception}");
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var queue = DispatcherQueue.GetForCurrentThread();
        panel = new PanelWindow();
        tray = new TrayIcon(onSelect: TogglePanel, onQuit: Quit);
        EngineHost.Changed += snapshot => tray.Update(snapshot);
        SingleInstance.OnShowRequested(() => queue.TryEnqueue(() => panel.ShowNearTray(tray)));

        Log.Info("started");
        if (Environment.GetCommandLineArgs().Contains("--demo"))
        {
            EngineHost.StartDemo();
            panel.ShowNearTray(tray);
            // --shot <file.png>: saves the panel as drawn, then quits (for screenshots).
            var line = Environment.GetCommandLineArgs();
            var shot = Array.IndexOf(line, "--shot");
            if (shot > 0 && shot + 1 < line.Length) _ = panel.SaveShotAsync(line[shot + 1]).ContinueWith(_ => queue.TryEnqueue(Quit));
            return;
        }
        var apk = Path.Combine(AppContext.BaseDirectory, "phone-app.apk");
        EngineHost.Start(queue, File.Exists(apk) ? apk : null);
    }

    private void TogglePanel()
    {
        if (panel!.IsShown) panel.HidePanel();
        else panel.ShowNearTray(tray!);
    }

    private void Quit()
    {
        tray?.Dispose();
        Exit();
    }
}
