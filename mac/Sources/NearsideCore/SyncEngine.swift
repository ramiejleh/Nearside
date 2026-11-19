import Foundation
import Observation

/// Everything the UI shows: connection state, clipboard history, unseen arrivals, setup progress.
@MainActor
@Observable
public final class SyncEngine {
    public enum State: Equatable, Sendable {
        case adbMissing      // can't work at all until adb is installed
        case needsSetup      // never paired: show the setup flow
        case searching       // paired, phone not reachable right now
        case connected
    }

    public struct SetupStep: Identifiable, Equatable, Sendable {
        public enum Status: Equatable, Sendable { case pending, running, done, failed(String) }
        public let id: Int
        public let title: String
        public var status: Status
    }

    public private(set) var state: State
    public private(set) var phoneName: String
    public private(set) var history: ClipHistory
    /// Phone clips that arrived since the panel was last opened.
    public private(set) var unseenIDs: Set<UUID> = []
    public private(set) var setupSteps: [SetupStep] = []
    public private(set) var isPairing = false

    /// Called for every clip that arrives from the phone (drives the arrival toast).
    public var onArrival: ((ClipItem) -> Void)?

    public var historyLimit: Int {
        get { history.limit }
        set { history.limit = newValue; persist() }
    }

    private let apkURL: URL?
    private let defaults = UserDefaults.standard
    private let link = HelperLink()
    private var pasteboard: PasteboardWatcher!
    private var preparing = false
    private var started = false

    public init(apkURL: URL?) {
        self.apkURL = apkURL
        let limit = defaults.object(forKey: "historyLimit") as? Int ?? 200
        history = ClipHistory.load(from: Paths.history, limit: limit)
        phoneName = defaults.string(forKey: "phoneName") ?? "Phone"
        if Adb.path == nil {
            state = .adbMissing
        } else {
            // Set up = completed the pairing flow, which is the only place a phone gets pinned.
            let pinned = defaults.string(forKey: "phoneSerial") != nil
            state = defaults.bool(forKey: "setupComplete") && pinned ? .searching : .needsSetup
        }
    }

    // MARK: Lifecycle

    public func start() {
        guard !started else { return }
        started = true
        pasteboard = PasteboardWatcher { [weak self] text in self?.macCopied(text) }
        pasteboard.start()

        link.onMessage = { [weak self] message in self?.handle(message) }
        link.onDisconnect = { [weak self] in
            guard let self, state == .connected else { return }
            state = .searching
        }

        // Keep the helper and tunnel alive: whenever we're idle, try to (re)establish them.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }.fire()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let pinned = self?.pinnedSerial else { return }
                Task.detached { Adb.renewAuthorization(pinned: pinned) }
            }
        }
    }

    /// Hardware serial of the one phone we work with; nothing else is ever connected to.
    private var pinnedSerial: String? {
        get { defaults.string(forKey: "phoneSerial") }
        set { defaults.set(newValue, forKey: "phoneSerial") }
    }

    private func tick() {
        // Only ever talk to the phone pinned during the user-run pairing flow; no discovery
        // of "whatever phone is around" (that would let a look-alike device be adopted).
        guard link.isIdle, !preparing, !isPairing, state == .searching || state == .connected,
              let pinned = pinnedSerial else { return }
        preparing = true
        Task {
            let phone = await Task.detached { Adb.prepareHelper(pinned: pinned) }.value
            preparing = false
            guard let phone else { return }
            adopt(phone)
            link.connect()
        }
    }

    private func adopt(_ phone: Adb.Phone) {
        if let model = phone.model {
            phoneName = model
            defaults.set(model, forKey: "phoneName")
        }
    }

    // MARK: Messages

    private func handle(_ message: [String: Any]) {
        switch message["t"] as? String {
        case "hello":
            state = .connected
        case "clip":
            guard state == .connected, let text = message["text"] as? String, !text.isEmpty else { return }
            pasteboard.write(text)
            let item = history.add(text, source: .android)
            unseenIDs.insert(item.id)
            persist()
            onArrival?(item)
        default:
            break
        }
    }

    private func macCopied(_ text: String) {
        history.add(text, source: .mac)
        persist()
        if state == .connected {
            link.send(["t": "clip", "text": text, "ts": Int64(Date().timeIntervalSince1970 * 1000)])
        }
    }

    // MARK: User actions

    /// Puts a history item back on both clipboards.
    public func use(_ item: ClipItem) {
        pasteboard.write(item.text)
        if state == .connected {
            link.send(["t": "clip", "text": item.text, "ts": Int64(Date().timeIntervalSince1970 * 1000)])
        }
        history.promote(id: item.id)
        unseenIDs.remove(item.id)
        persist()
    }

    public func delete(_ item: ClipItem) {
        history.remove(id: item.id)
        unseenIDs.remove(item.id)
        persist()
    }

    public func clearHistory() {
        history.clear()
        unseenIDs.removeAll()
        persist()
    }

    public func markAllSeen() {
        unseenIDs.removeAll()
    }

    /// Forget the phone and show the setup flow again.
    public func resetSetup() {
        defaults.set(false, forKey: "setupComplete")
        pinnedSerial = nil
        link.disconnect()
        setupSteps = []
        state = .needsSetup
    }

    private func persist() {
        defaults.set(history.limit, forKey: "historyLimit")
        try? history.save(to: Paths.history)
    }

    // MARK: Setup

    /// One-time setup from the phone's "Pair device with pairing code" screen.
    public func pair(hostPort: String, code: String) {
        guard !isPairing else { return }
        isPairing = true
        link.disconnect()
        let titles = [
            "Pair with your phone",
            "Connect over Wi-Fi",
            "Install Nearside on the phone",
            "Grant background permissions",
            "Start clipboard sync",
        ]
        setupSteps = titles.enumerated().map { SetupStep(id: $0.offset, title: $0.element, status: .pending) }
        let apkPath = apkURL?.path

        Task {
            defer { isPairing = false }
            let run = runStep

            // Pairing tells us the phone's hardware serial; from here on only that phone is used.
            setupSteps[0].status = .running
            let host = hostPort.trimmingCharacters(in: .whitespaces)
            let pin = code.trimmingCharacters(in: .whitespaces)
            let paired = await Task.detached { Adb.run(["pair", host, pin]) }.value
            guard paired.ok, paired.out.contains("Successfully paired"),
                  let phoneSerial = Adb.serialFromPairOutput(paired.out) else {
                setupSteps[0].status = .failed(Self.friendly(paired.out))
                return
            }
            setupSteps[0].status = .done
            pinnedSerial = phoneSerial

            guard await run(1, {
                Adb.ensureConnected(pinned: phoneSerial, wait: 20) == nil ? "Paired, but the phone isn't visible on the network. Keep Wireless debugging open and try again." : nil
            }) else { return }

            guard await run(2, {
                guard let apkPath else { return "The app bundle is missing nearside.apk." }
                guard let serial = Adb.ensureConnected(pinned: phoneSerial) else { return "Lost the connection to the phone." }
                let r = Adb.run(["-s", serial, "install", "-r", apkPath], timeout: 180)
                return r.ok ? nil : Self.friendly(r.out)
            }) else { return }

            guard await run(3, {
                guard let serial = Adb.ensureConnected(pinned: phoneSerial) else { return "Lost the connection to the phone." }
                let pkg = Adb.appPackage
                _ = Adb.shell(serial, "pm grant \(pkg) android.permission.WRITE_SECURE_SETTINGS")
                _ = Adb.shell(serial, "cmd deviceidle whitelist +\(pkg)")
                // Launching once takes the app out of the "stopped" state so it gets BOOT_COMPLETED.
                _ = Adb.shell(serial, "am start -n \(pkg)/.MainActivity")
                return nil
            }) else { return }

            setupSteps[4].status = .running
            let phone = await Task.detached { Adb.prepareHelper(pinned: phoneSerial) }.value
            guard let phone else {
                setupSteps[4].status = .failed("The clipboard helper didn't start. Make sure Wireless debugging is still on.")
                return
            }
            setupSteps[4].status = .done
            defaults.set(true, forKey: "setupComplete")
            state = .searching
            adopt(phone)
            link.connect()
        }
    }

    /// Runs one setup step off the main thread. `work` returns nil on success, else an error message.
    private func runStep(_ index: Int, _ work: @escaping @Sendable () -> String?) async -> Bool {
        setupSteps[index].status = .running
        if let error = await Task.detached(operation: work).value {
            setupSteps[index].status = .failed(error)
            return false
        }
        setupSteps[index].status = .done
        return true
    }

    nonisolated private static func friendly(_ adbOutput: String) -> String {
        if adbOutput.contains("Wrong password") || adbOutput.contains("failed to pair") {
            return "The pairing code didn't work. Codes expire quickly; tap \"Pair device with pairing code\" again for a new one."
        }
        if adbOutput.contains("Connection refused") || adbOutput.contains("cannot connect") {
            return "Couldn't reach the phone. Check the IP address and port, and that both devices are on the same Wi-Fi."
        }
        return adbOutput.isEmpty ? "Something went wrong." : adbOutput
    }
}
