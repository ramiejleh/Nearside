package dev.nearside.link;

import android.app.PendingIntent;
import android.content.Intent;
import android.os.ParcelFileDescriptor;

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
    /**
     * Sends a shared file to the Mac: the helper copies it to its staging dir and tells the
     * Mac, which pulls it over adb. False when no Mac is connected.
     */
    boolean sendFile(String name, in ParcelFileDescriptor fd);
}
