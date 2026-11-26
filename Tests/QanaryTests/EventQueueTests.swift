import XCTest
@testable import Qanary

/// Answers each post with the next status in `statuses` (nil = no answer), and keeps every body it was sent.
final class FakeTransport: Transport {
    var statuses: [Int?]
    private(set) var bodies: [[String: Any]] = []
    private let lock = NSLock()

    init(_ statuses: [Int?] = []) { self.statuses = statuses }

    func post(_ body: Data, completion: @escaping (Int?) -> Void) {
        lock.lock()
        bodies.append((try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
        let status = statuses.isEmpty ? 200 : statuses.removeFirst()
        lock.unlock()
        DispatchQueue.global().async { completion(status) }
    }

    var posts: Int { lock.lock(); defer { lock.unlock() }; return bodies.count }
    func events(_ i: Int) -> [[String: Any]] { (bodies[i]["events"] as? [[String: Any]]) ?? [] }
}

final class EventQueueTests: XCTestCase {
    var dir: URL!
    let q = DispatchQueue(label: "test.sdk")
    let token = "qs_" + String(repeating: "x", count: 43)

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("qanary-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func queue(_ t: FakeTransport, startSeq: Int = 0, appId: String? = "com.example.mealpal", reserved: ((Int) -> Void)? = nil) -> EventQueue {
        q.sync { EventQueue(token: token, file: dir.appendingPathComponent("events.jsonl"), startSeq: startSeq, appId: appId, transport: t, queue: q, reserve: reserved ?? { _ in }) }
    }

    private func flush(_ e: EventQueue) -> EventQueue.Outcome {
        let done = expectation(description: "flush")
        var out: EventQueue.Outcome = .idle
        q.async { e.flush { out = $0; done.fulfill() } }
        wait(for: [done], timeout: 5)
        return out
    }

    func testSequenceTimesAndTheWireFormat() {
        let t = FakeTransport()
        let e = queue(t)
        q.sync {
            e.add("session_start", t: 0, data: ["device": "iPhone16,1", "os": "ios", "resumed": false])
            e.add("screen_view", t: 120, screen: "CheckoutViewController")
            e.add("heartbeat", t: 10_000)
        }
        XCTAssertEqual(flush(e), .sent)
        XCTAssertEqual(t.posts, 1)
        XCTAssertEqual(t.bodies[0]["sessionToken"] as? String, token)
        XCTAssertEqual(t.bodies[0]["sdkVersion"] as? String, "ios-0.1.1")
        XCTAssertEqual(t.bodies[0]["appId"] as? String, "com.example.mealpal", "the app it's in, for the verify check")
        let ev = t.events(0)
        XCTAssertEqual(ev.map { $0["seq"] as? Int }, [0, 1, 2])
        XCTAssertEqual(ev.map { $0["t"] as? Int }, [0, 120, 10_000])
        XCTAssertEqual(ev.map { $0["type"] as? String }, ["session_start", "screen_view", "heartbeat"])
        XCTAssertEqual(ev[1]["screen"] as? String, "CheckoutViewController")
        XCTAssertNil(ev[2]["screen"], "no screen key when there's none")
        XCTAssertNil(ev[2]["data"], "no data key when there's none")
        XCTAssertEqual((ev[0]["data"] as? [String: Any])?["resumed"] as? Bool, false)
        XCTAssertEqual(q.sync { e.count }, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.file.path), "nothing left to keep on disk")
    }

    func testNoAppIdKeyWhenItIsUnknown() {
        let t = FakeTransport()
        let e = queue(t, appId: nil)
        q.sync { _ = e.add("heartbeat", t: 1) }
        XCTAssertEqual(flush(e), .sent)
        XCTAssertNil(t.bodies[0]["appId"])
    }

    func testEventsSurviveAKill() {
        let e1 = queue(FakeTransport())
        q.sync { _ = e1.add("session_start", t: 0); _ = e1.add("rage_tap", t: 50, data: ["taps": 3, "region": "top"]) }
        // The process dies before sending. A new queue on the same file sends them first.
        let t = FakeTransport()
        let e2 = queue(t, startSeq: 50)
        q.sync { _ = e2.add("session_start", t: 0) }
        XCTAssertEqual(flush(e2), .sent)
        XCTAssertEqual(t.events(0).map { $0["seq"] as? Int }, [0, 1, 50])
        XCTAssertEqual(t.events(0).map { $0["type"] as? String }, ["session_start", "rage_tap", "session_start"])
    }

    func testRetriesWhenThereIsNoAnswerOrAServerError() {
        let t = FakeTransport([nil, 503, 200])
        let e = queue(t)
        q.sync { _ = e.add("heartbeat", t: 1) }
        XCTAssertEqual(flush(e), .retry)
        XCTAssertEqual(flush(e), .retry)
        XCTAssertEqual(q.sync { e.count }, 1, "kept for the next try")
        XCTAssertTrue(FileManager.default.fileExists(atPath: e.file.path))
        XCTAssertEqual(flush(e), .sent)
        XCTAssertEqual(t.events(2).first?["seq"] as? Int, 0, "the same event, the same seq")
    }

    func testARefusedBatchIsDroppedNotRetriedForever() {
        let t = FakeTransport([400])
        let e = queue(t)
        q.sync { _ = e.add("heartbeat", t: 1) }
        XCTAssertEqual(flush(e), .refused(400))
        XCTAssertEqual(q.sync { e.count }, 0)
    }

    func testGoneStopsTheSessionForGood() {
        for status in [410, 404] {
            let t = FakeTransport([status])
            let e = queue(t)
            var finished = false
            q.sync { e.onFinished = { finished = true }; e.add("heartbeat", t: 1) }
            XCTAssertEqual(flush(e), .finished, "\(status)")
            q.sync {
                XCTAssertTrue(finished)
                XCTAssertTrue(e.stopped)
                XCTAssertNil(e.add("heartbeat", t: 2), "nothing is recorded after the session is over")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: e.file.path))
        }
    }

    func testBatchesOfFiveHundred() {
        let t = FakeTransport()
        let e = queue(t)
        q.sync { for i in 0..<1203 { e.add("heartbeat", t: i) } }
        XCTAssertEqual(flush(e), .sent)
        XCTAssertEqual(t.posts, 3)
        XCTAssertEqual([0, 1, 2].map { t.events($0).count }, [500, 500, 203])
        XCTAssertEqual(t.events(2).last?["seq"] as? Int, 1202)
    }

    func testFieldEventsNeverCarryText() {
        let t = FakeTransport()
        let e = queue(t)
        q.sync {
            XCTAssertNil(e.add("field_edit", t: 1, data: ["edits": 3]), "a field event needs data.field")
            e.add("field_edit", t: 2, data: ["field": .string(String(repeating: "f", count: 90)), "edits": 3, "clears": 1,
                                         "value": "secret", "text": "secret", "input": "secret", "content": "secret", "password": "secret"])
            XCTAssertNil(e.add("keystroke", t: 3), "unknown types are dropped")
        }
        XCTAssertEqual(flush(e), .sent)
        let data = t.events(0)[0]["data"] as? [String: Any]
        XCTAssertEqual(Set((data ?? [:]).keys), ["field", "edits", "clears"])
        XCTAssertEqual((data?["field"] as? String)?.count, 60)
        XCTAssertEqual(t.events(0).count, 1)
    }

    func testSequenceNumbersAreReservedBeforeUse() {
        var reserved: [Int] = []
        let e = queue(FakeTransport(), startSeq: 100) { reserved.append($0) }
        q.sync { for i in 0..<120 { e.add("heartbeat", t: i) } }
        // Reserved up to 150 before seq 100 was used, then 200, then 250: a crash at any point restarts above every used number.
        XCTAssertEqual(reserved, [150, 200, 250])
        XCTAssertEqual(q.sync { e.nextSeq }, 220)
        XCTAssertTrue(reserved.last! >= q.sync { e.nextSeq })
    }

    func testFinishSendsWhatIsLeftThenStops() {
        let t = FakeTransport()
        let e = queue(t)
        let done = expectation(description: "finished")
        q.async {
            e.add("session_end", t: 5)
            e.finish { done.fulfill() }
            XCTAssertNil(e.add("heartbeat", t: 6), "closing: nothing new")
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(t.events(0).map { $0["type"] as? String }, ["session_end"])
        XCTAssertTrue(q.sync { e.stopped })
    }

    func testScreenNamesAreCapped() {
        let t = FakeTransport()
        let e = queue(t)
        q.sync { _ = e.add("screen_view", t: 0, screen: String(repeating: "S", count: 300)) }
        XCTAssertEqual(flush(e), .sent)
        XCTAssertEqual((t.events(0)[0]["screen"] as? String)?.count, 120)
    }
}
