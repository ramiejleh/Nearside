namespace Nearside;

/// One Nearside per signed-in user. A second start asks the first to open its panel, then exits.
internal static class SingleInstance
{
    private const string MutexName = @"Local\Nearside.App";
    private const string ShowEventName = @"Local\Nearside.Show";
    private static Mutex? mutex;
    private static EventWaitHandle? show;

    /// True if this is the only one running (keep going); false after waking the other one.
    /// With `wake`, the other one opens its panel.
    public static bool Claim(bool wake = true)
    {
        mutex = new Mutex(initiallyOwned: true, MutexName, out var created);
        show = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
        if (created) return true;
        if (wake) show.Set();
        return false;
    }

    /// Hands a `nearside:` link to the running Nearside: a WM_COPYDATA to its notification-area
    /// window (same session and desktop only). False if it isn't there.
    public static unsafe bool SendLink(string link)
    {
        var window = Win32.FindWindowW("NearsideTray", null);
        if (window == 0) return false;
        fixed (char* text = link)
        {
            var data = new Win32.COPYDATASTRUCT { dwData = Win32.LinkMessage, cbData = (uint)(link.Length * 2), lpData = (nint)text };
            Win32.SendMessageW(window, Win32.WM_COPYDATA, 0, (nint)(&data));
        }
        return true;
    }

    /// Calls `requested` (on a pool thread) each time another start asks for the panel.
    public static void OnShowRequested(Action requested)
    {
        ThreadPool.RegisterWaitForSingleObject(show!, (_, _) => requested(), null, Timeout.Infinite, executeOnlyOnce: false);
    }
}
