using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;

namespace Nearside;

/// Updates with WinSparkle: Sparkle's feed format and Ed25519 signatures, as on the Mac, from
/// site/appcast-windows.xml. Only in release builds (windows/scripts/release.ps1 sets the build
/// number). WinSparkle downloads the new installer, checks its signature and runs it; the app
/// quits first, and the installer starts it again.
internal static unsafe partial class Updates
{
    private const string Feed = "https://ramiejleh.github.io/Nearside/appcast-windows.xml";
    /// The public half of the update-signing key (`winsparkle-tool generate-key`; the private
    /// half never leaves the release machine). release.ps1 won't release without it.
    public const string PublicKey = "";
    private const string Dll = "WinSparkle.dll";

    /// The commit count, as the Mac's build number; empty in development builds.
    public static readonly string Build = typeof(Updates).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
        .FirstOrDefault(a => a.Key == "NearsideBuild")?.Value ?? "";
    /// "0.2.0" (without the "+commit" .NET adds).
    public static readonly string Version = (typeof(Updates).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
        .InformationalVersion ?? "0.0.0").Split('+')[0];

    public static bool Available => PublicKey.Length > 0 && Build.Length > 0 && File.Exists(Path.Combine(AppContext.BaseDirectory, Dll));

    private static DispatcherQueue? queue;
    private static Action? quit;

    public static void Start(DispatcherQueue uiQueue, Action quitApp)
    {
        if (!Available) return;
        queue = uiQueue;
        quit = quitApp;
        // NEARSIDE_UPDATE_FEED: another feed, for testing an update locally. Safe to allow: an
        // update is only installed if it's signed with the key above.
        set_appcast_url(Environment.GetEnvironmentVariable("NEARSIDE_UPDATE_FEED") is { Length: > 0 } test ? test : Feed);
        if (set_eddsa_public_key(PublicKey) != 1)
        {
            Log.Info("updates: the public key isn't valid; not checking");
            return;
        }
        set_app_details("Nearside", "Nearside", Version);
        set_app_build_version(Build);
        set_registry_path(@"Software\Nearside\WinSparkle");
        set_can_shutdown_callback(&CanShutdown);
        set_shutdown_request_callback(&ShutdownRequested);
        init();
        started = true;
    }

    private static bool started;

    /// "Check for updates" (shows WinSparkle's window either way).
    public static void Check()
    {
        if (started) check_update_with_ui();
    }

    /// --install-update (testing): check now and install what's found, without asking.
    public static void CheckAndInstall()
    {
        if (started) check_update_with_ui_and_install();
    }

    public static void Stop()
    {
        if (started) cleanup();
        started = false;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int CanShutdown() => 1;

    /// WinSparkle's thread: the installer is about to run, so quit (on the UI thread).
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void ShutdownRequested()
    {
        if (queue is { } q && quit is { } action) q.TryEnqueue(() => action());
    }

    [LibraryImport(Dll, EntryPoint = "win_sparkle_init")] private static partial void init();
    [LibraryImport(Dll, EntryPoint = "win_sparkle_cleanup")] private static partial void cleanup();
    [LibraryImport(Dll, EntryPoint = "win_sparkle_check_update_with_ui")] private static partial void check_update_with_ui();
    [LibraryImport(Dll, EntryPoint = "win_sparkle_check_update_with_ui_and_install")] private static partial void check_update_with_ui_and_install();
    [LibraryImport(Dll, EntryPoint = "win_sparkle_set_appcast_url", StringMarshalling = StringMarshalling.Utf8)] private static partial void set_appcast_url(string url);
    [LibraryImport(Dll, EntryPoint = "win_sparkle_set_eddsa_public_key", StringMarshalling = StringMarshalling.Utf8)] private static partial int set_eddsa_public_key(string key);
    [LibraryImport(Dll, EntryPoint = "win_sparkle_set_registry_path", StringMarshalling = StringMarshalling.Utf8)] private static partial void set_registry_path(string path);
    [LibraryImport(Dll, EntryPoint = "win_sparkle_set_app_details", StringMarshalling = StringMarshalling.Utf16)] private static partial void set_app_details(string company, string app, string version);
    [LibraryImport(Dll, EntryPoint = "win_sparkle_set_app_build_version", StringMarshalling = StringMarshalling.Utf16)] private static partial void set_app_build_version(string build);
    [LibraryImport(Dll, EntryPoint = "win_sparkle_set_can_shutdown_callback")] private static partial void set_can_shutdown_callback(delegate* unmanaged[Cdecl]<int> callback);
    [LibraryImport(Dll, EntryPoint = "win_sparkle_set_shutdown_request_callback")] private static partial void set_shutdown_request_callback(delegate* unmanaged[Cdecl]<void> callback);
}
