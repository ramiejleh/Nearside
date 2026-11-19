import Foundation
import Observation

/// SMS conversations for the Messages window, fetched from the phone on demand (nothing is
/// stored on the Mac). See SmsBridge.kt for the phone side of the protocol.
@MainActor
@Observable
public final class MessagesStore {
    public struct Thread: Identifiable, Equatable, Sendable {
        public let id: Int64
        public let address: String
        public let name: String?
        public let snippet: String
        public let date: Date
        public let outgoing: Bool
        public let unread: Int
        public var title: String { name ?? address }
    }

    public struct Message: Identifiable, Equatable, Sendable {
        public let id: Int64
        public let body: String
        public let date: Date
        public let outgoing: Bool
        public let failed: Bool
        public let pending: Bool
    }

    public private(set) var threads: [Thread] = []
    public private(set) var messages: [Int64: [Message]] = [:]
    public private(set) var loaded = false
    /// Why there's nothing to show (no permission, phone error), if so.
    public private(set) var problem: String?
    public private(set) var sendError: String?

    /// The conversation shown on the right; loading it fetches its messages.
    public var selected: Int64? {
        didSet { if let selected, selected != oldValue { loadThread(selected) } }
    }

    /// True while the window is open: only then do phone-side changes trigger a refresh.
    public var isOpen = false {
        didSet { if isOpen && !oldValue { refresh() } }
    }

    var transport: (([String: Any]) -> Void)?
    private var nextRequest = 0
    /// Number we just texted from "New Message", to select its conversation once it appears.
    private var pendingAddress: String?

    public func refresh() {
        request(["t": "sms-threads"])
        if let selected { loadThread(selected) }
    }

    public func send(_ text: String, to address: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !address.isEmpty else { return }
        sendError = nil
        // Show it straight away; the phone's "changed" signal then brings the real one.
        if let thread = selected, threads.first(where: { $0.id == thread })?.address == address {
            messages[thread, default: []].append(Message(id: -Int64(nextRequest + 1), body: text, date: Date(),
                                                         outgoing: true, failed: false, pending: true))
        } else {
            pendingAddress = address
        }
        request(["t": "sms-send", "address": address, "text": text])
    }

    func reset() {
        threads = []
        messages = [:]
        loaded = false
        problem = nil
        selected = nil
    }

    private func loadThread(_ thread: Int64) {
        request(["t": "sms-thread", "thread": thread])
    }

    private func request(_ message: [String: Any]) {
        nextRequest += 1
        var message = message
        message["req"] = nextRequest
        transport?(message)
    }

    func handle(_ message: [String: Any]) {
        switch message["t"] as? String {
        case "sms-threads":
            threads = (message["threads"] as? [[String: Any]] ?? []).compactMap(Self.thread)
            loaded = true
            problem = nil
            if let address = pendingAddress,
               let match = threads.first(where: { Self.sameNumber($0.address, address) }) {
                pendingAddress = nil
                selected = match.id
            }
        case "sms-thread":
            guard let thread = (message["thread"] as? NSNumber)?.int64Value else { return }
            messages[thread] = (message["messages"] as? [[String: Any]] ?? []).compactMap(Self.message)
        case "sms-sent":
            if message["ok"] as? Bool != true {
                sendError = message["error"] as? String == "permission"
                    ? "Nearside isn't allowed to send texts. Turn on Text messages in Settings."
                    : "The phone couldn't send it."
                if let selected { loadThread(selected) } // drop the optimistic bubble
            }
        case "sms-changed":
            if isOpen { refresh() }
        case "sms-error":
            loaded = true
            problem = message["reason"] as? String == "permission"
                ? "Nearside isn't allowed to read texts on your phone. Turn on Text messages in Settings."
                : "The phone couldn't load your texts."
        default:
            break
        }
    }

    nonisolated static func thread(_ json: [String: Any]) -> Thread? {
        guard let id = (json["thread"] as? NSNumber)?.int64Value else { return nil }
        return Thread(id: id,
                      address: json["address"] as? String ?? "",
                      name: (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                      snippet: json["snippet"] as? String ?? "",
                      date: Date(timeIntervalSince1970: ((json["date"] as? NSNumber)?.doubleValue ?? 0) / 1000),
                      outgoing: json["out"] as? Bool ?? false,
                      unread: (json["unread"] as? NSNumber)?.intValue ?? 0)
    }

    nonisolated static func message(_ json: [String: Any]) -> Message? {
        guard let id = (json["id"] as? NSNumber)?.int64Value else { return nil }
        return Message(id: id,
                       body: json["body"] as? String ?? "",
                       date: Date(timeIntervalSince1970: ((json["date"] as? NSNumber)?.doubleValue ?? 0) / 1000),
                       outgoing: json["out"] as? Bool ?? false,
                       failed: json["failed"] as? Bool ?? false,
                       pending: json["pending"] as? Bool ?? false)
    }

    /// "+45 12 34 56 78" and "12345678" are the same number (compares the last 8 digits).
    nonisolated public static func sameNumber(_ a: String, _ b: String) -> Bool {
        let da = a.filter(\.isNumber), db = b.filter(\.isNumber)
        guard !da.isEmpty, !db.isEmpty else { return a == b }
        return da.suffix(8) == db.suffix(8)
    }
}
