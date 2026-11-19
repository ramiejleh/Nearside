import NearsideCore
import ServiceManagement
import SwiftUI

/// In-panel settings page (opened from the gear in the header).
struct SettingsView: View {
    let engine: SyncEngine
    let onDone: () -> Void

    @AppStorage("showArrivalToast") private var showArrivalToast = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmReset = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Notifications") {
                    Toggle(isOn: $showArrivalToast) {
                        Text("Pop-up when a clip arrives")
                        Text("A card slides in at the top right when you copy on your \(engine.phoneName).")
                    }
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

                if engine.state != .adbMissing {
                    Section("Phone") {
                        LabeledContent("Paired with", value: engine.state == .needsSetup ? "Nothing yet" : engine.phoneName)
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
