using System.Runtime.InteropServices;

namespace Nearside;

/// A phone app's window as its own app on the taskbar: Windows groups windows by AppUserModelID,
/// and without one of its own every window shares Nearside's (one button, Nearside's icon). Each
/// app's windows get "Nearside.PhoneApp.<package>", its icon (with the Nearside badge, as in the
/// Start menu), and a relaunch command, so pinning the button pins that app.
internal static class TaskbarIdentity
{
    private static readonly string IconFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Nearside", "window-icons");

    // System.AppUserModel.* (propkey.h).
    private static readonly Guid AppUserModel = new("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    private const uint RelaunchCommand = 2, RelaunchIconResource = 3, RelaunchDisplayNameResource = 4, Id = 5;

    /// An id is at most 128 characters; a package can be longer (then it's shortened with a hash).
    private static string AppId(string package)
    {
        var id = $"Nearside.PhoneApp.{package}";
        if (id.Length <= 128) return id;
        var hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(package)))[..16];
        return $"{id[..(128 - 17)]}.{hash}";
    }

    /// Before the window shows, so its button starts out in the right group.
    public static void Set(nint hwnd, string package, string label)
    {
        if (!PhoneAppShortcuts.SafePackage(package)) return;
        With(hwnd, store =>
        {
            SetString(store, RelaunchCommand, $"\"{Environment.ProcessPath}\" {PhoneAppShortcuts.Arguments(package)}");
            SetString(store, RelaunchDisplayNameResource, label);
            var icon = IconPath(package);
            if (File.Exists(icon)) SetString(store, RelaunchIconResource, icon);
            SetString(store, Id, AppId(package));
        });
    }

    /// The app's icon arrived (a PNG from the phone): drawn once into an .ico, then used for the
    /// window and its button. Returns the .ico, or null if it couldn't be made.
    public static async Task<string?> IconAsync(nint hwnd, string package, string png, bool adaptive)
    {
        if (!PhoneAppShortcuts.SafePackage(package)) return null;
        var ico = IconPath(package);
        try
        {
            Directory.CreateDirectory(IconFolder);
            // Redrawn when the phone's icon is newer (an app update can change it).
            if (!File.Exists(ico) || File.GetLastWriteTimeUtc(png) > File.GetLastWriteTimeUtc(ico))
            {
                var drawn = await PhoneAppShortcuts.DrawAsync(await File.ReadAllBytesAsync(png), adaptive);
                await File.WriteAllBytesAsync(ico, PhoneAppShortcuts.Ico(drawn));
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or COMException)
        {
            Log.Info($"taskbar: no icon for a phone app ({e.GetType().Name})");
            return null;
        }
        With(hwnd, store => SetString(store, RelaunchIconResource, ico));
        return ico;
    }

    /// When the window closes (Windows asks for the properties to be cleared before then).
    public static void Clear(nint hwnd) => With(hwnd, store =>
    {
        foreach (var pid in new[] { Id, RelaunchCommand, RelaunchDisplayNameResource, RelaunchIconResource })
        {
            var key = new PropertyKey { Format = AppUserModel, Id = pid };
            var empty = new PropVariant();
            store.SetValue(ref key, ref empty);
        }
        store.Commit();
    });

    private static string IconPath(string package) => Path.Combine(IconFolder, $"{package}.ico");

    /// The app's .ico from an earlier window, if there is one (shown until the phone's arrives).
    public static string? ExistingIcon(string package) =>
        PhoneAppShortcuts.SafePackage(package) && File.Exists(IconPath(package)) ? IconPath(package) : null;

    private static void With(nint hwnd, Action<IPropertyStore> action)
    {
        var iid = typeof(IPropertyStore).GUID;
        if (SHGetPropertyStoreForWindow(hwnd, ref iid, out var store) != 0 || store == null) return;
        try
        {
            action(store);
        }
        catch (COMException e)
        {
            Log.Info($"taskbar: couldn't set a window's identity ({e.HResult:X8})");
        }
        finally
        {
            Marshal.ReleaseComObject(store);
        }
    }

    private static void SetString(IPropertyStore store, uint pid, string value)
    {
        var key = new PropertyKey { Format = AppUserModel, Id = pid };
        var v = new PropVariant { Type = 31 /* VT_LPWSTR */, Pointer = Marshal.StringToCoTaskMemUni(value) };
        try
        {
            store.SetValue(ref key, ref v);
            store.Commit();
        }
        finally
        {
            PropVariantClear(ref v);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PropertyKey
    {
        public Guid Format;
        public uint Id;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PropVariant
    {
        public ushort Type;
        public ushort Reserved1, Reserved2, Reserved3;
        public nint Pointer;
        public nint Pointer2;
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    private interface IPropertyStore
    {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, out PropVariant value);
        void SetValue(ref PropertyKey key, ref PropVariant value);
        void Commit();
    }

    [DllImport("shell32.dll")]
    private static extern int SHGetPropertyStoreForWindow(nint hwnd, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore? store);

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PropVariant value);
}
