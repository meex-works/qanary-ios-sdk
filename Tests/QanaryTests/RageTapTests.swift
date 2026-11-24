import XCTest
@testable import Qanary

final class RageTapTests: XCTestCase {
    let h = 900.0

    func testThreeQuickTapsInOnePlace() {
        var d = RageTapDetector()
        XCTAssertNil(d.tap(x: 100, y: 100, at: 10.0, height: h))
        XCTAssertNil(d.tap(x: 104, y: 98, at: 10.3, height: h))
        XCTAssertEqual(d.tap(x: 99, y: 103, at: 10.6, height: h), .init(taps: 3, region: "top"))
    }

    func testSlowTapsAreNotRage() {
        var d = RageTapDetector()
        XCTAssertNil(d.tap(x: 100, y: 100, at: 10.0, height: h))
        XCTAssertNil(d.tap(x: 100, y: 100, at: 10.6, height: h))
        XCTAssertNil(d.tap(x: 100, y: 100, at: 11.2, height: h), "the first tap fell out of the 700 ms window")
    }

    func testTapsAllOverTheScreenAreNotRage() {
        var d = RageTapDetector()
        XCTAssertNil(d.tap(x: 50, y: 100, at: 1.0, height: h))
        XCTAssertNil(d.tap(x: 200, y: 100, at: 1.1, height: h))
        XCTAssertNil(d.tap(x: 50, y: 400, at: 1.2, height: h))
        XCTAssertNil(d.tap(x: 300, y: 700, at: 1.3, height: h))
    }

    func testOneReportPerBurst() {
        var d = RageTapDetector()
        _ = d.tap(x: 10, y: 800, at: 1.0, height: h)
        _ = d.tap(x: 10, y: 800, at: 1.1, height: h)
        XCTAssertEqual(d.tap(x: 10, y: 800, at: 1.2, height: h), .init(taps: 3, region: "bottom"))
        XCTAssertNil(d.tap(x: 10, y: 800, at: 1.3, height: h))
        XCTAssertNil(d.tap(x: 10, y: 800, at: 1.4, height: h))
        XCTAssertNil(d.tap(x: 10, y: 800, at: 1.5, height: h), "still the same burst")
        // A second burst later on counts again.
        _ = d.tap(x: 10, y: 450, at: 5.0, height: h)
        _ = d.tap(x: 10, y: 450, at: 5.1, height: h)
        XCTAssertEqual(d.tap(x: 10, y: 450, at: 5.2, height: h), .init(taps: 3, region: "middle"))
    }

    func testCountsEveryNearbyTapInTheBurst() {
        var d = RageTapDetector()
        _ = d.tap(x: 200, y: 200, at: 1.0, height: h)
        _ = d.tap(x: 500, y: 200, at: 1.05, height: h)   // elsewhere: not counted
        _ = d.tap(x: 210, y: 200, at: 1.1, height: h)
        XCTAssertEqual(d.tap(x: 205, y: 205, at: 1.2, height: h)?.taps, 3)
    }
}

final class CrashRecordTests: XCTestCase {
    func testParsesWhatTheHandlersWrite() {
        XCTAssertEqual(CrashCapture.parse("v1\nsignal\nSIGTRAP\nCheckoutViewController\n"),
                       .init(source: "signal", signature: "SIGTRAP", screen: "CheckoutViewController"))
        XCTAssertEqual(CrashCapture.parse("v1\nexception\nNSInvalidArgumentException@$s6Sample4mainyyF\n\n"),
                       .init(source: "exception", signature: "NSInvalidArgumentException@$s6Sample4mainyyF", screen: nil))
    }

    func testFindsTheAppsOwnFrame() {
        let stack = [
            "0   CoreFoundation                      0x00000001804c0e80 __exceptionPreprocess + 160",
            "1   libobjc.A.dylib                     0x0000000180096168 objc_exception_throw + 72",
            "2   QanarySample.debug.dylib            0x0000000102a3c5e4 $s12QanarySample11AboutScreenV4bodyQrvgyyScMYccfU_ + 120",
            "3   SwiftUI                             0x00000001c0a0b0c0 $s7SwiftUI6ButtonV + 44",
        ]
        XCTAssertEqual(CrashCapture.appFrame(stack, executable: "QanarySample"), "closure #1 @Swift.MainActor () -> () in QanarySample.AboutScreen.body.getter : some", "demangled")
        XCTAssertEqual(CrashCapture.appFrame(["2   QanarySample   0x1 main + 1"], executable: "QanarySample"), "main")
        XCTAssertEqual(CrashCapture.demangle("$s12QanarySample4mainyyF"), "QanarySample.main() -> ()")
        XCTAssertEqual(CrashCapture.demangle("-[NSObject init]"), "-[NSObject init]", "not Swift: unchanged")
        XCTAssertNil(CrashCapture.appFrame(Array(stack.prefix(2)), executable: "QanarySample"))
        XCTAssertNil(CrashCapture.appFrame(["2   QanarySampleKit   0x1 x + 1"], executable: "QanarySample"), "another image that only starts with the name")
    }

    func testIgnoresAnEmptyOrForeignFile() {
        XCTAssertNil(CrashCapture.parse(""))
        XCTAssertNil(CrashCapture.parse("hello"))
        XCTAssertNil(CrashCapture.parse("v2\nsignal\nSIGSEGV\n"))
    }
}
