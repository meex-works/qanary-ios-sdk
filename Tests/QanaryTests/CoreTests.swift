import XCTest
@testable import Qanary

/// The session lifecycle on a Core with its own temporary store: dormant until a link, resume on the next launch,
/// stop on 410, the 15-day limit, and last launch's crash.
final class CoreTests: XCTestCase {
    var dir: URL!
    let token = "qs_" + String(repeating: "k", count: 43)
    let endpoint = URL(string: "http://localhost:8820")!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("qanary-core-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func core(_ t: FakeTransport) -> Core {
        let c = Core(store: Store(dir: dir))
        c.makeTransport = { _ in t }
        return c
    }

    private func settle(_ c: Core, _ seconds: TimeInterval = 0.3) {
        // Let posts answer and their results land back on the SDK's queue.
        let e = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { c.queue.async { e.fulfill() } }
        wait(for: [e], timeout: seconds + 5)
    }

    private func sentTypes(_ t: FakeTransport) -> [String] {
        (0..<t.posts).flatMap { t.events($0).compactMap { $0["type"] as? String } }
    }

    func testDormantUntilOpenedFromQanary() {
        let t = FakeTransport()
        let c = core(t)
        c.start(endpoint: endpoint, foreground: true, device: ["device": "iPhone16,1", "os": "ios"])
        c.event("error", t: 1, data: ["kind": "network", "status": 500])
        c.screen("Home", t: 2)
        settle(c)
        XCTAssertFalse(c.recording.get)
        XCTAssertEqual(t.posts, 0, "nothing is sent without a session")
        XCTAssertNil(Store(dir: dir).load())
        c.resetForTests()
    }

    func testALinkStartsASessionAndTheNextLaunchResumesIt() {
        let t = FakeTransport()
        let c = core(t)
        c.start(endpoint: endpoint, foreground: true, device: ["device": "iPhone16,1", "os": "ios", "osVersion": "26.5", "appVersion": "1.0", "sdkVersion": "ios-0.1.0"])
        c.screen("Home", t: 5)
        c.take(token, foreground: true)
        c.take(token, foreground: true)   // the same link again: still one session
        settle(c)
        XCTAssertTrue(c.recording.get)
        XCTAssertEqual(sentTypes(t), ["session_start", "screen_view"], "the screen already in front is named at once")
        let start = (t.events(0)[0]["data"] as? [String: Any]) ?? [:]
        XCTAssertEqual(start["os"] as? String, "ios")
        XCTAssertEqual(start["device"] as? String, "iPhone16,1")
        XCTAssertEqual(start["resumed"] as? Bool, false)
        XCTAssertEqual(Store(dir: dir).load()?.token, token)

        // The next launch: same session, resumed, and the sequence carries on above every number used.
        let used = t.events(0).compactMap { $0["seq"] as? Int }.max()!
        let t2 = FakeTransport()
        let c2 = core(t2)
        c2.start(endpoint: endpoint, foreground: true, device: ["os": "ios"])
        settle(c2)
        XCTAssertTrue(c2.recording.get)
        let first = t2.events(0)[0]
        XCTAssertEqual(first["type"] as? String, "session_start")
        XCTAssertEqual((first["data"] as? [String: Any])?["resumed"] as? Bool, true)
        XCTAssertGreaterThan(first["seq"] as! Int, used)
        c.resetForTests()
        c2.resetForTests()
    }

    func testHeartbeatsOnlyInFront() {
        let t = FakeTransport()
        let c = core(t)
        c.start(endpoint: endpoint, foreground: true, device: [:])
        c.take(token, foreground: true)
        settle(c)
        c.sync { c.tickNow() }
        c.didEnterBackground(t: 100) {}
        settle(c)
        c.sync { c.tickNow() }   // behind other apps: no heartbeat
        c.willEnterForeground(t: 200)
        settle(c)
        c.sync { c.tickNow() }
        settle(c)
        XCTAssertEqual(sentTypes(t), ["session_start", "heartbeat", "background", "foreground", "heartbeat"])
        c.resetForTests()
    }

    func testTheServerEndsIt() {
        let t = FakeTransport([200, 410])
        let c = core(t)
        c.start(endpoint: endpoint, foreground: true, device: [:])
        c.take(token, foreground: true)
        settle(c)
        c.sync { c.tickNow() }
        settle(c)
        XCTAssertFalse(c.recording.get)
        XCTAssertNil(Store(dir: dir).load(), "a finished session isn't resumed")
        c.screen("After", t: 1)
        c.sync { c.tickNow() }
        settle(c)
        XCTAssertEqual(t.posts, 2)
        c.resetForTests()
    }

    func testStopsAfterFifteenDays() {
        let s = Store(dir: dir)
        s.prepare()
        s.save(.init(token: token, since: Clock.wallMs() - 16 * 86_400_000, seqNext: 10))
        let t = FakeTransport()
        let c = core(t)
        c.start(endpoint: endpoint, foreground: true, device: [:])
        settle(c)
        XCTAssertFalse(c.recording.get)
        XCTAssertNil(s.load())
        XCTAssertEqual(t.posts, 0)
        c.resetForTests()
    }

    func testReportsLastLaunchsCrash() {
        let s = Store(dir: dir)
        s.prepare()
        s.save(.init(token: token, since: Clock.wallMs(), seqNext: 40))
        try! "v1\nsignal\nSIGSEGV\nCartViewController\n".write(to: s.crashFile, atomically: true, encoding: .utf8)
        let t = FakeTransport()
        let c = core(t)
        c.start(endpoint: endpoint, foreground: true, device: [:])
        settle(c)
        let ev = t.events(0)
        XCTAssertEqual(ev.map { $0["type"] as? String }, ["session_start", "error"])
        let data = ev[1]["data"] as? [String: Any]
        XCTAssertEqual(data?["kind"] as? String, "crash")
        XCTAssertEqual(data?["signature"] as? String, "SIGSEGV")
        XCTAssertEqual(ev[1]["screen"] as? String, "CartViewController", "the crash lands on the screen it happened on")
        XCTAssertEqual(ev[0]["seq"] as? Int, 40)
        c.resetForTests()
    }

    func testStopSendsSessionEndAndForgets() {
        let t = FakeTransport()
        let c = core(t)
        c.start(endpoint: endpoint, foreground: true, device: [:])
        c.take(token, foreground: true)
        settle(c)
        c.stop(t: 99)
        settle(c)
        XCTAssertFalse(c.recording.get)
        XCTAssertEqual(sentTypes(t).last, "session_end")
        XCTAssertNil(Store(dir: dir).load())
        c.resetForTests()
    }

    func testANewLinkReplacesTheOldSession() {
        let t = FakeTransport()
        let c = core(t)
        let other = "qc_" + String(repeating: "c", count: 32)
        c.start(endpoint: endpoint, foreground: true, device: [:])
        c.take(token, foreground: true)
        settle(c)
        c.take(other, foreground: true)
        settle(c)
        XCTAssertEqual(Store(dir: dir).load()?.token, other)
        XCTAssertEqual(t.bodies.last?["sessionToken"] as? String, other)
        c.resetForTests()
    }

    func testAFieldStaysOnTheScreenItWasFocusedOn() {
        let t = FakeTransport()
        let c = core(t)
        c.start(endpoint: endpoint, foreground: true, device: [:])
        c.take(token, foreground: true)
        c.screen("Checkout", t: 1)
        c.event("field_focus", t: 2, data: ["field": "email"])
        c.screen("Menu", t: 3)   // the next screen appeared before the field ended editing
        c.event("field_edit", t: 4, data: ["field": "email", "edits": 2, "clears": 0])
        c.event("error", t: 5, data: ["kind": "network", "status": 503])
        settle(c)
        let ev = (0..<t.posts).flatMap { t.events($0) }.filter { ($0["type"] as? String) != "session_start" }
        XCTAssertEqual(ev.map { $0["type"] as? String }, ["screen_view", "field_focus", "screen_view", "field_edit", "error"])
        XCTAssertEqual(ev.map { $0["screen"] as? String }, ["Checkout", "Checkout", "Menu", "Checkout", "Menu"])
        c.resetForTests()
    }

    func testOnlyHttpsOrLocalhost() {
        XCTAssertTrue(Core.endpointAllowed(URL(string: "https://api.qanaries.com")!))
        XCTAssertTrue(Core.endpointAllowed(URL(string: "http://localhost:8820")!))
        XCTAssertTrue(Core.endpointAllowed(URL(string: "http://127.0.0.1:8799")!))
        XCTAssertFalse(Core.endpointAllowed(URL(string: "http://api.qanaries.com")!))
        XCTAssertFalse(Core.endpointAllowed(URL(string: "ftp://localhost")!))
    }
}
