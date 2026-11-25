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
    private const int MaxTracked = 20;

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
        EngineHost.Changed += ShowRinging;
    }

    // MARK: Calls

    private const string CallGroup = "call";
    private static readonly string[] QuickReplies = ["Can't talk now. I'll call you back.", "I'll call you later.", "On my way."];
    /// The ringing call shown (its key and state), so it's only re-shown when it changes.
    private (string Key, string State)? ringShown;

    /// A call ringing on the phone: Windows' call notification (it stays up and rings), with
    /// Answer, Decline and, for a phone call, declining with a text.
    private void ShowRinging(Snapshot s)
    {
        var calls = s.Calls;
        var call = calls.Show ? calls.List.FirstOrDefault(c => c.Key == calls.Ringing) : null;
        var now = call == null ? ((string, string)?)null : (call.Key, call.State);
        if (now == ringShown) return;
        ringShown = now;
        _ = AppNotificationManager.Default.RemoveByGroupAsync(CallGroup);
        if (call == null) return;
        try
        {
            var builder = new AppNotificationBuilder()
                .SetScenario(AppNotificationScenario.IncomingCall)
                .AddArgument("call", call.Key)
                .AddText(Clean(call.Title, 100))
                .AddText(call.State == "screening" ? $"{call.Kind} · screening" : call.Kind);
            if (call.Photo != null && SaveIcon("call-" + call.Key, call.Photo) is { } photo)
            {
                builder.SetAppLogoOverride(new Uri(photo), AppNotificationImageCrop.Circle);
            }
            if (call.Number != null && s.Settings.TextMessages && call.Can.Contains("decline"))
            {
                var replies = new AppNotificationComboBox("reply").SetSelectedItem("0");
                for (var i = 0; i < QuickReplies.Length; i++) replies.AddItem(i.ToString(), QuickReplies[i]);
                builder.AddComboBox(replies);
                builder.AddButton(new AppNotificationButton("Text").AddArgument("call", call.Key).AddArgument("do", "text"));
            }
            if (call.Can.Contains("decline"))
            {
                builder.AddButton(new AppNotificationButton("Decline").AddArgument("call", call.Key).AddArgument("do", "decline")
                    .SetButtonStyle(AppNotificationButtonStyle.Critical));
            }
            if (call.Can.Contains("answer"))
            {
                builder.AddButton(new AppNotificationButton("Answer").AddArgument("call", call.Key).AddArgument("do", "answer")
                    .SetButtonStyle(AppNotificationButtonStyle.Success));
            }
            if (calls.RingHere && call.State == "incoming") builder.SetAudioEvent(AppNotificationSoundEvent.Call, AppNotificationAudioLooping.Loop);
            else builder.MuteAudio();
            var notification = builder.BuildNotification();
            notification.Tag = "ringing";
            notification.Group = CallGroup;
            AppNotificationManager.Default.Show(notification);
        }
        catch (Exception error)
        {
            Log.Error($"the call notification couldn't be shown: {error.GetType().Name}");
        }
    }

    private static void CallInvoked(string key, Dictionary<string, string> args, Dictionary<string, string> input)
    {
        switch (args.GetValueOrDefault("do"))
        {
            case "answer": EngineHost.Command("callAct", new { key, action = "answer" }); break;
            case "decline": EngineHost.Command("callAct", new { key, action = "decline" }); break;
            case "text":
                var choice = int.TryParse(input.GetValueOrDefault("reply"), out var i) && i >= 0 && i < QuickReplies.Length ? i : 0;
                EngineHost.Command("callDeclineText", new { key, text = QuickReplies[choice] });
                break;
        }
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
        var app = Clean(e.GetProperty("app").GetString(), 100);
        var title = Clean(e.GetProperty("title").GetString(), 200);
        var text = Clean(e.GetProperty("text").GetString(), 1000);
        var quiet = e.GetProperty("quiet").GetBoolean();
        try
        {
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
            foreach (var action in e.GetProperty("actions").EnumerateArray().Take(5)) // Windows shows up to 5 buttons
            {
                var label = Clean(action.GetProperty("title").GetString(), 40);
                var button = new AppNotificationButton(label).AddArgument("key", key).AddArgument("action", index.ToString());
                if (action.GetProperty("reply").GetBoolean())
                {
                    builder.AddTextBox("reply", label, "");
                    button.SetInputId("reply");
                }
                builder.AddButton(button);
                index++;
            }
            if (quiet) builder.MuteAudio();
            var notification = builder.BuildNotification();
            notification.Tag = Tag(key);
            notification.Group = PhoneGroup;
            notification.SuppressDisplay = quiet; // in the notification center only, no pop-up
            AppNotificationManager.Default.Show(notification);
            if (notification.Id == 0) return; // not shown (notifications off for Nearside)
            shown[notification.Tag] = (key, DateTime.UtcNow);
            // Windows keeps 20 per app and drops the oldest: those aren't cleared by the user, so
            // they're no longer tracked (never dismissed on the phone for it).
            foreach (var old in shown.OrderByDescending(p => p.Value.Shown).Skip(MaxTracked).Select(p => p.Key).ToList()) shown.Remove(old);
            Log.Info($"notification shown{(quiet ? " (quiet)" : "")}, {shown.Count} on screen");
        }
        catch (Exception error)
        {
            Log.Error($"a notification couldn't be shown: {error.GetType().Name}"); // no content in the log
        }
    }

    private static void ShowLocal(JsonElement e)
    {
        var id = e.GetProperty("id").GetString()!;
        try
        {
            var notification = new AppNotificationBuilder()
                .AddArgument("key", id)
                .AddArgument("local", "1")
                .AddText(Clean(e.GetProperty("title").GetString(), 200))
                .AddText(Clean(e.GetProperty("body").GetString(), 1000))
                .BuildNotification();
            notification.Tag = Tag(id);
            notification.Group = LocalGroup;
            AppNotificationManager.Default.Show(notification);
        }
        catch (Exception error)
        {
            Log.Error($"a notification couldn't be shown: {error.GetType().Name}");
        }
    }

    /// Text for a notification: bounded, without characters XML can't carry.
    private static string Clean(string? text, int limit)
    {
        if (string.IsNullOrEmpty(text)) return "";
        var kept = new StringBuilder(Math.Min(text.Length, limit));
        foreach (var c in text)
        {
            if (kept.Length == limit) break;
            if (c is '\t' or '\n' or '\r' || (c >= 0x20 && c != 0xFFFE && c != 0xFFFF)) kept.Append(c);
        }
        // Don't end on half a surrogate pair.
        if (kept.Length > 0 && char.IsHighSurrogate(kept[^1])) kept.Length--;
        return kept.ToString();
    }

    private void Remove(string key)
    {
        var tag = Tag(key);
        shown.Remove(tag);
        _ = AppNotificationManager.Default.RemoveByTagAndGroupAsync(tag, PhoneGroup);
    }

    /// The ones no longer in the notification center were cleared on this PC: dismiss them on the phone.
    /// Fails closed: nothing is dismissed unless notifications are on and the center's list looks whole.
    private async Task ReconcileAsync()
    {
        if (shown.Count == 0 || !Enabled) return;
        var all = await AppNotificationManager.Default.GetAllAsync();
        if (!Enabled || all.Count == 0) return; // turned off meanwhile, or an empty answer: no conclusions
        var present = all.Select(n => n.Tag).ToHashSet();
        var settled = DateTime.UtcNow.AddSeconds(-3); // just-shown ones may not be listed yet
        foreach (var (tag, entry) in shown.ToList())
        {
            if (present.Contains(tag) || entry.Shown > settled) continue;
            shown.Remove(tag);
            Log.Info("notification cleared on this PC: dismissing it on the phone");
            EngineHost.Command("notifDismissed", new { key = entry.Key });
        }
    }

    private static bool Enabled => AppNotificationManager.Default.Setting == AppNotificationSetting.Enabled;

    private void Invoked(Dictionary<string, string> args, Dictionary<string, string> input)
    {
        if (args.TryGetValue("call", out var call))
        {
            CallInvoked(call, args, input);
            return;
        }
        if (!args.TryGetValue("key", out var key)) return;
        // The engine treats "file:" keys as files it saved (a click reveals them): only our own
        // notifications may carry one.
        if (key.StartsWith("file:", StringComparison.Ordinal) && !args.ContainsKey("local")) return;
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
