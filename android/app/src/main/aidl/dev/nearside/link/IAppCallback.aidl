package dev.nearside.link;

/** Implemented by the Nearside app; called by the helper. */
oneway interface IAppCallback {
    /** A JSON message from the Mac that the helper doesn't handle itself (anything but clips). */
    void onMessage(String json);
    void onMacConnectionChanged(boolean connected);
}
