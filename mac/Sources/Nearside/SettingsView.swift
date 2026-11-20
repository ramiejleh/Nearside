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
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmReset = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Notifications") {
                    Toggle(isOn: Binding(get: { engine.mirrorNotifications }, set: { engine.mirrorNotifications = $0 })) {
                        Text("Mirror phone notifications")
                        Text("Your \(engine.phoneName)'s notifications appear on this Mac. Dismissing one here dismisses it on the phone.")
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
                    LabeledContent("Open the launcher", value: "⌥⌘P")
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
            .scrollContentBackground(.hidden)

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
