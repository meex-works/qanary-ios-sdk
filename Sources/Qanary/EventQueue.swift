import Foundation

/// Sends one batch to the API. The status, or nil when there was no answer (offline, timeout).
protocol Transport {
    func post(_ body: Data, completion: @escaping (Int?) -> Void)
}

/// POST <endpoint>/v1/sdk/events over an ephemeral URLSession (no cookies, no cache).
final class URLSessionTransport: Transport {
    let url: URL
    private let session: URLSession

    init(endpoint: URL) {
        url = endpoint.appendingPathComponent("v1/sdk/events")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 20
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        session = URLSession(configuration: cfg)
    }

    func post(_ body: Data, completion: @escaping (Int?) -> Void) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("qanary-sdk/\(Qanary.sdkVersion)", forHTTPHeaderField: "user-agent")
        session.dataTask(with: req) { _, resp, _ in completion((resp as? HTTPURLResponse)?.statusCode) }.resume()
    }
}

/// One session's events: kept in memory and in a small file (one JSON event per line) so a crash or a kill loses
/// nothing, sent in batches of up to 500. Not thread-safe: every call happens on `queue` (the SDK's own serial queue).
final class EventQueue {
    enum Outcome: Equatable { case sent, refused(Int), retry, finished, idle }

    static let maxBatch = 500
    static let maxPending = 5000
    /// Sequence numbers are reserved in blocks and the reservation saved first, so a crash can never make a later
    /// launch reuse a number (the API keeps the first event with a given seq and ignores the rest).
    static let seqBlock = 50

    let token: String
    let file: URL
    private let queue: DispatchQueue
    private let transport: Transport
    private let reserve: (Int) -> Void
    private let encoder = JSONEncoder()
    private var pending: [Event] = []
    private var seq: Int
    private var reservedUpTo: Int
    private var sending = false
    private var waiters: [(Outcome) -> Void] = []
    private var closing = false
    private(set) var stopped = false
    /// The server said this session is over (410, or 404: no such session).
    var onFinished: (() -> Void)?

    init(token: String, file: URL, startSeq: Int, transport: Transport, queue: DispatchQueue, reserve: @escaping (Int) -> Void) {
        self.token = token
        self.file = file
        self.transport = transport
        self.queue = queue
        self.reserve = reserve
        seq = startSeq
        reservedUpTo = startSeq
        // Events left from the last run (a crash, a kill, no connection) go out first.
        if let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder()
            pending = data.split(separator: 0x0A).compactMap { try? decoder.decode(Event.self, from: Data($0)) }
        }
    }

    var count: Int { pending.count }
    var events: [Event] { pending }
    var nextSeq: Int { seq }

    @discardableResult
    func add(_ type: String, t: Int, screen: String? = nil, data: [String: Event.Value]? = nil) -> Event? {
        guard !stopped, !closing, Event.types.contains(type) else { return nil }
        var d = data ?? [:]
        if type.hasPrefix("field_") {
            // Counts only: a field event names its field and never carries what was typed (the API refuses it too).
            guard case .string(let name)? = d["field"] else { return nil }
            d["field"] = .string(String(name.prefix(Event.maxField)))
            for k in Event.forbiddenFieldKeys { d.removeValue(forKey: k) }
        }
        if seq >= reservedUpTo {
            reservedUpTo = seq + EventQueue.seqBlock
            reserve(reservedUpTo)
        }
        let e = Event(seq: seq, t: max(0, t), type: type, screen: screen.map { String($0.prefix(Event.maxScreen)) }, data: d.isEmpty ? nil : d)
        seq += 1
        pending.append(e)
        if pending.count > EventQueue.maxPending {
            pending.removeFirst(pending.count - EventQueue.maxPending)
            rewrite()
        } else {
            append(e)
        }
        return e
    }

    /// Sends what's waiting, batch after batch. `completion` gets the last outcome.
    func flush(_ completion: ((Outcome) -> Void)? = nil) {
        if let completion { waiters.append(completion) }
        guard !sending else { return }   // the batch in flight calls the waiters when it's done
        guard !stopped else { return notify(.finished) }
        guard !pending.isEmpty else { return notify(.idle) }
        let batch = Array(pending.prefix(EventQueue.maxBatch))
        guard let body = try? encoder.encode(Batch(sessionToken: token, sdkVersion: Qanary.sdkVersion, events: batch)) else {
            pending.removeFirst(batch.count)
            rewrite()
            return notify(.refused(0))
        }
        sending = true
        transport.post(body) { [weak self] status in
            guard let self else { return }
            self.queue.async { self.sent(batch.count, status: status) }
        }
    }

    /// Stop for good: nothing more is added or sent.
    func shutdown(deleteFile: Bool) {
        stopped = true
        pending.removeAll()
        if deleteFile { try? FileManager.default.removeItem(at: file) }
        notify(.finished)
    }

    /// Send what's left once, then shut down (a new session replaced this one, or the app called stop()).
    func finish(_ completion: (() -> Void)? = nil) {
        closing = true
        flush { [weak self] _ in
            self?.shutdown(deleteFile: true)
            completion?()
        }
    }

    private func sent(_ n: Int, status: Int?) {
        sending = false
        guard !stopped else { return notify(.finished) }
        switch status {
        case 410?, 404?:
            Log.d("server: session finished (\(status!)); recording stopped")
            shutdown(deleteFile: true)
            onFinished?()
        case let s? where (200..<500).contains(s):
            // Delivered, or refused for good (a malformed batch): either way it's done with.
            Log.d(s < 300 ? "sent \(n) events" : "batch refused (\(s))")
            pending.removeFirst(min(n, pending.count))
            rewrite()
            if !pending.isEmpty { return flush() }
            notify(s < 300 ? .sent : .refused(s))
        default:
            Log.d("send failed (\(status.map(String.init) ?? "no answer")); will retry")
            notify(.retry)
        }
    }

    private func notify(_ o: Outcome) {
        let ws = waiters
        waiters = []
        ws.forEach { $0(o) }
    }

    // MARK: the file

    private func append(_ e: Event) {
        guard var line = try? encoder.encode(e) else { return }
        line.append(0x0A)
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        line.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    private func rewrite() {
        guard !pending.isEmpty else { try? FileManager.default.removeItem(at: file); return }
        var out = Data()
        for e in pending { if let line = try? encoder.encode(e) { out.append(line); out.append(0x0A) } }
        try? out.write(to: file, options: .atomic)
    }

    private struct Batch: Encodable {
        let sessionToken: String
        let sdkVersion: String
        let events: [Event]
    }
}
