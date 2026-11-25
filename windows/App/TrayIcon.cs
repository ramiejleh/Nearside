using System.Runtime.InteropServices;
using Microsoft.Win32;
using Nearside.Engine;

namespace Nearside;

/// Nearside's icon in the notification area: a click opens the panel, a right-click offers
/// Settings and Quit.
/// It follows the taskbar's theme (white mark on a dark taskbar, black on a light one) and is
/// outlined while the phone isn't connected, as on the Mac's menu bar.
internal sealed unsafe class TrayIcon : IDisposable
{
    private const uint CallbackMessage = Win32.WM_APP + 1;
    private const uint IconId = 1;
    private const int MenuOpen = 1, MenuQuit = 2, MenuSettings = 3, MenuUpdates = 4;

    private static TrayIcon? instance; // the window procedure's way back here (there's one icon)
    private readonly Action onSelect, onSettings, onQuit;
    /// The launcher's shortcut was pressed.
    public Action? OnHotKey { get; set; }
    /// "Check for updates" in the menu (release builds only).
    public Action? OnCheckForUpdates { get; set; }
    private readonly uint taskbarCreated;
    private nint window, icon;
    private bool connected, added;
    private string tip = "Nearside";

    public TrayIcon(Action onSelect, Action onSettings, Action onQuit)
    {
        this.onSelect = onSelect;
        this.onSettings = onSettings;
        this.onQuit = onQuit;
        instance = this;
        taskbarCreated = Win32.RegisterWindowMessageW("TaskbarCreated");
        window = CreateWindow();
        Show();
        // Locking or sleeping this PC locks phone apps again (Windows Hello to show them).
        if (!Win32.WTSRegisterSessionNotification(window, 0))
        {
            AuthGate.NoLockSignal = true; // can't tell a lock: ask every time
            Log.Error("no session notifications: Windows Hello is asked every time");
        }
        Win32.RegisterPowerSettingNotification(window, Win32.ConsoleDisplayState, 0); // the display turning off
        // Ctrl+Alt+N opens the launcher from anywhere.
        if (!Win32.RegisterHotKey(window, 1, Win32.MOD_CONTROL | Win32.MOD_ALT | Win32.MOD_NOREPEAT, 'N')) Log.Info("Ctrl+Alt+N is taken by another app");
    }

    /// The icon's place on screen (physical pixels), to open the panel next to it.
    public Win32.RECT? Bounds
    {
        get
        {
            var id = new Win32.NOTIFYICONIDENTIFIER { cbSize = (uint)sizeof(Win32.NOTIFYICONIDENTIFIER), hWnd = window, uID = IconId };
            return Win32.Shell_NotifyIconGetRect(&id, out var rect) == 0 ? rect : null;
        }
    }

    public void Update(Snapshot s)
    {
        var text = s.State switch
        {
            "connected" => $"Nearside: {s.PhoneName}{(s.OverUSB ? " (USB)" : "")}",
            "searching" when s.InUseOn != null => $"Nearside: {s.PhoneName} is in use on {s.InUseOn}",
            "searching" => $"Nearside: looking for {s.PhoneName}",
            _ => "Nearside: not set up",
        };
        if (s.Connected == connected && text == tip) return;
        connected = s.Connected;
        tip = text;
        Show();
    }

    /// Adds the icon, or updates it (after a change, a theme switch, or Explorer restarting).
    private void Show()
    {
        var old = icon;
        icon = LoadIcon();
        var data = new Win32.NOTIFYICONDATAW
        {
            cbSize = (uint)sizeof(Win32.NOTIFYICONDATAW),
            hWnd = window,
            uID = IconId,
            uFlags = Win32.NIF_MESSAGE | Win32.NIF_ICON | Win32.NIF_TIP | Win32.NIF_SHOWTIP,
            uCallbackMessage = CallbackMessage,
            hIcon = icon,
        };
        var length = Math.Min(tip.Length, 127);
        tip.AsSpan(0, length).CopyTo(new Span<char>(data.szTip, 128));
        data.szTip[length] = '\0';
        if (!added || Win32.Shell_NotifyIconW(Win32.NIM_MODIFY, &data) == 0)
        {
            added = Win32.Shell_NotifyIconW(Win32.NIM_ADD, &data) != 0;
            data.uVersion = Win32.NOTIFYICON_VERSION_4;
            Win32.Shell_NotifyIconW(Win32.NIM_SETVERSION, &data);
        }
        if (old != 0) Win32.DestroyIcon(old);
    }

    private nint LoadIcon()
    {
        var name = $"tray-{(TaskbarIsLight() ? "light" : "dark")}{(connected ? "" : "-off")}.ico";
        var path = Path.Combine(AppContext.BaseDirectory, "Assets", name);
        var size = Win32.GetSystemMetrics(Win32.SM_CXSMICON);
        return Win32.LoadImageW(0, path, Win32.IMAGE_ICON, size, size, Win32.LR_LOADFROMFILE);
    }

    private static bool TaskbarIsLight()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("SystemUsesLightTheme") is int light && light == 1;
    }

    private void ShowMenu(int x, int y)
    {
        var menu = Win32.CreatePopupMenu();
        Win32.AppendMenuW(menu, Win32.MF_STRING, MenuOpen, "Open Nearside");
        Win32.AppendMenuW(menu, Win32.MF_STRING, MenuSettings, "Settings");
        if (OnCheckForUpdates != null) Win32.AppendMenuW(menu, Win32.MF_STRING, MenuUpdates, "Check for updates");
        Win32.AppendMenuW(menu, Win32.MF_SEPARATOR, 0, null);
        Win32.AppendMenuW(menu, Win32.MF_STRING, MenuQuit, "Quit Nearside");
        Win32.SetForegroundWindow(window); // or the menu won't close when clicking elsewhere
        var chosen = Win32.TrackPopupMenu(menu, Win32.TPM_RETURNCMD | Win32.TPM_RIGHTBUTTON | Win32.TPM_BOTTOMALIGN, x, y, 0, window, 0);
        Win32.DestroyMenu(menu);
        if (chosen == MenuOpen) onSelect();
        else if (chosen == MenuSettings) onSettings();
        else if (chosen == MenuUpdates) OnCheckForUpdates?.Invoke();
        else if (chosen == MenuQuit) onQuit();
    }

    private nint CreateWindow()
    {
        var module = Win32.GetModuleHandleW(null);
        fixed (char* className = "NearsideTray")
        {
            var wc = new Win32.WNDCLASSEXW
            {
                cbSize = (uint)sizeof(Win32.WNDCLASSEXW),
                lpfnWndProc = &WindowProc,
                hInstance = module,
                lpszClassName = className,
            };
            Win32.RegisterClassExW(&wc);
            // A hidden top-level window (not message-only: those miss Explorer's TaskbarCreated).
            return Win32.CreateWindowExW(0, className, className, 0, 0, 0, 0, 0, 0, 0, module, 0);
        }
    }

    [UnmanagedCallersOnly]
    private static nint WindowProc(nint hwnd, uint message, nint wParam, nint lParam)
    {
        var self = instance;
        try
        {
            if (self != null && message == CallbackMessage)
            {
                // NOTIFYICON_VERSION_4: the event in lParam's low word, the anchor point in wParam.
                switch ((uint)(lParam & 0xFFFF))
                {
                    case Win32.NIN_SELECT:
                    case Win32.NIN_KEYSELECT:
                        self.onSelect();
                        break;
                    case Win32.WM_CONTEXTMENU:
                        self.ShowMenu((short)(wParam & 0xFFFF), (short)((wParam >> 16) & 0xFFFF));
                        break;
                }
                return 0;
            }
            if (self != null && message == self.taskbarCreated)
            {
                self.added = false; // Explorer restarted: the icon is gone
                self.Show();
                return 0;
            }
            if (self != null && message == Win32.WM_SETTINGCHANGE) self.Show(); // maybe the theme
            if (message == Win32.WM_WTSSESSION_CHANGE && wParam is Win32.WTS_SESSION_LOCK or Win32.WTS_CONSOLE_DISCONNECT or Win32.WTS_REMOTE_DISCONNECT) AuthGate.Lock();
            if (message == Win32.WM_POWERBROADCAST && wParam == Win32.PBT_APMSUSPEND) AuthGate.Lock();
            if (message == Win32.WM_POWERBROADCAST && wParam == Win32.PBT_POWERSETTINGCHANGE && lParam != 0)
            {
                var setting = *(Win32.POWERBROADCAST_SETTING*)lParam;
                if (setting.PowerSetting == Win32.ConsoleDisplayState && setting.Data == 0) AuthGate.Lock();
            }
            if (self != null && message == Win32.WM_HOTKEY) self.OnHotKey?.Invoke();
        }
        catch (Exception e)
        {
            Log.Error($"tray: {e}"); // never let an exception into Windows' call
        }
        return Win32.DefWindowProcW(hwnd, message, wParam, lParam);
    }

    public void Dispose()
    {
        var data = new Win32.NOTIFYICONDATAW { cbSize = (uint)sizeof(Win32.NOTIFYICONDATAW), hWnd = window, uID = IconId };
        Win32.Shell_NotifyIconW(Win32.NIM_DELETE, &data);
        if (icon != 0) Win32.DestroyIcon(icon);
        Win32.DestroyWindow(window);
        instance = null;
    }
}
