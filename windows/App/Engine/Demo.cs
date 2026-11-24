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
        };
    }
}
