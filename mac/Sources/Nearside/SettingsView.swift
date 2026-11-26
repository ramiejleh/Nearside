import NearsideCore
import NearsideMac
import ServiceManagement
import SwiftUI

/// In-panel settings page (opened from the gear in the header).
struct SettingsView: View {
    let engine: SyncEngine
    let onDone: () -> Void
    let openSetup: () -> Void

    @AppStorage("showArrivalToast") private var showArrivalToast = true
    @State private var phoneAppsAuth = AuthGate.mode
    @AppStorage(PhoneSpotlight.enabledKey) private var phoneAppsInSpotlight = true
    @AppStorage(PhoneAppLaunchers.enabledKey) private var phoneAppLaunchers = false
    @AppStorage("PhoneApps.motion") private var phoneAppsMotion = "smooth"
    @AppStorage("PhoneApps.notificationClick") private var notificationClick = "phone"
    @AppStorage(PhoneQuality.key) private var phoneQuality = PhoneQuality.auto.rawValue
    @AppStorage(PhoneFrameRate.key) private var phoneFrameRate = 60
    @AppStorage(PhoneSound.key) private var phoneSound = "mac"
    @AppStorage(PhoneSound.microphoneKey) private var phoneMicrophone = true
    @AppStorage(Webcam.frontKey) private var webcamFront = false
    @AppStorage(AppWindowController.keyboardLayoutKey) private var keyboardLayout = ""
    @AppStorage(AppWindowController.returnAfterKey) private var returnAfter = 0
    @State private var phoneLayouts: [String] = []
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var automaticUpdates = Updates.automaticChecks
    @State private var confirmReset = false
    @State private var permissions = Permissions()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                // What the panel shows and Nearside does: each feature's own switch. Their details
                // are in the sections below.
                Section {
                    Toggle(isOn: Binding(get: { engine.clipboardSync }, set: { engine.clipboardSync = $0 })) {
                        Label("Clipboard", systemImage: "doc.on.clipboard")
                        Text("Copy on one device, paste on the other, with a history in the panel.")
                    }
                    Toggle(isOn: Binding(get: { engine.mirrorNotifications }, set: { engine.mirrorNotifications = $0 })) {
                        Label("Notifications", systemImage: "bell")
                        Text("Your \(engine.phoneName)'s notifications on this Mac and in the panel. Dismissing one here dismisses it on the phone.")
                    }
                    Toggle(isOn: Binding(get: { engine.recentPhotos }, set: { engine.recentPhotos = $0 })) {
                        Label("Photos", systemImage: "photo.on.rectangle")
                        Text("The phone's newest photos in the panel, while it's open. Drag one out to keep it.")
                    }
                    Toggle(isOn: Binding(get: { engine.textMessages }, set: { engine.textMessages = $0 })) {
                        Label("Text messages", systemImage: "message")
                        Text("Read and send SMS in the Messages window. RCS chats stay in Google Messages.")
                    }
                    Toggle(isOn: Binding(get: { engine.showCalls }, set: { engine.showCalls = $0 })) {
                        Label("Calls", systemImage: "phone")
                        Text(engine.mirrorNotifications
                             ? "Answer or decline phone and app calls here."
                             : "Needs Notifications on: calls come from the phone's call notification.")
                    }
                    .disabled(!engine.mirrorNotifications)
                } header: {
                    Text("Features")
                } footer: {
                    Text("Turned off, a feature leaves the panel and nothing of it crosses between your devices.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                Section("Notifications") {
                    NotificationApps(engine: engine)
                    Picker(selection: $notificationClick) {
                        Text("On your phone").tag("phone")
                        Text("On this Mac").tag("mac")
                    } label: {
                        Text("Clicking a notification opens it")
                        Text("Either way, “Open on Mac” in a notification’s options opens it in a window here.")
                    }
                }
                .disabled(!engine.mirrorNotifications)

                Section("Calls") {
                    Toggle(isOn: Binding(get: { engine.ringOnMac }, set: { engine.ringOnMac = $0 })) {
                        Text("Ring on this Mac")
                        Text("A soft ring while a call comes in.")
                    }
                    .disabled(!engine.mirrorNotifications || !engine.showCalls)
                }

                Section("Phone apps") {
                    Picker(selection: Binding(get: { phoneAppsAuth }, set: { mode in
                        Task { @MainActor in
                            if await PhoneWindowManager.shared?.changeAuthMode(to: mode) == true { phoneAppsAuth = mode }
                        }
                    })) {
                        ForEach(AuthGate.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: {
                        Text("Ask for Touch ID")
                        Text("Phone apps work while your phone is locked, so your Mac asks before showing them.")
                    }
                    Toggle(isOn: $phoneAppsInSpotlight) {
                        Text("Show in Spotlight")
                        Text("Find your phone's apps in Spotlight and open them here.")
                    }
                    .onChange(of: phoneAppsInSpotlight) { _, on in
                        if on { PhoneWindowManager.shared?.library.refresh() } else { PhoneSpotlight.remove() }
                    }
                    Toggle(isOn: $phoneAppLaunchers) {
                        Text("Add to Applications")
                        Text("For Raycast, Alfred and Launchpad: each phone app becomes a small app in Applications › Nearside Phone Apps that opens it here.")
                    }
                    .onChange(of: phoneAppLaunchers) { _, on in
                        if !on { PhoneAppLaunchers.removeAll() }
                        PhoneWindowManager.shared?.indexApps() // the launchers, and Spotlight's entries follow
                    }
                    Picker(selection: $phoneAppsMotion) {
                        Text("Smooth").tag("smooth")
                        Text("Responsive").tag("responsive")
                    } label: {
                        Text("Motion")
                        Text(phoneAppsMotion == "responsive"
                             ? "Less delay; some frames are skipped when Wi-Fi is uneven."
                             : "Frames shown evenly, with only as much delay as the connection needs. For windows opened from now on.")
                    }
                    Picker(selection: $phoneQuality) {
                        ForEach(PhoneQuality.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    } label: {
                        Text("Quality")
                        Text((PhoneQuality(rawValue: phoneQuality) ?? .auto).detail + " For windows opened from now on.")
                    }
                    Picker(selection: $phoneFrameRate) {
                        ForEach(PhoneFrameRate.choices, id: \.self) { Text("\($0) fps").tag($0) }
                    } label: {
                        Text("Frame rate")
                        Text(phoneFrameRate > 60
                             ? "Smoother scrolling on a fast screen; needs good Wi-Fi and Android 14 or later. For windows opened from now on."
                             : "For windows opened from now on.")
                    }
                    Picker(selection: $phoneSound) {
                        Text("On this Mac").tag("mac")
                        Text("On your phone").tag("phone")
                    } label: {
                        Text("Play sound")
                        Text("For windows opened from now on.")
                    }
                    Toggle(isOn: $phoneMicrophone) {
                        Text("Use this Mac's microphone")
                        Text("While an app in a window records, for a call or a voice message. Off: it records from your phone.")
                    }
                    .disabled(phoneSound == "phone")
                    Picker(selection: $keyboardLayout) {
                        Text("Same as this Mac").tag("")
                        ForEach(phoneLayouts, id: \.self) { Text($0).tag($0) }
                    } label: {
                        Text("Keyboard layout")
                        Text("The layout phone apps use for what you type here.")
                    }
                    .task {
                        if let layouts = await engine.phoneKeyboardLayouts() {
                            phoneLayouts = keyboardLayout.isEmpty || layouts.contains(keyboardLayout) ? layouts : [keyboardLayout] + layouts
                        } else if !keyboardLayout.isEmpty {
                            phoneLayouts = [keyboardLayout]
                        }
                    }
                    .onChange(of: keyboardLayout) { _, _ in
                        NotificationCenter.default.post(name: PhoneWindowManager.keyboardLayoutSettingChanged, object: nil)
                    }
                    Picker(selection: $returnAfter) {
                        Text("Never").tag(0)
                        ForEach([5, 15, 30, 60], id: \.self) { Text("After \($0) minutes").tag($0) }
                    } label: {
                        Text("Return hidden apps to the phone")
                        Text("When a window stays minimised or out of sight that long, its app goes back to your phone.")
                    }
                    LabeledContent {
                        ShortcutRecorder()
                    } label: {
                        Text("Open the launcher")
                        Text("From anywhere. Use ⌘ or ⌃ with a key.")
                    }
                }

                Section {
                    ForEach(Permissions.kinds) { PermissionRow(permissions: permissions, kind: $0) }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("What macOS lets Nearside do. If something stops working, check here first.")
                }

                if let webcam = Webcam.shared {
                    Section("Phone camera") {
                        Toggle(isOn: Binding(get: { webcam.enabled }, set: { webcam.enabled = $0 })) {
                            Text("Use your phone as a webcam")
                            Text(webcam.status.isEmpty
                                 ? "“Nearside Camera” in FaceTime, Zoom and browsers. The phone's camera is on only while an app uses it."
                                 : webcam.status)
                        }
                        Picker(selection: $webcamFront) {
                            Text("Back").tag(false)
                            Text("Front").tag(true)
                        } label: {
                            Text("Camera")
                            Text("The back camera is the better one. Takes effect the next time an app starts it.")
                        }
                        .disabled(!webcam.enabled)
                    }
                }

                Section("Screenshots") {
                    Toggle(isOn: Binding(get: { engine.screenshotsToMac }, set: { engine.screenshotsToMac = $0 })) {
                        Text("New phone screenshots go to this Mac")
                        Text("Each one lands in Downloads.")
                    }
                    Toggle(isOn: Binding(get: { engine.screenshotsToPhone }, set: { engine.screenshotsToPhone = $0 })) {
                        Text("Mac screenshots go to the phone")
                        Text("Into Pictures/Nearside, where the phone's gallery shows them.")
                    }
                }

                Section("Clipboard") {
                    Toggle(isOn: $showArrivalToast) {
                        Text("Pop-up when a clip arrives")
                        Text("A card slides in at the top right when you copy on your \(engine.phoneName).")
                    }
                    Picker("Keep in history", selection: Binding(get: { engine.historyLimit }, set: { engine.historyLimit = $0 })) {
                        Text("50 items").tag(50)
                        Text("200 items").tag(200)
                        Text("500 items").tag(500)
                    }
                    LabeledContent("Saved items", value: engine.history.items.count.formatted())
                }
                .disabled(!engine.clipboardSync)

                Section("General") {
                    Toggle("Open at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in
                            do {
                                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            } catch {
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                    if Updates.available {
                        Toggle("Check for updates automatically", isOn: $automaticUpdates)
                            .onChange(of: automaticUpdates) { _, on in Updates.automaticChecks = on }
                        Button("Check for Updates…") { Updates.checkNow() }
                    }
                }

                if engine.state == .connected, engine.clipboardToastHidden != nil {
                    Section("On the phone") {
                        Toggle(isOn: Binding(get: { engine.clipboardToastHidden ?? false },
                                             set: { engine.setClipboardToastHidden($0) })) {
                            Text("Hide \u{201C}pasted from your clipboard\u{201D} on the phone")
                            Text("Android's own phone-wide switch: with it off, you also won't see when other apps read your clipboard.")
                        }
                    }
                }

                do {
                    Section("Phone") {
                        LabeledContent("Paired with", value: engine.state == .needsSetup ? "Nothing yet" : engine.phoneName)
                        Toggle(isOn: Binding(get: { engine.lowBatteryAlert }, set: { engine.lowBatteryAlert = $0 })) {
                            Text("Notify when the battery is low")
                            Text("Once, at \(PhoneStatus.LowBatteryAlert.threshold)%, unless it's charging.")
                        }
                        if engine.state == .connected {
                            LabeledContent("Phone app") {
                                Label(engine.appLinked ? "Linked" : "Not linked",
                                      systemImage: engine.appLinked ? "checkmark.circle.fill" : "exclamationmark.circle")
                                    .foregroundStyle(engine.appLinked ? .green : .orange)
                            }
                        }
                        if engine.state != .needsSetup {
                            if confirmReset {
                                HStack {
                                    Text("Forget \(engine.phoneName)?")
                                    Spacer()
                                    Button("Cancel") { confirmReset = false }
                                    Button("Forget", role: .destructive) {
                                        confirmReset = false
                                        engine.resetSetup()
                                        onDone()
                                        openSetup()
                                    }
                                    .tint(.red)
                                }
                            } else {
                                Button("Set Up a Phone Again…") { confirmReset = true }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tint(.green) // switches are green when on (the form's only tinted controls)
            .scrollContentBackground(.hidden)
            .onAppear { permissions.startWatching() }
            .onDisappear { permissions.stopWatching() }

            Divider()
            HStack {
                Text("Nearside \(Self.version)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit Nearside") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .font(.system(size: 11))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// The launcher's shortcut: click, then press the new one (Esc cancels).
private struct ShortcutRecorder: View {
    @State private var shortcut = LauncherShortcut.current
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "Type a shortcut…" : shortcut.title) { recording ? stop() : start() }
                .monospacedDigit()
            if shortcut != .default && !recording {
                Button { save(.default) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help("Back to ⌥⌘P")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil } // Esc
            if let new = LauncherShortcut(event) { save(new); stop() } else { NSSound.beep() }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func save(_ new: LauncherShortcut) {
        shortcut = new
        LauncherShortcut.current = new
    }
}
