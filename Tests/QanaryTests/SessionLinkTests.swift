import XCTest
@testable import Qanary

final class SessionLinkTests: XCTestCase {
    let qs = "qs_" + String(repeating: "aB3-_", count: 8) + "xyz"   // 46 characters, like the API's tokens
    let qc = "qc_kQ2yN8Zr0vT1uXw5Pq7sLm9dHc3bFa6e"

    func testTakesTesterAndCheckTokens() {
        XCTAssertEqual(SessionLink.token(in: URL(string: "mealpal://qanary?session=\(qs)")!), qs)
        XCTAssertEqual(SessionLink.token(in: URL(string: "mealpal://qanary?session=\(qc)")!), qc)
        XCTAssertTrue(SessionLink.isCheck(qc))
        XCTAssertFalse(SessionLink.isCheck(qs))
    }

    func testAcceptsTheShapesAppsSee() {
        XCTAssertEqual(SessionLink.token(in: URL(string: "mealpal://qanary/?session=\(qs)")!), qs, "trailing slash")
        XCTAssertEqual(SessionLink.token(in: URL(string: "mealpal://QANARY?session=\(qs)")!), qs, "host is case-insensitive")
        XCTAssertEqual(SessionLink.token(in: URL(string: "mealpal:qanary?session=\(qs)")!), qs, "no //")
        XCTAssertEqual(SessionLink.token(in: URL(string: "mealpal://qanary?x=1&session=\(qs)&y=2")!), qs, "other parameters")
        // The API percent-encodes the token; base64url never needs it, but a decoder must still read it.
        XCTAssertEqual(SessionLink.token(in: URL(string: "mealpal://qanary?session=\(qs.replacingOccurrences(of: "-", with: "%2D"))")!), qs)
    }

    func testRefusesEverythingElse() {
        for s in [
            "mealpal://open?session=\(qs)",            // not the qanary host
            "mealpal://qanary?token=\(qs)",            // wrong parameter
            "mealpal://qanary?session=",               // empty
            "mealpal://qanary?session=qa_abcdefghijklmnopqrstu",   // a sign-in token, not a session
            "mealpal://qanary?session=qs_short",       // too short
            "mealpal://qanary?session=qs_" + String(repeating: "a", count: 130),   // too long
            "mealpal://qanary?session=qs_abcdefgh%20ijklmnopq",   // a space
            "mealpal://qanary?session=qs_abcdefgh%2Fijklmnopq",   // a slash
            "https://qanaries.com/qanary?session=\(qs)", // a web link with a path, host isn't qanary
            "mealpal://settings",
        ] {
            XCTAssertNil(SessionLink.token(in: URL(string: s)!), s)
        }
    }

    func testHandleReturnsWhetherItWasConsumed() {
        XCTAssertFalse(Qanary.handle(URL(string: "mealpal://settings")!))
        XCTAssertFalse(Qanary.handle(URL(string: "https://example.com/qanary?session=\(qs)")!))
        XCTAssertTrue(Qanary.handle(URL(string: "mealpal://qanary?session=\(qs)")!))
        // Not started in this test process: the token waits for start() and nothing is recorded or written.
        XCTAssertEqual(Core.shared.sync { Core.shared.takePendingTokenForTests() }, qs)
        XCTAssertFalse(Qanary.isRecording)
    }
}
