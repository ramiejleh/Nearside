using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using Nearside.Engine;

namespace Nearside;

/// The phone's notifications (and Nearside's own) as Windows notifications. The engine says what to
/// show (BridgeNotifications.swift); what the user does with one goes back to it as a command.
/// Windows doesn't report a notification being cleared, so clearing is noticed when the engine
/// asks (reconcile): what's no longer in the notification center was cleared.
internal sealed class Notifications
{
    private const string PhoneGroup = "phone", LocalGroup = "local";

    /// Tag (Windows allows 64 characters) to the engine's key, for what's on screen.
    private readonly Dictionary<string, (string Key, DateTime Shown)> shown = [];
    private readonly string iconFolder = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Nearside", "icons");

    public Notifications(Microsoft.UI.Dispatching.DispatcherQueue queue)
    {
        var manager = AppNotificationManager.Default;
        // Called on a pool thread: handled on the UI thread, the engine's.
        manager.NotificationInvoked += (_, e) =>
        {
            var (arguments, input) = (new Dictionary<string, string>(e.Arguments), new Dictionary<string, string>(e.UserInput));
            queue.TryEnqueue(() => Invoked(arguments, input));
        };
        manager.Register();
        _ = manager.RemoveAllAsync(); // from an earlier run: the phone sends what's current
        EngineHost.Event += OnEvent;
    }

    public void Unregister() => AppNotificationManager.Default.Unregister();

    private void OnEvent(string name, JsonElement e)
    {
        switch (name)
        {
            case "notify": Show(e); break;
            case "notifyLocal": ShowLocal(e); break;
            case "notifyRemove": Remove(e.GetProperty("key").GetString()!); break;
            case "notifyKeepOnly":
                var keep = e.GetProperty("keys").EnumerateArray().Select(k => k.GetString()).ToHashSet();
                foreach (var (tag, entry) in shown.ToList())
                {
                    if (!keep.Contains(entry.Key)) Remove(entry.Key);
                }
                break;
            case "notifyRemoveAll":
                shown.Clear();
                _ = AppNotificationManager.Default.RemoveByGroupAsync(PhoneGroup);
                break;
            case "notifyReconcile": _ = ReconcileAsync(); break;
        }
    }

    private void Show(JsonElement e)
    {
        var key = e.GetProperty("key").GetString()!;
        var app = e.GetProperty("app").GetString() ?? "";
        var title = e.GetProperty("title").GetString() ?? "";
        var text = e.GetProperty("text").GetString() ?? "";
        var builder = new AppNotificationBuilder()
            .AddArgument("key", key)
            .SetAttributionText(app)
            .AddText(title.Length > 0 ? title : app)
            .AddText(text);
        if (e.TryGetProperty("icon", out var icon) && SaveIcon(e.GetProperty("package").GetString() ?? app, icon.GetString()) is { } file)
        {
            builder.SetAppLogoOverride(new Uri(file), AppNotificationImageCrop.Default);
        }
        var index = 0;
        foreach (var action in e.GetProperty("actions").EnumerateArray())
        {
            var label = action.GetProperty("title").GetString() ?? "";
            var button = new AppNotificationButton(label).AddArgument("key", key).AddArgument("action", index.ToString());
            if (action.GetProperty("reply").GetBoolean())
            {
                builder.AddTextBox("reply", label, "");
                button.SetInputId("reply");
            }
            builder.AddButton(button);
            index++;
        }
        if (e.GetProperty("quiet").GetBoolean()) builder.MuteAudio();
        var notification = builder.BuildNotification();
        notification.Tag = Tag(key);
        notification.Group = PhoneGroup;
        notification.SuppressDisplay = e.GetProperty("quiet").GetBoolean(); // quiet: in the center only, no pop-up
        shown[notification.Tag] = (key, DateTime.UtcNow);
        AppNotificationManager.Default.Show(notification);
        Log.Info($"notification shown{(notification.SuppressDisplay ? " (quiet)" : "")}, {shown.Count} on screen");
    }

    private static void ShowLocal(JsonElement e)
    {
        var id = e.GetProperty("id").GetString()!;
        var notification = new AppNotificationBuilder()
            .AddArgument("key", id)
            .AddText(e.GetProperty("title").GetString() ?? "")
            .AddText(e.GetProperty("body").GetString() ?? "")
            .BuildNotification();
        notification.Tag = Tag(id);
        notification.Group = LocalGroup;
        AppNotificationManager.Default.Show(notification);
    }

    private void Remove(string key)
    {
        var tag = Tag(key);
        shown.Remove(tag);
        _ = AppNotificationManager.Default.RemoveByTagAndGroupAsync(tag, PhoneGroup);
    }

    /// The ones no longer in the notification center were cleared on this PC: dismiss them on the phone.
    private async Task ReconcileAsync()
    {
        if (shown.Count == 0) return;
        var present = (await AppNotificationManager.Default.GetAllAsync()).Select(n => n.Tag).ToHashSet();
        var settled = DateTime.UtcNow.AddSeconds(-3); // just-shown ones may not be listed yet
        foreach (var (tag, entry) in shown.ToList())
        {
            if (present.Contains(tag) || entry.Shown > settled) continue;
            shown.Remove(tag);
            Log.Info("notification cleared on this PC: dismissing it on the phone");
            EngineHost.Command("notifDismissed", new { key = entry.Key });
        }
    }

    private void Invoked(Dictionary<string, string> args, Dictionary<string, string> input)
    {
        if (!args.TryGetValue("key", out var key)) return;
        if (args.TryGetValue("action", out var action) && int.TryParse(action, out var index))
        {
            input.TryGetValue("reply", out var text);
            EngineHost.Command("notifAction", new { key, i = index, text });
        }
        else
        {
            EngineHost.Command("notifOpened", new { key });
        }
        shown.Remove(Tag(key));
    }

    /// A short, stable tag for a key of any length.
    private static string Tag(string key) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key)))[..32];

    /// The app's icon as a file (Windows shows images from files): one per app, rewritten as it changes.
    private string? SaveIcon(string package, string? base64)
    {
        if (string.IsNullOrEmpty(base64)) return null;
        try
        {
            var bytes = Convert.FromBase64String(base64);
            if (bytes.Length > 512 * 1024) return null;
            Directory.CreateDirectory(iconFolder);
            var path = Path.Combine(iconFolder, Tag(package) + ".png");
            if (!File.Exists(path) || new FileInfo(path).Length != bytes.Length) File.WriteAllBytes(path, bytes);
            return path;
        }
        catch (Exception e) when (e is FormatException or IOException)
        {
            return null;
        }
    }
}
