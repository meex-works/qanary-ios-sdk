import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// What session_start says about the phone and the build: the model identifier (e.g. "iPhone16,1"), the OS and its
/// version, the app's version and the SDK's. Nothing that identifies the person or the device.
enum DeviceInfo {
    static func collect() -> [String: Event.Value] {
        [
            "device": .string(model()),
            "os": "ios",
            "osVersion": .string(osVersion()),
            "appVersion": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"),
            "sdkVersion": .string(Qanary.sdkVersion),
        ]
    }

    /// The hardware model identifier. The simulator reports the model it simulates.
    static func model() -> String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !sim.isEmpty { return sim }
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }

    static func osVersion() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }
}

/// Whether the app is in front, and the notifications that say when it changes.
enum AppState {
    #if canImport(UIKit)
    /// Read without UIApplication.shared, so an app extension linking the SDK still builds.
    static var app: UIApplication? {
        (UIApplication.self as AnyObject).perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? UIApplication
    }

    static var isForeground: Bool {
        guard Thread.isMainThread, let app else { return true }
        return app.applicationState != .background
    }

    private static var observing = false

    /// Installed at start() (main thread), so a change is never missed between a link arriving and the first event.
    static func observe() {
        guard Thread.isMainThread else { return DispatchQueue.main.async { observe() } }
        guard !observing else { return }
        observing = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            let t = Clock.ms()
            guard Core.shared.recording.get, let app else { return Core.shared.didEnterBackground(t: t) {} }
            // Ask for a little time so the last batch goes out before the app is suspended.
            let task = BackgroundTask()
            task.id = app.beginBackgroundTask(withName: "qanary-flush") { task.end(app) }
            Core.shared.didEnterBackground(t: t) { DispatchQueue.main.async { task.end(app) } }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            Core.shared.willEnterForeground(t: Clock.ms())
        }
    }

    private final class BackgroundTask {
        var id: UIBackgroundTaskIdentifier = .invalid
        func end(_ app: UIApplication) {
            guard id != .invalid else { return }
            app.endBackgroundTask(id)
            id = .invalid
        }
    }
    #else
    static var isForeground: Bool { true }
    #endif
}
