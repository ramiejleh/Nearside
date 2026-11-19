import NearsideCore
import SwiftUI

@main
struct NearsideApp: App {
    @State private var engine: SyncEngine
    private let toast = ArrivalToastController()

    init() {
        let engine = SyncEngine(apkURL: Bundle.main.url(forResource: "nearside", withExtension: "apk"))
        let toast = toast
        engine.onArrival = { [weak engine] item in
            toast.show(item, from: engine?.phoneName ?? "Phone")
        }
        engine.start()
        _engine = State(initialValue: engine)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(engine: engine)
        } label: {
            MenuBarLabel(engine: engine)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Phone glyph, plus a count of phone clips you haven't looked at yet.
struct MenuBarLabel: View {
    let engine: SyncEngine

    var body: some View {
        let symbol = switch engine.state {
        case .connected: "smartphone"
        case .searching, .needsSetup: "antenna.radiowaves.left.and.right.slash"
        case .adbMissing: "exclamationmark.triangle"
        }
        if engine.unseenIDs.isEmpty {
            Image(systemName: symbol)
        } else {
            // Image + text renders as icon and title in the menu bar.
            Label("\(engine.unseenIDs.count)", systemImage: symbol)
                .labelStyle(.titleAndIcon)
        }
    }
}
