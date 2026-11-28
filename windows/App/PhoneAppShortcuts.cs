using System.Runtime.InteropServices;
using System.Text.Json;
using Nearside.Engine;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Nearside;

/// The phone's apps in the Start menu (Settings, off by default, as the Mac's launchers): a
/// shortcut per app in "Nearside Phone Apps", so Start search (and launchers that read the Start
/// menu) finds them. Each opens `nearside://open?package=<package>` with Nearside. Kept in step
/// with the phone's app list; the folder is Nearside's own, and turning the setting off removes it.
internal static class PhoneAppShortcuts
{
    public const string SettingKey = "PhoneApps.startMenu";
    public static bool On => AppSettings.Get(SettingKey) == "1";

    private static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Nearside Phone Apps");
    private static readonly string IconFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Nearside", "shortcut-icons");
    /// The apps as last listed: id -> (package, label); and each package's shortcut.
    private static Dictionary<string, (string Package, string Label)> apps = [];
    private static readonly Dictionary<string, string> shortcuts = [];
    private static bool listedThisRun;

    public static void Start()
    {
        EngineHost.Event += (name, e) =>
        {
            if (!On) return;
            if (name == "apps" && e.TryGetProperty("apps", out var list)) Sync(list);
            else if (name == "appIcons") _ = IconsAsync(e.GetProperty("icons"));
        };
        // Once connected, the list is asked for once per run (the phone may have new apps). The
        // phone away for a minute: its shortcuts go until it's back (then they're listed again).
        EngineHost.Changed += s =>
        {
            if (!On) return;
            if (s.PhoneAway)
            {
                if (Directory.Exists(Folder)) { RemoveAll(); Log.Info("start menu: phone away; its apps removed"); }
                listedThisRun = false;
                return;
            }
            if (listedThisRun || !s.Connected || !s.AppLinked) return;
            listedThisRun = true;
            EngineHost.Command("listApps");
        };
    }

    private static void RemoveAll()
    {
        try
        {
            if (Directory.Exists(Folder)) Directory.Delete(Folder, recursive: true);
            if (Directory.Exists(IconFolder)) Directory.Delete(IconFolder, recursive: true);
        }
        catch (IOException e)
        {
            Log.Info($"start menu: couldn't remove the shortcuts ({e.GetType().Name})");
        }
    }

    /// A package's icon file (".b": with the Nearside badge; a new name so Windows draws it afresh).
    private static string IconPath(string package) => Path.Combine(IconFolder, $"{package}.b.ico");

    public static void SetOn(bool on)
    {
        AppSettings.Set(SettingKey, on ? "1" : "0");
        if (on)
        {
            listedThisRun = true;
            EngineHost.Command("listApps");
        }
        else
        {
            RemoveAll();
        }
    }

    /// What a package's shortcut runs Nearside with (the package is letters, digits, dots and
    /// underscores: nothing to quote).
    public static string Arguments(string package) => $"--link nearside://open?package={package}";

    /// A shortcut per app; apps sharing a name all get their packages added, so a newly installed
    /// app can never take another's shortcut. One that runs anything else is written again;
    /// others are removed.
    private static void Sync(JsonElement list)
    {
        if (EngineHost.Current.PhoneAway) return;
        apps = [];
        shortcuts.Clear();
        foreach (var app in list.EnumerateArray())
        {
            var package = app.GetProperty("package").GetString();
            if (package == null || !SafePackage(package)) continue;
            apps[app.GetProperty("id").GetString()!] = (package, app.GetProperty("label").GetString() ?? package);
        }
        Directory.CreateDirectory(Folder);
        var shared = apps.Values.GroupBy(a => FileName(a.Label), StringComparer.OrdinalIgnoreCase)
            .Where(g => g.Count() > 1).Select(g => g.Key).ToHashSet(StringComparer.OrdinalIgnoreCase);
        // Each file belongs to one package in this pass (FileName keeps labels from looking like a
        // name-plus-package, or a short name; the number is a last resort).
        var wanted = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (package, label) in apps.Values.OrderBy(a => a.Package, StringComparer.Ordinal))
        {
            var name = FileName(label);
            if (shared.Contains(name)) name = $"{name} ({package})";
            var file = $"{name}.lnk";
            for (var n = 2; wanted.Contains(file); n++) file = $"{name} {n}.lnk";
            wanted.Add(file);
            var path = Path.Combine(Folder, file);
            shortcuts[package] = path;
            var icon = IconPath(package);
            if (ArgumentsOf(path) != Arguments(package)) Write(path, package, label, File.Exists(icon) ? icon : null);
        }
        foreach (var file in Directory.GetFiles(Folder, "*.lnk"))
        {
            if (!wanted.Contains(Path.GetFileName(file))) File.Delete(file);
        }
        Log.Info($"start menu: {wanted.Count} phone apps");
    }

    /// The phone's icons as .ico files (a PNG inside, rounded if it's full-bleed), and the
    /// shortcuts that didn't have theirs yet.
    private static async Task IconsAsync(JsonElement icons)
    {
        Directory.CreateDirectory(IconFolder);
        foreach (var icon in icons.EnumerateObject())
        {
            if (!apps.TryGetValue(icon.Name, out var app)) continue;
            var ico = IconPath(app.Package);
            var had = File.Exists(ico);
            if (had) continue; // drawn once per app (removed with the shortcuts)
            try
            {
                var png = await File.ReadAllBytesAsync(icon.Value.GetProperty("path").GetString()!);
                png = await DrawAsync(png, round: icon.Value.GetProperty("adaptive").GetBoolean());
                await File.WriteAllBytesAsync(ico, Ico(png));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or COMException)
            {
                continue;
            }
            if (!had && shortcuts.TryGetValue(app.Package, out var path)) Write(path, app.Package, app.Label, ico);
        }
    }

    /// An .ico holding one PNG (Windows reads those since Vista).
    public static byte[] Ico(byte[] png)
    {
        using var buffer = new MemoryStream();
        using var w = new BinaryWriter(buffer);
        w.Write((ushort)0); w.Write((ushort)1); w.Write((ushort)1); // reserved, icon, one image
        // Its size from the PNG's header (width and height at bytes 16 and 20); 0 means 256 or more.
        int width = png.Length >= 24 ? png[16] << 24 | png[17] << 16 | png[18] << 8 | png[19] : 256;
        int height = png.Length >= 24 ? png[20] << 24 | png[21] << 16 | png[22] << 8 | png[23] : 256;
        w.Write((byte)(width is > 0 and < 256 ? width : 0)); w.Write((byte)(height is > 0 and < 256 ? height : 0));
        w.Write((byte)0); w.Write((byte)0); w.Write((ushort)1); w.Write((ushort)32);
        w.Write((uint)png.Length); w.Write((uint)22); // its size, and where it starts
        w.Write(png);
        return buffer.ToArray();
    }

    /// Nearside's logo, for the badge on each shortcut's icon (tells them from real PC apps).
    private static readonly string BadgeFile = Path.Combine(AppContext.BaseDirectory, "Assets", "Logo.png");

    /// The phone's icon as the shortcut shows it: full-bleed (adaptive) ones in a rounded square,
    /// as Android shows them, then Nearside's logo small in the bottom-right corner.
    public static async Task<byte[]> DrawAsync(byte[] png, bool round)
    {
        var (pixels, width, height) = await DecodeAsync(png, 0);
        if (round)
        {
            var radius = Math.Min(width, height) * 0.22;
            for (var y = 0; y < height; y++)
            {
                for (var x = 0; x < width; x++)
                {
                    // Distance outside the rounded square's corner arc (0 inside), softened over a pixel.
                    double dx = Math.Max(0, Math.Max(radius - x - 0.5, x + 0.5 - (width - radius)));
                    double dy = Math.Max(0, Math.Max(radius - y - 0.5, y + 0.5 - (height - radius)));
                    var cover = Math.Clamp(radius - Math.Sqrt(dx * dx + dy * dy) + 0.5, 0, 1);
                    if (cover >= 1) continue;
                    var i = (y * width + x) * 4;
                    for (var c = 0; c < 4; c++) pixels[i + c] = (byte)(pixels[i + c] * cover);
                }
            }
        }
        if (File.Exists(BadgeFile))
        {
            var side = (int)(Math.Min(width, height) * 0.42);
            var (badge, bw, bh) = await DecodeAsync(await File.ReadAllBytesAsync(BadgeFile), side);
            int left = width - bw, top = height - bh;
            for (var y = 0; y < bh; y++)
            {
                for (var x = 0; x < bw; x++)
                {
                    int s = (y * bw + x) * 4, d = ((top + y) * width + left + x) * 4;
                    var a = badge[s + 3] / 255.0; // premultiplied: source over
                    for (var c = 0; c < 4; c++) pixels[d + c] = (byte)Math.Min(255, badge[s + c] + pixels[d + c] * (1 - a));
                }
            }
        }
        using var output = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)width, (uint)height, 96, 96, pixels);
        await encoder.FlushAsync();
        var bytes = new byte[output.Size];
        output.Seek(0);
        await output.ReadAsync(System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsBuffer(bytes), (uint)bytes.Length, InputStreamOptions.None);
        return bytes;
    }

    /// Premultiplied BGRA pixels, scaled to `side` square when it's above 0.
    private static async Task<(byte[] Pixels, int Width, int Height)> DecodeAsync(byte[] png, int side)
    {
        using var input = new InMemoryRandomAccessStream();
        await input.WriteAsync(System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsBuffer(png));
        input.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(input);
        var transform = side > 0
            ? new BitmapTransform { ScaledWidth = (uint)side, ScaledHeight = (uint)side, InterpolationMode = BitmapInterpolationMode.Fant }
            : new BitmapTransform();
        var pixels = (await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
            transform, ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage)).DetachPixelData();
        return side > 0 ? (pixels, side, side) : (pixels, (int)decoder.PixelWidth, (int)decoder.PixelHeight);
    }

    private static void Write(string path, string package, string label, string? icon)
    {
        var link = (IShellLinkW)new ShellLink();
        link.SetPath(Environment.ProcessPath!);
        link.SetArguments(Arguments(package));
        link.SetDescription($"{label} on your phone, in a window (Nearside)");
        link.SetWorkingDirectory(AppContext.BaseDirectory);
        if (icon != null) link.SetIconLocation(icon, 0);
        ((IPersistFile)link).Save(path, true);
        Marshal.ReleaseComObject(link);
    }

    /// What an existing shortcut runs Nearside with; null if there's none (or it can't be read).
    private static string? ArgumentsOf(string path)
    {
        if (!File.Exists(path)) return null;
        var link = (IShellLinkW)new ShellLink();
        try
        {
            ((IPersistFile)link).Load(path, 0);
            var args = new System.Text.StringBuilder(1024);
            link.GetArguments(args, args.Capacity);
            return args.ToString();
        }
        catch (COMException)
        {
            return null;
        }
        finally
        {
            Marshal.ReleaseComObject(link);
        }
    }

    public static bool SafePackage(string package) =>
        package.Length is > 0 and <= 255 && package.All(c => c < 128 && (char.IsAsciiLetterOrDigit(c) || c is '.' or '_'));

    /// The package from a `nearside://open?package=...` link, if it is one.
    public static string? PackageFrom(string link)
    {
        if (!Uri.TryCreate(link, UriKind.Absolute, out var uri) || uri.Scheme != "nearside" || uri.Host != "open") return null;
        var query = System.Web.HttpUtility.ParseQueryString(uri.Query);
        return query["package"] is { } package && SafePackage(package) ? package : null;
    }

    /// A label as a file name: no characters Windows forbids, not empty, not too long. Its own
    /// parentheses become brackets, so a "(package)" suffix only ever comes from Sync; and no "~",
    /// so it can't spell another file's 8.3 short name (FOOBAR~1) and write over that one.
    private static string FileName(string label)
    {
        var name = new string(label.Select(c => c switch
        {
            '(' => '[',
            ')' => ']',
            '~' => '-',
            _ when Path.GetInvalidFileNameChars().Contains(c) => '-',
            _ => c,
        }).ToArray()).Trim().TrimEnd('.');
        if (name.Length == 0) name = "App";
        return name.Length > 80 ? name[..80] : name;
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    private class ShellLink;

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
    private interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder file, int max, nint data, uint flags);
        void GetIDList(out nint list);
        void SetIDList(nint list);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder name, int max);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder dir, int max);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder args, int max);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
        void GetHotkey(out short key);
        void SetHotkey(short key);
        void GetShowCmd(out int cmd);
        void SetShowCmd(int cmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder path, int max, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(nint hwnd, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("0000010b-0000-0000-C000-000000000046")]
    private interface IPersistFile
    {
        void GetClassID(out Guid id);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string file, uint mode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string file, [MarshalAs(UnmanagedType.Bool)] bool remember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string file);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string file);
    }
}
