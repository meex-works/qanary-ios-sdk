import Foundation
import os.log

/// Where the SDK keeps its few files: Application Support/com.qanaries.sdk, excluded from backups.
/// state.json (the session token, when it started, the reserved sequence number), one events file per session,
/// and crash.log (written by the crash handlers, read on the next launch). No UserDefaults.
final class Store {
    struct SessionState: Codable, Equatable {
        var token: String
        /// Wall-clock milliseconds when the session was opened from Qanary (the 15-day limit counts from here).
        var since: Double
        var seqNext: Int
    }

    let dir: URL

    init(dir: URL) { self.dir = dir }

    static func appDefault() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("com.qanaries.sdk", isDirectory: true)
    }

    var stateFile: URL { dir.appendingPathComponent("state.json") }
    var crashFile: URL { dir.appendingPathComponent("crash.log") }

    func eventsFile(for token: String) -> URL {
        let safe = String(token.suffix(16).filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        return dir.appendingPathComponent("events-\(safe).jsonl")
    }

    func prepare() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    func load() -> SessionState? {
        guard let d = try? Data(contentsOf: stateFile) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: d)
    }

    func save(_ s: SessionState) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: stateFile, options: .atomic)
    }

    /// The session ended: its state goes (only if it's still the saved one).
    func clearState(ifToken token: String) {
        if load()?.token == token { try? FileManager.default.removeItem(at: stateFile) }
    }

    /// Event files from sessions that are no longer current (e.g. the app died while one session replaced another).
    func removeEventFiles(except keep: URL?) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for n in names where n.hasPrefix("events-") && n != keep?.lastPathComponent {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
        }
    }
}

/// The clock events carry: milliseconds since this launch, from the monotonic system uptime (never the wall clock,
/// which the person can change). Declared in the privacy manifest: system boot time, reason 35F9.1.
enum Clock {
    private static let launch = ProcessInfo.processInfo.systemUptime
    static func touch() { _ = launch }
    static func ms() -> Int { max(0, Int((ProcessInfo.processInfo.systemUptime - launch) * 1000)) }
    static func wallMs() -> Double { Date().timeIntervalSince1970 * 1000 }
}

/// Debug logging (`Qanary.debug = true`): os_log, subsystem com.qanaries.sdk. Never logs a session token.
enum Log {
    private static let lock = NSLock()
    private static var _enabled = false
    static var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; lock.unlock() }
    }
    static let log = OSLog(subsystem: "com.qanaries.sdk", category: "sdk")

    static func d(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        os_log("%{public}@", log: log, type: .default, message())
    }

    /// Misuse the developer must see even with debug off (e.g. a non-https endpoint).
    static func error(_ message: String) {
        os_log("%{public}@", log: log, type: .error, message)
    }
}

/// A Bool or a small value shared between the SDK's queue and the main thread.
final class Locked<T> {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    var get: T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
}
