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
    private static (string Reason, Task<bool> Task)? asking;
    /// Hello verified someone in this run: from then on, it being unavailable never lets anyone in.
    private static bool helloWorked;

    /// Windows' lock notifications couldn't be had: without them "after a wake or unlock" can't
    /// be told, so it asks every time.
    public static bool NoLockSignal { get; set; }

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
            case Mode.AfterWake when unlocked && !NoLockSignal: return true;
            case Mode.EveryOpen when unlocked && !opening: return true;
        }
        var ok = await AskAsync(window, "Show your phone's apps");
        if (ok) unlocked = true;
        return ok;
    }

    /// Always asks: for turning the protection down in settings.
    public static Task<bool> ConfirmAsync(nint window, string reason) => AskAsync(window, reason);

    /// One prompt at a time: the same question shares the prompt up; another waits for it, then asks.
    private static async Task<bool> AskAsync(nint window, string reason)
    {
        while (asking is { } pending && !pending.Task.IsCompleted)
        {
            if (pending.Reason == reason) return await pending.Task;
            await pending.Task;
        }
        var task = Ask(window, reason);
        asking = (reason, task);
        return await task;
    }

    private static async Task<bool> Ask(nint window, string reason)
    {
        var availability = await UserConsentVerifier.CheckAvailabilityAsync();
        if (availability != UserConsentVerifierAvailability.Available)
        {
            // No Hello on this PC (as the Mac allows without Touch ID); anything else (busy,
            // blocked by policy), or Hello vanishing after it worked, keeps phone apps hidden.
            var allow = !helloWorked && availability is UserConsentVerifierAvailability.DeviceNotPresent
                or UserConsentVerifierAvailability.NotConfiguredForUser;
            Log.Info($"Windows Hello can't ask ({availability}); {(allow ? "allowing" : "refusing")}");
            return allow;
        }
        // The prompt belongs to a window: ours, else whatever is in front.
        var result = await UserConsentVerifierInterop.RequestVerificationForWindowAsync(window != 0 ? window : Win32.GetForegroundWindow(), reason);
        if (result == UserConsentVerificationResult.Verified) helloWorked = true;
        return result == UserConsentVerificationResult.Verified;
    }
}
