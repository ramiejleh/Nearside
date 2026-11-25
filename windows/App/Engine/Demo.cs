namespace Nearside.Engine;

/// Made-up content for screenshots (Nearside.exe --demo).
internal static class Demo
{
    public static Snapshot Snapshot(bool setup)
    {
        if (setup)
        {
            return new Snapshot
            {
                State = "needsSetup",
                QrPayload = "WIFI:T:ADB;S:nearside-demo;P:demo-password;;",
                Settings = new Settings { MirrorNotifications = true, TextMessages = true },
                ClipboardToastHidden = false,
            };
        }
        var now = DateTimeOffset.Now;
        long Ago(double minutes) => now.AddMinutes(-minutes).ToUnixTimeMilliseconds();
        return new Snapshot
        {
            State = "connected",
            PhoneName = "Pixel 9 Pro",
            AppLinked = true,
            PhoneStatus = new PhoneStatus(76, false, true, 3, "5G"),
            History =
            [
                new("1", "Table for four at 19:30, under the name Kim", true, Ago(0.5)),
                new("2", "https://example.com/trail-maps/north-ridge", false, Ago(4)),
                new("3", "Gate B14, boarding from 10:05", true, Ago(38)),
                new("4", "Remember to bring the charger and the blue folder", false, Ago(130)),
                new("5", "+45 12 34 56 78", true, Ago(1500)),
            ],
            Unseen = ["1"],
            Transfers = [new("t1", "holiday-photos.zip", true, "inProgress", null, null)],
            ClipboardToastHidden = false,
            Settings = new Settings { MirrorNotifications = true, TextMessages = true, HistoryLimit = 200, LowBatteryAlert = true },
            Calls = new CallsView
            {
                Show = true,
                AudioHere = true,
                Pinned = "c1",
                List = [new PhoneCall { Key = "c1", Package = "com.google.android.dialer", App = "Phone", State = "ongoing", Title = "Kim",
                    Kind = "Phone call", Can = ["hangup"], IsPhone = true, Number = "+45 20 30 40 50", Since = Ago(3.4) }],
            },
            Messages = new MessagesView
            {
                Loaded = true,
                Selected = 1,
                Threads =
                [
                    new(1, "+45 20 30 40 50", "Kim", "Kim", "See you at the station", Ago(2), false, 1),
                    new(2, "+45 60 70 80 90", "Alex", "Alex", "Thanks, got it", Ago(90), true, 0),
                    new(3, "1234", "1234", null, "Your parcel is ready for pickup", Ago(1500), false, 0),
                ],
                Conversation =
                [
                    new(11, "Are we still on for Saturday?", Ago(70), true, false, false, true, false, true),
                    new(12, "Yes! Train at 10:15", Ago(69), false, false, false, true, true, false),
                    new(13, "Perfect", Ago(68), true, false, false, true, false, false),
                    new(14, "I'll bring the map", Ago(67.5), true, false, false, false, true, false),
                    new(15, "See you at the station", Ago(2), false, false, false, true, true, true),
                ],
            },
        };
    }
}
