namespace Nearside;

/// One Nearside per signed-in user. A second start asks the first to open its panel, then exits.
internal static class SingleInstance
{
    private const string MutexName = @"Local\Nearside.App";
    private const string ShowEventName = @"Local\Nearside.Show";
    private static Mutex? mutex;
    private static EventWaitHandle? show;

    /// True if this is the only one running (keep going); false after waking the other one.
    public static bool Claim()
    {
        mutex = new Mutex(initiallyOwned: true, MutexName, out var created);
        show = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
        if (created) return true;
        show.Set();
        return false;
    }

    /// Calls `requested` (on a pool thread) each time another start asks for the panel.
    public static void OnShowRequested(Action requested)
    {
        ThreadPool.RegisterWaitForSingleObject(show!, (_, _) => requested(), null, Timeout.Infinite, executeOnlyOnce: false);
    }
}
