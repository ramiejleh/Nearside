using Windows.Security.Credentials.UI;

namespace Nearside;

/// Windows Hello before phone apps show. Phone apps work while the phone is locked, and their
/// display is always unlocked, so this PC has to be the lock: by default once after each wake or
/// unlock of the PC. Where Hello can't ask (not set up), it allows, as the Mac does without Touch ID.
internal static class AuthGate
{
    public enum Mode { Never, AfterWake, EveryOpen }

    private const string Key = "PhoneAppsAuthentication";
    private static bool unlocked;
    private static Task<bool>? asking;

    /// The PC locked or went to sleep: open windows cover themselves.
    public static event Action? Locked;

    public static Mode Current
    {
        get => Enum.TryParse<Mode>(AppSettings.Get(Key), out var mode) ? mode : Mode.AfterWake;
        set => AppSettings.Set(Key, value.ToString());
    }

    public static bool IsLocked => Current != Mode.Never && !unlocked;

    public static void Lock()
    {
        unlocked = false;
        if (Current != Mode.Never) Locked?.Invoke();
    }

    /// True once the person has shown it's them (or nothing is asked). `opening`: a new app
    /// window is about to open.
    public static async Task<bool> AuthenticateAsync(nint window, bool opening)
    {
        switch (Current)
        {
            case Mode.Never: return true;
            case Mode.AfterWake when unlocked: return true;
            case Mode.EveryOpen when unlocked && !opening: return true;
        }
        var ok = await AskAsync(window, "Show your phone's apps");
        if (ok) unlocked = true;
        return ok;
    }

    /// Always asks: for turning the protection down in settings.
    public static Task<bool> ConfirmAsync(nint window, string reason) => AskAsync(window, reason);

    private static Task<bool> AskAsync(nint window, string reason)
    {
        if (asking is { IsCompleted: false }) return asking; // one prompt at a time
        asking = Ask(window, reason);
        return asking;
    }

    private static async Task<bool> Ask(nint window, string reason)
    {
        var availability = await UserConsentVerifier.CheckAvailabilityAsync();
        if (availability != UserConsentVerifierAvailability.Available)
        {
            Log.Info($"Windows Hello can't ask ({availability}); allowing");
            return true;
        }
        // The prompt belongs to a window: ours, else whatever is in front.
        var result = await UserConsentVerifierInterop.RequestVerificationForWindowAsync(window != 0 ? window : Win32.GetForegroundWindow(), reason);
        return result == UserConsentVerificationResult.Verified;
    }
}
