import AppKit
import Foundation
import Observation
import os

/// Everything the UI shows: connection state, clipboard history, unseen arrivals, setup progress.
@MainActor
@Observable
public final class SyncEngine {
    public enum State: Equatable, Sendable {
        case needsSetup      // never paired: show the setup flow
        case searching       // paired, phone not reachable right now
        case connected
    }

    /// A file going to or coming from the phone (most recent first in `transfers`).
    public struct Transfer: Identifiable, Equatable, Sendable {
        public enum Direction: Sendable { case toPhone, toMac }
        public enum Status: Equatable, Sendable {
            case inProgress
            case done(URL?) // where it landed on the Mac (toMac), nil for toPhone
            case failed(String)
        }
        public let id: UUID
        public let name: String
        public let direction: Direction
        public var status: Status
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
    /// Whether the Nearside app on the phone is linked to the helper (needed for app features).
    public private(set) var appLinked = false
    public private(set) var transfers: [Transfer] = []
    /// Whether Android's phone-wide "pasted from your clipboard" toast is off; nil until read.
    public private(set) var clipboardToastHidden: Bool?

    /// SMS for the Messages window.
    public let messages = MessagesStore()

    /// Read and send SMS from the Mac. Turning it off revokes the phone app's SMS and contacts
    /// permissions, so nothing on the phone can read texts at all.
    public var textMessages: Bool {
        didSet {
            defaults.set(textMessages, forKey: "textMessages")
            if !textMessages { messages.reset() }
            applySmsAccess()
        }
    }

    /// Mirror the phone's notifications to macOS. Turning it off also revokes the phone app's
    /// notification access, so nothing is read on the phone at all.
    public var mirrorNotifications: Bool {
        didSet {
            defaults.set(mirrorNotifications, forKey: "mirrorNotifications")
            if !mirrorNotifications { notifications.removeAll() }
            applyNotificationAccess()
        }
    }

    /// Called for every clip that arrives from the phone (drives the arrival toast).
    public var onArrival: ((ClipItem) -> Void)?

    public var historyLimit: Int {
        get { history.limit }
        set { history.limit = newValue; persist() }
    }

    private let apkURL: URL?
    private let defaults = UserDefaults.standard
    private let link = HelperLink()
    private let notifications = PhoneNotifications()
    /// adb serial of the phone we're connected to right now (for one-off adb commands).
    private var adbSerial: String?
    private var pasteboard: PasteboardWatcher!
    private var preparing = false
    private var started = false
    private var displayRequests: [Int: CheckedContinuation<HelperReply?, Never>] = [:]
    private var nextDisplayRequest = 1
    /// Another Mac is using the phone (its name): this one waits until it's free, or until
    /// `useHere()`. Phone-app windows closed when it took over.
    public private(set) var inUseOn: String?
    private var waitTicks = 0

    /// "Use on this Mac": take the phone back from the other Mac.
    public func useHere() {
        inUseOn = nil
        link.passive = false
        tick()
    }

    /// The phone's "Stop" on its apps-open notification: close every phone-app window.
    public var onPhoneAppsStop: (() -> Void)?
    /// A phone notification to open in a Mac window: (key, package, app name).
    public var onOpenNotificationOnMac: ((String, String, String) -> Void)?

    public init(apkURL: URL?) {
        self.apkURL = apkURL
        let limit = defaults.object(forKey: "historyLimit") as? Int ?? 200
        history = ClipHistory.load(from: Paths.history, limit: limit)
        phoneName = defaults.string(forKey: "phoneName") ?? "Phone"
        mirrorNotifications = defaults.object(forKey: "mirrorNotifications") as? Bool ?? true
        textMessages = defaults.object(forKey: "textMessages") as? Bool ?? true
        // Set up = completed the pairing flow, which is the only place a phone (its serial and
        // its key) gets pinned. A setup from before key pinning has no key: it pairs once more.
        let paired = defaults.bool(forKey: "setupComplete") && defaults.string(forKey: "phoneSerial") != nil
            && Native.pinnedKey != nil
        state = paired ? .searching : .needsSetup
    }

    // MARK: Lifecycle

    public func start() {
        guard !started else { return }
        started = true
        pasteboard = PasteboardWatcher { [weak self] text in self?.macCopied(text) }
        pasteboard.start()

        link.onMessage = { [weak self] message in self?.handle(message) }
        messages.transport = { [weak self] message in
            guard let self, self.state == .connected, self.textMessages else { return }
            self.link.send(message)
        }
        notifications.onDismiss = { [weak self] key in
            guard !key.hasPrefix(Self.fileNotificationPrefix) else { return } // ours, not the phone's
            self?.link.send(["t": "notif-dismiss", "key": key])
        }
        notifications.onOpen = { [weak self] key in
            if key.hasPrefix(Self.fileNotificationPrefix) {
                let path = String(key.dropFirst(Self.fileNotificationPrefix.count))
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                return
            }
            self?.link.send(["t": "notif-open", "key": key])
        }
        notifications.onOpenOnMac = { [weak self] key, pkg, app in
            self?.onOpenNotificationOnMac?(key, pkg, app)
        }
        notifications.onAction = { [weak self] key, index, text in
            var message: [String: Any] = ["t": "notif-action", "key": key, "i": index]
            if let text { message["text"] = text }
            self?.link.send(message)
        }
        link.onDisconnect = { [weak self] in
            guard let self, state == .connected else { return }
            state = .searching
            appLinked = false
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
        if state == .connected, mirrorNotifications { notifications.reconcile() }
        // Only ever talk to the phone pinned during the user-run pairing flow; no discovery
        // of "whatever phone is around" (that would let a look-alike device be adopted).
        guard link.isIdle, !preparing, !isPairing, state == .searching || state == .connected,
              let pinned = pinnedSerial else { return }
        if inUseOn != nil { // another Mac has it: ask now and then whether it's free
            waitTicks += 1
            guard waitTicks % 5 == 0 else { return }
        }
        preparing = true
        Task {
            await updatePhoneAppIfNeeded(pinned: pinned)
            let phone = await Task.detached { Adb.prepareHelper(pinned: pinned) }.value
            preparing = false
            guard let phone else { return }
            adopt(phone)
            link.connect()
        }
    }

    /// The phone app bundled in this Mac app, by versionCode (Info.plist, from bundle.sh).
    private let bundledAppVersion = Bundle.main.object(forInfoDictionaryKey: "NearsidePhoneAppVersion") as? Int
    /// Checked once per launch (and never while another Mac has the phone: its helper would stop).
    private var checkedPhoneApp = false
    @ObservationIgnored private let log = Logger(subsystem: "dev.nearside.mac", category: "phone-app")
    /// The phone app couldn't be updated: shown in the panel until fixed.
    public private(set) var phoneAppProblem: PhoneAppProblem?
    public private(set) var reinstallingPhoneApp = false

    public enum PhoneAppProblem: Equatable {
        /// The installed app was signed with another key, so it must be replaced (`reinstallPhoneApp`).
        case otherSignature
        case failed(String)
    }

    private func updatePhoneAppIfNeeded(pinned: String) async {
        guard !checkedPhoneApp, inUseOn == nil, let apk = apkURL, let version = bundledAppVersion, version > 0 else { return }
        let outcome = await Task.detached(operation: { Adb.updateAppIfOutdated(pinned: pinned, apk: apk, version: version) }).value
        if outcome != .unknown { checkedPhoneApp = true }
        switch outcome {
        case .unknown: break
        case .upToDate: phoneAppProblem = nil
        case .updated:
            phoneAppProblem = nil
            log.info("updated the phone app to \(version)")
        case .otherSignature: phoneAppProblem = .otherSignature
        case .failed(let message):
            phoneAppProblem = .failed(Self.friendly(message))
            log.error("phone app update failed: \(message, privacy: .public)")
        }
    }

    /// Replaces a phone app signed with another key (after the user agreed in the panel).
    public func reinstallPhoneApp() {
        guard let pinned = pinnedSerial, let apk = apkURL, !reinstallingPhoneApp else { return }
        reinstallingPhoneApp = true
        link.disconnect()
        Task {
            let r = await Task.detached { Adb.reinstallApp(pinned: pinned, apk: apk) }.value
            reinstallingPhoneApp = false
            phoneAppProblem = r.ok ? nil : .failed(Self.friendly(r.out))
            tick()
        }
    }

    private func adopt(_ phone: Adb.Phone) {
        adbSerial = phone.serial
        if let model = phone.model {
            phoneName = model
            defaults.set(model, forKey: "phoneName")
        }
    }

    // MARK: Phone-app requests (see PhoneApps.swift)

    func nextDisplayRequestID() -> Int {
        defer { nextDisplayRequest += 1 }
        return nextDisplayRequest
    }

    func registerDisplayRequest(_ req: Int, _ continuation: CheckedContinuation<HelperReply?, Never>) {
        displayRequests[req] = continuation
    }

    func finishDisplayRequest(_ req: Int, with value: HelperReply?) {
        displayRequests.removeValue(forKey: req)?.resume(returning: value)
    }

    func sendToHelper(_ message: [String: Any]) { link.send(message) }

    // MARK: Messages

    private func handle(_ message: [String: Any]) {
        switch message["t"] as? String {
        case "hello":
            state = .connected
            inUseOn = nil // the phone is ours again
            applyNotificationAccess()
            if let serial = adbSerial {
                Task {
                    await Task.detached { Adb.grantPostNotifications(serial) }.value
                    clipboardToastHidden = await Task.detached { Adb.clipboardToastHidden(serial) }.value
                }
            }
            applySmsAccess()
        case "sms-threads", "sms-thread", "sms-sent", "sms-read", "sms-changed", "sms-error":
            messages.handle(message)
        case "file-ready":
            receiveFile(message)
        case "app":
            appLinked = message["linked"] as? Bool ?? false
        case "display-ticket", "display-apps", "display-icons", "display-layouts":
            if let req = message["req"] as? Int, let waiting = displayRequests.removeValue(forKey: req) {
                waiting.resume(returning: HelperReply(message))
            }
        case "apps-stop":
            onPhoneAppsStop?()
        case "busy", "taken-over":
            // Another Mac uses the phone now: wait (politely) instead of taking it back.
            inUseOn = (message["by"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "another Mac"
            NSLog("Nearside: phone in use on another Mac; waiting")
            link.passive = true
            link.disconnect()
            onPhoneAppsStop?()
        case "share-failed":
            if let pkg = message["pkg"] as? String { onShareFailed?(pkg, message["accepts"] as? Bool ?? false) }
        case "clip":
            guard state == .connected, let text = message["text"] as? String, !text.isEmpty else { return }
            pasteboard.write(text)
            let item = history.add(text, source: .android)
            unseenIDs.insert(item.id)
            persist()
            onArrival?(item)
        case "notif":
            guard mirrorNotifications, let key = message["key"] as? String else { return }
            notifications.show(key: key,
                               package: message["pkg"] as? String ?? "",
                               app: message["app"] as? String ?? "Phone",
                               title: message["title"] as? String ?? "",
                               text: message["text"] as? String ?? "",
                               iconPNG: (message["icon"] as? String).flatMap { Data(base64Encoded: $0) },
                               actions: (message["actions"] as? [[String: Any]] ?? []).compactMap { action in
                                   guard let title = action["title"] as? String else { return nil }
                                   return .init(title: title, isReply: action["reply"] as? Bool ?? false)
                               },
                               quiet: message["quiet"] as? Bool ?? false)
        case "notif-active":
            if mirrorNotifications, let keys = message["keys"] as? [String] { notifications.keepOnly(Set(keys)) }
        case "notif-removed":
            if let key = message["key"] as? String { notifications.remove(key: key) }
        default:
            break
        }
    }

    // MARK: Files

    private static let fileNotificationPrefix = "file:"

    /// Sends files to the phone's Download/Nearside folder, one after another.
    public func sendFiles(_ urls: [URL]) {
        guard state == .connected, let serial = adbSerial else { return }
        let jobs = urls.map { url in (url, Transfer(id: UUID(), name: url.lastPathComponent, direction: .toPhone, status: .inProgress)) }
        for (_, transfer) in jobs { addTransfer(transfer) }
        Task {
            for (url, transfer) in jobs {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                    setStatus(transfer.id, .failed("Folders can't be sent yet"))
                    continue
                }
                let result = await Task.detached { Adb.push(serial, file: url) }.value
                switch result {
                case .success(let name):
                    setStatus(transfer.id, .done(nil))
                    link.send(["t": "file-received", "name": name])
                case .failure(let error):
                    setStatus(transfer.id, .failed(Self.friendly(error.message)))
                }
            }
        }
    }

    /// Files dropped on a phone-app window: pushed (shown as transfers), then shared to the app in it.
    public func shareFiles(_ urls: [URL], into session: PhoneAppSession) {
        guard state == .connected, let serial = adbSerial else { return }
        let jobs = urls.map { url in (url, Transfer(id: UUID(), name: url.lastPathComponent, direction: .toPhone, status: .inProgress)) }
        for (_, transfer) in jobs { addTransfer(transfer) }
        Task {
            var names: [String] = []
            for (url, transfer) in jobs {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                    setStatus(transfer.id, .failed("Folders can't be sent yet"))
                    continue
                }
                switch await Task.detached(operation: { Adb.push(serial, file: url, to: Adb.appShareFolder) }).value {
                case .success(let name):
                    setStatus(transfer.id, .done(nil))
                    names.append(name)
                case .failure(let error):
                    setStatus(transfer.id, .failed(Self.friendly(error.message)))
                }
            }
            if !names.isEmpty { session.share(names) }
        }
    }

    /// The app in a window couldn't take dropped files: (package, whether it takes that kind at all).
    public var onShareFailed: ((String, Bool) -> Void)?

    /// The phone shared a file with us: pull it into ~/Downloads.
    private func receiveFile(_ message: [String: Any]) {
        guard let id = message["id"] as? String, let remote = message["path"] as? String,
              remote.hasPrefix("/data/local/tmp/nearside-out/"), let serial = adbSerial else { return }
        let name = FileNames.safe(message["name"] as? String ?? "file")
        let transfer = Transfer(id: UUID(), name: name, direction: .toMac, status: .inProgress)
        addTransfer(transfer)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = FileNames.unique(name, in: downloads)
        let phone = phoneName
        Task {
            let ok = await Task.detached { Adb.pull(serial, remote: remote, to: destination) }.value
            link.send(["t": "file-pulled", "id": id]) // the phone can delete its staged copy
            guard ok else {
                setStatus(transfer.id, .failed("Couldn't copy it from the phone."))
                return
            }
            Self.quarantine(destination)
            setStatus(transfer.id, .done(destination))
            notifications.showLocal(id: Self.fileNotificationPrefix + destination.path,
                                    title: "Received \(destination.lastPathComponent)",
                                    body: "From your \(phone) · in Downloads. Click to show it.")
        }
    }

    /// Marks a received file like a browser or AirDrop download, so Gatekeeper checks it
    /// before anything in it can run (any app on the phone could have sent it).
    nonisolated static func quarantine(_ url: URL) {
        let flags = "0083" // downloaded, Gatekeeper must check
        let value = "\(flags);\(String(Int(Date().timeIntervalSince1970), radix: 16));Nearside;\(UUID().uuidString)"
        _ = value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
    }

    public func dismissTransfer(_ id: UUID) {
        transfers.removeAll { $0.id == id }
    }

    private func addTransfer(_ transfer: Transfer) {
        transfers.insert(transfer, at: 0)
        if transfers.count > 20 { transfers.removeLast(transfers.count - 20) }
    }

    private func setStatus(_ id: UUID, _ status: Transfer.Status) {
        if let i = transfers.firstIndex(where: { $0.id == id }) { transfers[i].status = status }
    }

    /// Makes the phone app's SMS/contacts permissions match the setting (on every connect).
    private func applySmsAccess() {
        let allowed = textMessages
        guard state == .connected, let serial = adbSerial else { return }
        let open = messages.isOpen
        Task {
            await Task.detached { Adb.setSmsAccess(serial, allowed: allowed) }.value
            if allowed && open { messages.refresh() }
        }
    }

    /// Makes the phone's notification access match the setting (idempotent, so it's simply
    /// re-applied on every connect; that also covers phones set up before this feature).
    private func applyNotificationAccess() {
        let allowed = mirrorNotifications
        if allowed { notifications.activate() }
        guard state == .connected, let serial = adbSerial else { return }
        Task.detached { Adb.setNotificationAccess(serial, allowed: allowed) }
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

    /// Only ever changed by an explicit choice in the wizard or Settings.
    public func setClipboardToastHidden(_ hidden: Bool) {
        guard state == .connected, let serial = adbSerial else { return }
        Task {
            if await Task.detached(operation: { Adb.setClipboardToastHidden(serial, hidden) }).value {
                clipboardToastHidden = hidden
            }
        }
    }

    /// Forget the phone and show the setup flow again.
    public func resetSetup() {
        defaults.set(false, forKey: "setupComplete")
        pinnedSerial = nil
        Native.pinnedKey = nil
        link.disconnect()
        Task.detached { Native.disconnect() }
        setupSteps = []
        state = .needsSetup
    }

    private func persist() {
        defaults.set(history.limit, forKey: "historyLimit")
        try? history.save(to: Paths.history)
    }

    // MARK: Setup

    /// The QR code currently offered for "Pair device with QR code"; nil when not listening.
    public private(set) var qrPairing: QRPairing?
    private var qrTask: Task<Void, Never>?

    /// Shows a QR code and waits for the phone to scan it, then runs the full setup.
    /// A failed attempt gets a fresh code (each one works once). Runs until stopped or set up.
    public func startQRPairing() {
        guard qrTask == nil else { return }
        qrPairing = QRPairing.random()
        qrTask = Task {
            while !Task.isCancelled, state == .needsSetup {
                if !isPairing, let session = qrPairing,
                   let address = await Task.detached(operation: { Adb.pairingEndpoint(named: session.name) }).value,
                   !Task.isCancelled {
                    await runSetup(hostPort: address, code: session.password)
                    if state == .needsSetup { qrPairing = QRPairing.random() }
                }
                try? await Task.sleep(for: .seconds(1))
            }
            qrTask = nil
            qrPairing = nil
        }
    }

    public func stopQRPairing() {
        qrTask?.cancel()
        qrTask = nil
        qrPairing = nil
    }

    /// One-time setup from the phone's "Pair device with pairing code" screen.
    public func pair(hostPort: String, code: String) {
        guard !isPairing else { return }
        Task { await runSetup(hostPort: hostPort, code: code) }
    }

    private func runSetup(hostPort: String, code: String) async {
        guard !isPairing else { return }
        isPairing = true
        link.disconnect()
        // Forget the old pairing first, so a failed attempt can't leave a half-paired state.
        defaults.set(false, forKey: "setupComplete")
        pinnedSerial = nil
        Native.pinnedKey = nil
        await Task.detached { Native.disconnect() }.value
        let titles = [
            "Pair with your phone",
            "Connect over Wi-Fi",
            "Install Nearside on the phone",
            "Grant background permissions",
            "Start clipboard sync",
        ]
        setupSteps = titles.enumerated().map { SetupStep(id: $0.offset, title: $0.element, status: .pending) }
        let apkPath = apkURL?.path

        do {
            defer { isPairing = false }
            let run = runStep

            // Pairing tells us the phone's hardware serial; from here on only that phone is used.
            setupSteps[0].status = .running
            let host = hostPort.trimmingCharacters(in: .whitespaces)
            let pin = code.trimmingCharacters(in: .whitespaces)
            let phoneSerial: String
            let pairedHost: String
            switch await Task.detached(operation: { Adb.pair(hostPort: host, code: pin) }).value {
            case .success(let paired):
                phoneSerial = paired.serial
                pairedHost = paired.host
            case .failure(let error):
                setupSteps[0].status = .failed(error.message)
                return
            }
            setupSteps[0].status = .done
            pinnedSerial = phoneSerial

            guard await run(1, {
                // Pin the phone's connection key now, seconds after the code-checked pairing.
                switch Native.pinAfterPairing(serial: phoneSerial, at: pairedHost, wait: 20) {
                case .pinned: return nil
                case .conflict: return "More than one device on this network claims to be your phone. For your safety, nothing was trusted. Try again on a network you trust."
                case .notFound: return "Paired, but couldn't connect. Keep Wireless debugging open and try again."
                }
            }) else { return }

            guard await run(2, {
                guard let apkPath else { return "The app bundle is missing nearside.apk." }
                guard Adb.ensureConnected(pinned: phoneSerial) != nil else { return "Lost the connection to the phone." }
                let r = Adb.install(URL(fileURLWithPath: apkPath))
                return r.ok ? nil : Self.friendly(r.out)
            }) else { return }

            guard await run(3, {
                guard let serial = Adb.ensureConnected(pinned: phoneSerial) else { return "Lost the connection to the phone." }
                Adb.grantBackground(serial)
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
