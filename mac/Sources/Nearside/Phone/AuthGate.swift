import AppKit
import LocalAuthentication

/// Touch ID (or the Mac's password) before phone apps show. Phone apps work while the phone is
/// locked, and the windows' virtual device is always unlocked, so the Mac has to be the lock:
/// by default once after each wake or unlock of the Mac.
@MainActor
final class AuthGate {
    enum Mode: String, CaseIterable, Comparable {
        case never
        case afterWake
        case everyOpen

        static func < (a: Mode, b: Mode) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }

        var title: String {
            switch self {
            case .never: "Never"
            case .afterWake: "After the Mac wakes or unlocks"
            case .everyOpen: "Every time an app opens"
            }
        }
    }

    static let modeKey = "PhoneApps.authentication"

    static var mode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .afterWake
    }

    private(set) var unlocked = false
    /// Called when the Mac sleeps or locks (open windows cover themselves).
    var onLock: () -> Void = {}
    private var asking: Task<Bool, Never>?

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
    }

    /// Whether a window covered by the lock needs unlocking before it shows again.
    var isLocked: Bool { Self.mode != .never && !unlocked }

    private func lock() {
        guard unlocked else { return }
        unlocked = false
        onLock()
    }

    /// Asks if needed; true once the person has proven it's them (or nothing is asked).
    /// `opening` is true when a new app window is about to open.
    func authenticate(opening: Bool) async -> Bool {
        switch Self.mode {
        case .never: return true
        case .afterWake: if unlocked { return true }
        case .everyOpen: if unlocked, !opening { return true }
        }
        let ok = await ask("show your phone's apps")
        if ok { unlocked = true }
        return ok
    }

    /// Always asks: for turning the protection down in Settings.
    func confirm(_ reason: String) async -> Bool { await ask(reason) }

    private func ask(_ reason: String) async -> Bool {
        if let asking { return await asking.value } // one prompt at a time
        let task = Task { @MainActor in
            let context = LAContext()
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                NSLog("Nearside: can't ask for authentication (\(error?.localizedDescription ?? "?")); allowing")
                return true
            }
            NSApp.activate()
            do {
                return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            } catch {
                return false
            }
        }
        asking = task
        defer { asking = nil }
        return await task.value
    }
}
