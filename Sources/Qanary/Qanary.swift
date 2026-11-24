import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The Qanary SDK: goes inside the app being tested.
///
///     // SwiftUI
///     @main struct MyApp: App {
///         init() { Qanary.start() }
///         var body: some Scene { WindowGroup { ContentView().onOpenURL { Qanary.handle($0) } } }
///     }
///
///     // UIKit
///     func application(_ app: UIApplication, didFinishLaunchingWithOptions …) -> Bool { Qanary.start(); return true }
///     func application(_ app: UIApplication, open url: URL, options: …) -> Bool { Qanary.handle(url) }
///     // with scenes: scene(_:openURLContexts:) and scene(_:willConnectTo:options:) → Qanary.handle(contexts)
///
/// DORMANT by default: it records nothing unless the app was opened from the Qanary app with a session link
/// (`<your scheme>://qanary?session=…`). Real users of the app are never recorded. A session stops for good when the
/// server says it's over (the report is in, the test closed or the claim expired), after 15 days at most, or on `stop()`.
///
/// Privacy (also enforced by the server): never the text of a field, only counts; screen names are view controller
/// class names or names passed to `screen(_:)`; no screenshots, no identifiers, no location.
public enum Qanary {
    /// Sent with every batch. The API tells an iPhone build from an Android one by the "ios-" prefix.
    public static let sdkVersion = "ios-0.1.0"
    public static let defaultEndpoint = URL(string: "https://api.qanaries.com")!
    /// Covers the longest test; a session older than this stops recording.
    static let sessionTTL: TimeInterval = 15 * 24 * 3600

    /// Log what the SDK does (session started, batches sent, session over) via os_log, subsystem com.qanaries.sdk.
    /// Off by default. Session tokens are never logged.
    public static var debug: Bool {
        get { Log.enabled }
        set { Log.enabled = newValue }
    }

    /// True while a session from Qanary is recording.
    public static var isRecording: Bool { Core.shared.recording.get }

    /// Call once at launch (App init, or application(_:didFinishLaunchingWithOptions:)). Resumes a session that was
    /// opened from Qanary on an earlier launch; otherwise stays dormant. `endpoint` must be https (plain http is allowed
    /// only to localhost, for testing against a local API).
    public static func start(endpoint: URL = defaultEndpoint) {
        Core.shared.start(endpoint: endpoint, foreground: AppState.isForeground, device: DeviceInfo.collect())
        #if canImport(UIKit)
        AppState.observe()
        #endif
    }

    /// Give every URL the app is opened with to this. Returns true when it was a Qanary session link and the SDK took
    /// its token (then there's nothing else for the app to do with it); false for any other URL.
    @discardableResult
    public static func handle(_ url: URL) -> Bool {
        guard let token = SessionLink.token(in: url) else { return false }
        Core.shared.take(token, foreground: AppState.isForeground)
        return true
    }

    #if canImport(UIKit)
    /// For scene-based UIKit apps: `scene(_:openURLContexts:)`, and `connectionOptions.urlContexts` in
    /// `scene(_:willConnectTo:options:)` (a cold launch from a link doesn't call openURLContexts).
    @available(iOS 13.0, *)
    @discardableResult
    public static func handle(_ urlContexts: Set<UIOpenURLContext>) -> Bool {
        urlContexts.reduce(false) { handle($1.url) || $0 }
    }
    #endif

    /// Name the screen now in front, for apps whose screens aren't view controllers (SwiftUI: or use
    /// `.qanaryScreen("Name")`). UIKit view controllers are named automatically.
    public static func screen(_ name: String) {
        Core.shared.screen(name, t: Clock.ms())
    }

    /// For text fields the SDK can't see (custom or drawn fields): how a field went when it loses focus. Counts only,
    /// never the text. `edits` = changes typed, `clears` = times it was emptied after having text.
    /// UITextField and UITextView (and SwiftUI's TextField) are counted automatically.
    public static func field(_ name: String, edits: Int, clears: Int = 0) {
        guard edits > 0 else { return }
        Core.shared.event("field_edit", t: Clock.ms(), data: ["field": .string(name), "edits": .int(edits), "clears": .int(max(0, clears))])
    }

    /// A field the person typed in, then left empty: the form was abandoned at this field.
    public static func fieldAbandoned(_ name: String) {
        Core.shared.event("field_abandon", t: Clock.ms(), data: ["field": .string(name)])
    }

    /// A network request failed: an HTTP status (500 and up), or 0 when there was no response. Only the status is
    /// sent, never the URL or the body.
    public static func requestFailed(_ status: Int) {
        Core.shared.event("error", t: Clock.ms(), data: ["kind": "network", "status": .int(status)])
    }

    /// Optional: mark a test task from inside the app (`state` e.g. "started", "done"), so the report can show it.
    public static func task(_ id: String, _ state: String) {
        Core.shared.event("task_marker", t: Clock.ms(), screen: false, data: ["taskId": .string(String(id.prefix(48))), "state": .string(String(state.prefix(24)))])
    }

    /// End the session on this device now: what's queued is sent, then the SDK forgets the session and stays dormant
    /// until it's opened from Qanary again.
    public static func stop() {
        Core.shared.stop(t: Clock.ms())
    }
}

/// The SDK's state. Everything runs on one serial queue; the public API only enqueues work, so it never blocks the app.
final class Core {
    static let shared = Core(store: Store(dir: Store.appDefault()))

    final class StateBox {
        var state: Store.SessionState
        init(_ s: Store.SessionState) { state = s }
    }

    final class Session {
        let token: String
        let queue: EventQueue
        let box: StateBox
        var state: Store.SessionState { box.state }
        init(token: String, queue: EventQueue, box: StateBox) { self.token = token; self.queue = queue; self.box = box }
    }

    let queue = DispatchQueue(label: "com.qanaries.sdk")
    let recording = Locked(false)
    let inForeground = Locked(true)
    private let store: Store
    /// Builds the transport for a session (tests swap in a fake).
    var makeTransport: (URL) -> Transport = { URLSessionTransport(endpoint: $0) }
    private var started = false
    private var endpoint = Qanary.defaultEndpoint
    private var device: [String: Event.Value] = [:]
    private var session: Session?
    private var pendingToken: String?
    private var currentScreen: String?
    private var fieldScreens: [String: String] = [:]
    private var timer: DispatchSourceTimer?
    static let tick: TimeInterval = 10

    init(store: Store) { self.store = store }

    // MARK: lifecycle

    func start(endpoint: URL, foreground: Bool, device: [String: Event.Value]) {
        Clock.touch()
        queue.async { [self] in
            guard !started else { return Log.d("start() was already called") }
            guard Core.endpointAllowed(endpoint) else {
                return Log.error("Qanary: the endpoint must be https (http only to localhost); the SDK stays off")
            }
            started = true
            self.endpoint = endpoint
            self.device = device
            inForeground.set(foreground)
            store.prepare()
            let crash = CrashCapture.takePending(store.crashFile)
            if let s = store.load() {
                if Clock.wallMs() - s.since > Qanary.sessionTTL * 1000 {
                    Log.d("session is over 15 days old; recording stopped")
                    store.clearState(ifToken: s.token)
                } else {
                    begin(s.token, fresh: false, saved: s)
                }
            }
            store.removeEventFiles(except: session.map { store.eventsFile(for: $0.token) })
            if let crash, let s = session {
                s.queue.add("error", t: Clock.ms(), screen: crash.screen, data: ["kind": "crash", "signature": .string(crash.signature), "source": .string(crash.source)])
                Log.d("reported a crash from the last launch")
            }
            if let t = pendingToken { pendingToken = nil; begin(t, fresh: true, saved: nil) }
            session?.queue.flush()
        }
    }

    static func endpointAllowed(_ u: URL) -> Bool {
        let scheme = u.scheme?.lowercased()
        if scheme == "https" { return u.host != nil }
        return scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(u.host?.lowercased() ?? "")
    }

    func take(_ token: String, foreground: Bool) {
        queue.async { [self] in
            inForeground.set(foreground)
            guard started else {
                pendingToken = token
                return Log.d("session link received before Qanary.start(); it starts when start() is called")
            }
            begin(token, fresh: true, saved: nil)
            session?.queue.flush()
        }
    }

    /// On the queue. A fresh session came from a link just now; otherwise it was saved by an earlier launch.
    private func begin(_ token: String, fresh: Bool, saved: Store.SessionState?) {
        if session?.token == token { return Log.d("same session link again; still recording") }
        if let old = session {
            // A new test (or a check) replaced the old one: the old queue sends what it has, then stops.
            Log.d("a new session replaced the previous one")
            old.queue.finish()
        }
        var state = saved ?? Store.SessionState(token: token, since: Clock.wallMs(), seqNext: 0)
        if fresh, let s = store.load(), s.token == token { state = s }   // the same link opened in a new process
        store.save(state)
        // The queue's sequence reservations are saved before the numbers are used.
        let box = StateBox(state)
        let q = EventQueue(token: token, file: store.eventsFile(for: token), startSeq: state.seqNext, transport: makeTransport(endpoint), queue: queue) { [weak self] next in
            box.state.seqNext = next
            self?.store.save(box.state)
        }
        q.onFinished = { [weak self] in self?.end(token, why: "server") }
        session = Session(token: token, queue: q, box: box)
        recording.set(true)
        // Every launch starts with session_start: the clock restarts at 0 in each process, and the server times
        // launches separately.
        var data = device
        data["resumed"] = .bool(!fresh)
        q.add("session_start", t: Clock.ms(), data: data)
        if !inForeground.get { q.add("background", t: Clock.ms()) }
        if let name = currentScreen { q.add("screen_view", t: Clock.ms(), screen: name) }
        CrashCapture.arm(store.crashFile, screen: currentScreen)
        Watchdog.shared.start()
        startTimer()
        #if canImport(UIKit)
        DispatchQueue.main.async { Hooks.installOnce() }
        #endif
        let kind = SessionLink.isCheck(token) ? "check session (reports to the developer's verify page)" : "tester session"
        Log.d(fresh ? "\(kind) started from a Qanary link" : "\(kind) resumed")
    }

    /// On the queue: the session is over for good.
    private func end(_ token: String, why: String) {
        guard let s = session, s.token == token else { return }
        s.queue.shutdown(deleteFile: true)
        forget(s)
        Log.d("session finished (\(why)); recording stopped")
    }

    func stop(t: Int) {
        queue.async { [self] in
            guard let s = session else { return }
            s.queue.add("session_end", t: t)
            s.queue.finish()
            forget(s)
            Log.d("stop() called; recording stopped")
        }
    }

    /// Nothing of the session stays: no state, no crash file, no timers, no watchdog.
    private func forget(_ s: Session) {
        session = nil
        recording.set(false)
        store.clearState(ifToken: s.token)
        CrashCapture.disarm()
        try? FileManager.default.removeItem(at: store.crashFile)
        Watchdog.shared.stop()
        timer?.cancel()
        timer = nil
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Core.tick, repeating: Core.tick, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.tickNow() }
        t.resume()
        timer = t
    }

    /// Every ~10 s: a heartbeat while the app is in front (time behind other apps isn't use), then send.
    func tickNow() {
        guard let s = session else { return }
        if Clock.wallMs() - s.state.since > Qanary.sessionTTL * 1000 { return end(s.token, why: "15 days") }
        if inForeground.get { s.queue.add("heartbeat", t: Clock.ms()) }
        s.queue.flush()
    }

    // MARK: app state (from the main thread)

    func didEnterBackground(t: Int, done: @escaping () -> Void) {
        queue.async { [self] in
            inForeground.set(false)
            guard let s = session else { return done() }
            s.queue.add("background", t: t)
            s.queue.flush { _ in done() }
        }
    }

    func willEnterForeground(t: Int) {
        queue.async { [self] in
            inForeground.set(true)
            guard let s = session else { return }
            s.queue.add("foreground", t: t)
            s.queue.flush()
        }
    }

    // MARK: events

    func screen(_ name: String, t: Int) {
        let name = String(name.prefix(Event.maxScreen))
        queue.async { [self] in
            guard name != currentScreen else { return }
            currentScreen = name
            CrashCapture.setScreen(name)
            session?.queue.add("screen_view", t: t, screen: name)
        }
    }

    /// An event on the current screen (or none, with `screen: false`). A field's events stay on the screen it was
    /// focused on: UIKit ends editing only after the next screen has appeared.
    func event(_ type: String, t: Int, screen: Bool = true, data: [String: Event.Value]) {
        queue.async { [self] in
            var on = screen ? currentScreen : nil
            if case .string(let field)? = data["field"] {
                if type == "field_focus" {
                    if fieldScreens.count > 50 { fieldScreens.removeAll() }
                    fieldScreens[field] = currentScreen
                } else if let s = fieldScreens[field] {
                    on = s
                }
            }
            session?.queue.add(type, t: t, screen: on, data: data)
        }
    }

    // MARK: test support

    /// Runs `block` on the SDK's queue and waits (tests only).
    func sync<T>(_ block: () -> T) -> T { queue.sync(execute: block) }
    var currentQueue: EventQueue? { session?.queue }
    func takePendingTokenForTests() -> String? { defer { pendingToken = nil }; return pendingToken }
    /// Tests only, on a Core made with a temporary store: forget everything, files included.
    func resetForTests() {
        queue.sync {
            if let s = session { s.queue.shutdown(deleteFile: true) }
            session = nil
            started = false
            pendingToken = nil
            currentScreen = nil
            recording.set(false)
            timer?.cancel()
            timer = nil
            Watchdog.shared.stop()
            CrashCapture.disarm()
            try? FileManager.default.removeItem(at: store.dir)
        }
    }
}
