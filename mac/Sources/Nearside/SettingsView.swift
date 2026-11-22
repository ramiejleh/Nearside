import NearsideCore
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
    @AppStorage(PhoneSound.key) private var phoneSound = "mac"
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
                Section("Notifications") {
                    Toggle(isOn: Binding(get: { engine.mirrorNotifications }, set: { engine.mirrorNotifications = $0 })) {
                        Text("Mirror phone notifications")
                        Text("Your \(engine.phoneName)'s notifications appear on this Mac. Dismissing one here dismisses it on the phone.")
                    }
                    Picker(selection: $notificationClick) {
                        Text("On your phone").tag("phone")
                        Text("On this Mac").tag("mac")
                    } label: {
                        Text("Clicking a notification opens it")
                        Text("Either way, “Open on Mac” in a notification’s options opens it in a window here.")
                    }
                    Toggle(isOn: $showArrivalToast) {
                        Text("Pop-up when a clip arrives")
                        Text("A card slides in at the top right when you copy on your \(engine.phoneName).")
                    }
                }

                Section("Text messages") {
                    Toggle(isOn: Binding(get: { engine.textMessages }, set: { engine.textMessages = $0 })) {
                        Text("Read and send SMS")
                        Text("In the Messages window (the bubble in the header). RCS chats stay in Google Messages.")
                    }
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
                    Picker(selection: $phoneSound) {
                        Text("On this Mac").tag("mac")
                        Text("On your phone").tag("phone")
                    } label: {
                        Text("Play sound")
                        Text("For windows opened from now on. Calls always stay on the phone.")
                    }
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

                Section("History") {
                    Picker("Keep", selection: Binding(get: { engine.historyLimit }, set: { engine.historyLimit = $0 })) {
                        Text("50 items").tag(50)
                        Text("200 items").tag(200)
                        Text("500 items").tag(500)
                    }
                    LabeledContent("Saved items", value: engine.history.items.count.formatted())
                }

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
                    Section("Clipboard") {
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
