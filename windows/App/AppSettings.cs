using Microsoft.Win32;

namespace Nearside;

/// The app's own settings (the engine keeps its own): HKCU\Software\Nearside.
internal static class AppSettings
{
    private const string KeyPath = @"Software\Nearside";

    public static string? Get(string name)
    {
        using var key = Registry.CurrentUser.OpenSubKey(KeyPath);
        return key?.GetValue(name) as string;
    }

    public static void Set(string name, string value)
    {
        using var key = Registry.CurrentUser.CreateSubKey(KeyPath);
        key.SetValue(name, value);
    }
}
