using System.Text.Json;
using System.Text.Json.Serialization;

namespace Nearside.Engine;

/// What the engine shows, as the bridge sends it (windows/Sources/NearsideBridge/Snapshot.swift).
public sealed record Snapshot
{
    public string State { get; init; } = "needsSetup";
    public bool OverUSB { get; init; }
    public string PhoneName { get; init; } = "";
    public bool AppLinked { get; init; }
    public bool IsPairing { get; init; }
    public bool ReinstallingPhoneApp { get; init; }
    public string? InUseOn { get; init; }
    public string? QrPayload { get; init; }
    public bool? ClipboardToastHidden { get; init; }
    public PhoneStatus? PhoneStatus { get; init; }
    public PhoneAppProblem? PhoneAppProblem { get; init; }
    public List<Clip> History { get; init; } = [];
    public List<string> Unseen { get; init; } = [];
    public List<Transfer> Transfers { get; init; } = [];
    public List<SetupStep> SetupSteps { get; init; } = [];
    public Settings Settings { get; init; } = new();
    /// Only while the Messages window is open.
    public MessagesView? Messages { get; init; }

    public bool Connected => State == "connected";
    public bool NeedsSetup => State == "needsSetup";

    public static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };
}

public sealed record Clip(string Id, string Text, bool FromPhone, long Date)
{
    public DateTimeOffset When => DateTimeOffset.FromUnixTimeMilliseconds(Date);
}

public sealed record Transfer(string Id, string Name, bool ToPhone, string Status, string? Path, string? Message);

public sealed record SetupStep(int Id, string Title, string Status, string? Message);

public sealed record PhoneStatus(int Battery, bool Charging, bool Wifi, int? Signal, string? Network);

public sealed record Settings
{
    public bool MirrorNotifications { get; init; }
    public bool TextMessages { get; init; }
    public bool RecentPhotos { get; init; }
    public bool ScreenshotsToPC { get; init; }
    public bool ScreenshotsToPhone { get; init; }
    public bool ShowCalls { get; init; }
    public bool RingHere { get; init; }
    public int HistoryLimit { get; init; }
    public bool LowBatteryAlert { get; init; }
}

public sealed record MessagesView
{
    public bool Loaded { get; init; }
    public List<MessageThread> Threads { get; init; } = [];
    public string? Problem { get; init; }
    public string? SendError { get; init; }
    public long? Selected { get; init; }
    public List<TextMessage> Conversation { get; init; } = [];
}

public sealed record MessageThread(long Id, string Address, string Title, string? Name, string Snippet, long Date, bool Outgoing, int Unread)
{
    public DateTimeOffset When => DateTimeOffset.FromUnixTimeMilliseconds(Date);
}

public sealed record TextMessage(long Id, string Body, long Date, bool Outgoing, bool Failed, bool Pending, bool First, bool Last, bool Header)
{
    public DateTimeOffset When => DateTimeOffset.FromUnixTimeMilliseconds(Date);
}

public sealed record PhoneAppProblem(string Kind, string? Message);
