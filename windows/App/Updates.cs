using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;

namespace Nearside;

/// Updates with WinSparkle: Sparkle's feed format and Ed25519 signatures, as on the Mac, from
/// site/appcast-windows.xml. Only in release builds (windows/scripts/release.ps1 sets the build
/// number). Nearside checks the feed itself and asks in its own window (UpdateWindow: WinSparkle's
/// is a classic dialog that ignores dark mode); on Install, WinSparkle reads the feed again,
/// downloads the new installer, checks its signature and runs it. The app quits first, and the
/// installer starts it again. What Nearside reads from the feed is only shown, never trusted.
internal static unsafe partial class Updates
{
    private const string Feed = "https://ramiejleh.github.io/Nearside/appcast-windows.xml";
    /// The public half of the update-signing key (`winsparkle-tool generate-key`; the private
    /// half never leaves the release machine). release.ps1 won't release without it.
    public const string PublicKey = "HSlJbaaRs21VvaJIe2xNFwIPhfT/8yxbuQjc+whRY9g=";
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
#if NEARSIDE_UPDATE_TEST
        // Test builds only (release.ps1 -UpdateTest): another feed, to try an update locally. Never
        // in a real release: the signature covers the installer, not the feed's other fields (the
        // installer's arguments, the version), and the installer runs as an administrator.
        feedUrl = Environment.GetEnvironmentVariable("NEARSIDE_UPDATE_FEED") is { Length: > 0 } test ? test : Feed;
#endif
        set_appcast_url(feedUrl);
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
        set_automatic_check_for_updates(0); // Nearside checks (below); WinSparkle only installs
        init();
        started = true;
        // A minute after starting, then daily.
        var timer = uiQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMinutes(1);
        timer.Tick += (t, _) => { t.Interval = TimeSpan.FromHours(24); _ = CheckAsync(manual: false); };
        timer.Start();
        checkTimer = timer;
    }

    private static bool started;
    private static string feedUrl = Feed;
    private static DispatcherQueueTimer? checkTimer;
    private const string SkippedKey = "Updates.skipped";

    /// A newer release in the feed: its version, build number and notes (plain text, one per point).
    public sealed record Release(string Version, int Build, List<string> Notes);

    /// "Check for updates": says what it found, even when there's nothing new.
    public static void Check()
    {
        if (started) _ = CheckAsync(manual: true);
    }

    /// Not offered again by itself (Check for updates still shows it).
    public static void Skip(Release release) => AppSettings.Set(SkippedKey, release.Build.ToString());

    /// WinSparkle downloads it, checks its signature and runs the installer (it shows its progress).
    public static void Install()
    {
        if (started) check_update_with_ui_and_install();
    }

#if NEARSIDE_UPDATE_TEST
    /// --install-update (test builds only): check now and install what's found, without asking.
    public static void CheckAndInstall()
    {
        if (started) check_update_with_ui_and_install();
    }
#endif

    public static void Stop()
    {
        checkTimer?.Stop();
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
    [LibraryImport(Dll, EntryPoint = "win_sparkle_check_update_with_ui_and_install")] private static partial void check_update_with_ui_and_install();
    [LibraryImport(Dll, EntryPoint = "win_sparkle_set_automatic_check_for_updates")] private static partial void set_automatic_check_for_updates(int state);
    [LibraryImport(Dll, EntryPoint = "win_sparkle_set_appcast_url", StringMarshalling = StringMarshalling.Utf8)] private static partial void set_appcast_url(string url);
    [LibraryImport(Dll, EntryPoint = "win_sparkle_set_eddsa_public_key", StringMarshalling = StringMarshalling.Utf8)] private static partial int set_eddsa_public_key(string key);
    [LibraryImport(Dll, EntryPoint = "win_sparkle_set_registry_path", StringMarshalling = StringMarshalling.Utf8)] private static partial void set_registry_path(string path);
    [LibraryImport(Dll, EntryPoint = "win_sparkle_set_app_details", StringMarshalling = StringMarshalling.Utf16)] private static partial void set_app_details(string company, string app, string version);
    [LibraryImport(Dll, EntryPoint = "win_sparkle_set_app_build_version", StringMarshalling = StringMarshalling.Utf16)] private static partial void set_app_build_version(string build);
    [LibraryImport(Dll, EntryPoint = "win_sparkle_set_can_shutdown_callback")] private static partial void set_can_shutdown_callback(delegate* unmanaged[Cdecl]<int> callback);
    [LibraryImport(Dll, EntryPoint = "win_sparkle_set_shutdown_request_callback")] private static partial void set_shutdown_request_callback(delegate* unmanaged[Cdecl]<void> callback);
}

/// The feed check, outside the unsafe part (await isn't allowed there).
internal static partial class Updates
{
    private static async Task CheckAsync(bool manual)
    {
        Release? release;
        try
        {
            release = await NewestAsync();
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or System.Xml.XmlException or FormatException)
        {
            Log.Info($"updates: couldn't read the feed ({e.GetType().Name})");
            if (manual) UpdateWindow.Show(null, "Nearside couldn't reach its update feed. Check your internet connection and try again.");
            return;
        }
        if (release == null)
        {
            if (manual) UpdateWindow.Show(null);
            return;
        }
        if (!manual && AppSettings.Get(SkippedKey) == release.Build.ToString()) return;
        Log.Info($"updates: {release.Version} ({release.Build}) is available");
        UpdateWindow.Show(release);
    }

    /// The newest release for this PC's architecture that's newer than this build, if any.
    private static async Task<Release?> NewestAsync()
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd($"Nearside/{Version}");
        var xml = System.Xml.Linq.XDocument.Parse(await http.GetStringAsync(feedUrl));
        System.Xml.Linq.XNamespace sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle";
        var os = RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "windows-arm64" : "windows-x64";
        var current = int.Parse(Build);
        Release? best = null;
        foreach (var item in xml.Descendants("item"))
        {
            if (!int.TryParse((string?)item.Element(sparkle + "version"), out var build) || build <= current) continue;
            if (!item.Elements("enclosure").Any(e => (string?)e.Attribute(sparkle + "os") == os)) continue;
            if (best != null && build <= best.Build) continue;
            var notes = System.Text.RegularExpressions.Regex.Matches((string?)item.Element("description") ?? "", "<li>(.*?)</li>",
                    System.Text.RegularExpressions.RegexOptions.Singleline)
                .Select(m => System.Net.WebUtility.HtmlDecode(System.Text.RegularExpressions.Regex.Replace(m.Groups[1].Value, "<[^>]+>", "")).Trim())
                .Where(n => n.Length > 0).ToList();
            best = new Release((string?)item.Element(sparkle + "shortVersionString") ?? build.ToString(), build, notes);
        }
        return best;
    }
}
