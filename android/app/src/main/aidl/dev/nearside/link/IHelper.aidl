package dev.nearside.link;

import android.app.PendingIntent;
import android.content.Intent;

/** Implemented by the shell-uid helper; called by the Nearside app. */
interface IHelper {
    /** Relays one JSON message to the Mac. False when no Mac is connected or it's rejected. */
    boolean sendToMac(String json);
    boolean isMacConnected();
    /**
     * Fires a notification's PendingIntent as shell, which may start activities from the
     * background (apps can't), so "open" and app-opening buttons work from the Mac.
     */
    boolean sendIntent(in PendingIntent intent, in Intent fillIn);
}
