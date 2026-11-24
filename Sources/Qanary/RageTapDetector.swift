import Foundation

/// 3 or more taps within 700 ms, inside a small circle, is a rage tap: someone hammering a control that
/// doesn't answer. Same rule as the Android SDK (Capture.kt), in points instead of dp. Pure, so it's unit tested.
struct RageTapDetector {
    static let window: TimeInterval = 0.7
    static let radius: Double = 48
    static let minTaps = 3

    struct Hit: Equatable { let taps: Int; let region: String }

    private var taps: [(t: TimeInterval, x: Double, y: Double)] = []
    private var reportedAt: TimeInterval = -.infinity

    /// One finished tap at window point (x, y) at time `t` (seconds, monotonic). `height` is the window's height, which
    /// places the hit in the top, middle or bottom third. Returns a hit at most once per burst.
    mutating func tap(x: Double, y: Double, at t: TimeInterval, height: Double) -> Hit? {
        taps.append((t, x, y))
        taps.removeAll { t - $0.t > RageTapDetector.window }
        let near = taps.filter { hypot($0.x - x, $0.y - y) < RageTapDetector.radius }.count
        guard near >= RageTapDetector.minTaps, t - reportedAt > RageTapDetector.window else { return nil }
        reportedAt = t
        taps.removeAll()
        let h = max(height, 1)
        let region = y < h / 3 ? "top" : y < 2 * h / 3 ? "middle" : "bottom"
        return Hit(taps: near, region: region)
    }
}
