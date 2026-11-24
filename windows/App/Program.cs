using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Nearside;

public static class Program
{
    [STAThread]
    private static void Main()
    {
        // One Nearside per user: a second start opens the running one's panel instead.
        if (!SingleInstance.Claim()) return;
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(callback =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            new App();
        });
    }
}
