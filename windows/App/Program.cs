using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Nearside;

public static class Program
{
    [STAThread]
    private static void Main()
    {
        // One Nearside per user: a second start opens the running one's panel instead, or hands it
        // its `nearside:` link (a Start-menu shortcut, a link from another launcher).
        if (!SingleInstance.Claim(wake: App.LinkArgument() == null))
        {
            if (App.LinkArgument() is { } link) SingleInstance.SendLink(link);
            return;
        }
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(callback =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            new App();
        });
    }
}
