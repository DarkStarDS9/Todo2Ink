import Foundation

/// A fixed-size, in-memory event log for the link and the sync state machine.
///
/// Not `os_log`: this needs to be readable off a user's own phone after they hit a bug in the
/// field, without a Mac, a cable or Console.app. It ships in Release, not just DEBUG builds — the
/// symptoms this exists to catch (a silent stuck reconnect, a sync that never resolves) show up on
/// TestFlight, not in the simulator.
///
/// A ring buffer rather than a growing array on purpose: this runs for the whole app lifetime, and
/// nobody is ever going to want more than the last few hundred lines to explain what just happened.
final class DebugLog: @unchecked Sendable {
    static let shared = DebugLog()

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String

        var formatted: String {
            "\(Self.formatter.string(from: timestamp))  \(message)"
        }

        private static let formatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return formatter
        }()
    }

    private let capacity = 500
    private let lock = NSLock()
    private var buffer: [Entry] = []

    private init() {}

    func log(_ message: String) {
        let entry = Entry(timestamp: Date(), message: message)
        lock.lock()
        buffer.append(entry)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        lock.unlock()
    }

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    var formattedText: String {
        entries.map(\.formatted).joined(separator: "\n")
    }
}
