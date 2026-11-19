package dev.nearside.link;

/** Implemented by the shell-uid helper; called by the Nearside app. */
interface IHelper {
    /** Relays one JSON message to the Mac. False when no Mac is connected or it's rejected. */
    boolean sendToMac(String json);
    boolean isMacConnected();
}
