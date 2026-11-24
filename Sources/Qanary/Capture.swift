import Foundation
#if canImport(UIKit)
import ObjectiveC
import UIKit

/// The automatic capture: screens (view controllers), rage taps and text-field counts. Installed on the main thread
/// the first time a session starts; until then the SDK doesn't touch the app at all. Every hook returns at once when
/// nothing is recording.
enum Hooks {
    private static var installed = false

    static func installOnce() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !installed else { return }
        installed = true
        swizzle(UIViewController.self, #selector(UIViewController.viewDidAppear(_:)), #selector(UIViewController.qanary_viewDidAppear(_:)))
        swizzle(UIWindow.self, #selector(UIWindow.sendEvent(_:)), #selector(UIWindow.qanary_sendEvent(_:)))
        FieldWatcher.install()
    }

    private static func swizzle(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let o = class_getInstanceMethod(cls, original), let r = class_getInstanceMethod(cls, replacement) else { return }
        if class_addMethod(cls, original, method_getImplementation(r), method_getTypeEncoding(r)) {
            class_replaceMethod(cls, replacement, method_getImplementation(o), method_getTypeEncoding(o))
        } else {
            method_exchangeImplementations(o, r)
        }
    }
}

extension UIViewController {
    /// Runs the original viewDidAppear (the implementations are swapped), then names the screen.
    @objc func qanary_viewDidAppear(_ animated: Bool) {
        qanary_viewDidAppear(animated)
        ScreenTracker.didAppear(self)
    }
}

extension UIWindow {
    /// Watches touches on their way through, never changing or holding them.
    @objc func qanary_sendEvent(_ event: UIEvent) {
        TouchWatcher.observe(event, in: self)
        qanary_sendEvent(event)
    }
}

/// A screen = a view controller of the app's own, shown by itself, presented, inside a navigation, tab, split or page
/// controller, or hosted in SwiftUI. Containers, children embedded in another of the app's screens, and Apple's own
/// controllers (keyboards, alerts, SwiftUI's hosting controllers) are skipped. SwiftUI views name their screens with
/// `.qanaryScreen("Name")`.
enum ScreenTracker {
    private static var ownClass: [ObjectIdentifier: Bool] = [:]

    static func didAppear(_ vc: UIViewController) {
        guard Core.shared.recording.get, !isContainer(vc), isOwn(type(of: vc)) else { return }
        // A child embedded in another of the app's screens is part of that screen. (A child of SwiftUI's own
        // controllers, i.e. a UIViewControllerRepresentable, is a screen.)
        if let parent = vc.parent, !isContainer(parent), isOwn(type(of: parent)) { return }
        Qanary.screen(String(describing: type(of: vc)))
    }

    static func isContainer(_ vc: UIViewController) -> Bool {
        vc is UINavigationController || vc is UITabBarController || vc is UISplitViewController || vc is UIPageViewController
    }

    /// Classes from the app's bundle (its executable, or a framework inside it), not the system's.
    private static func isOwn(_ cls: AnyClass) -> Bool {
        let key = ObjectIdentifier(cls)
        if let known = ownClass[key] { return known }
        let own = Bundle(for: cls).bundlePath.hasPrefix(Bundle.main.bundlePath)
        ownClass[key] = own
        return own
    }
}

/// Finished taps (a touch that didn't travel) go to the rage-tap detector. Only positions and times are read.
enum TouchWatcher {
    private static var starts: [ObjectIdentifier: CGPoint] = [:]
    private static var detector = RageTapDetector()
    static let tapSlop: CGFloat = 12

    static func observe(_ event: UIEvent, in window: UIWindow) {
        guard event.type == .touches, Core.shared.recording.get, let touches = event.allTouches else { return }
        for touch in touches where touch.window === window {
            let id = ObjectIdentifier(touch)
            switch touch.phase {
            case .began:
                if starts.count > 20 { starts.removeAll() }
                starts[id] = touch.location(in: window)
            case .ended:
                let p = touch.location(in: window)
                let s = starts.removeValue(forKey: id) ?? p
                guard hypot(p.x - s.x, p.y - s.y) <= tapSlop else { continue }
                if let hit = detector.tap(x: Double(p.x), y: Double(p.y), at: touch.timestamp, height: Double(window.bounds.height)) {
                    Core.shared.event("rage_tap", t: Clock.ms(), data: ["taps": .int(hit.taps), "region": .string(hit.region)])
                }
            case .cancelled:
                starts.removeValue(forKey: id)
            default:
                break
            }
        }
    }
}

/// Edit and clear counts for UITextField and UITextView (SwiftUI's TextField is one of these), from the system's own
/// notifications. Only the LENGTH of the text is ever read, to tell an edit that emptied the field; never the text.
/// A field is named by its accessibilityIdentifier, else its placeholder, else its tag.
enum FieldWatcher {
    private struct Counts { var edits = 0; var clears = 0; var length = 0 }
    private static var fields: [ObjectIdentifier: Counts] = [:]

    static func install() {
        let nc = NotificationCenter.default
        for (begin, change, end) in [
            (UITextField.textDidBeginEditingNotification, UITextField.textDidChangeNotification, UITextField.textDidEndEditingNotification),
            (UITextView.textDidBeginEditingNotification, UITextView.textDidChangeNotification, UITextView.textDidEndEditingNotification),
        ] {
            nc.addObserver(forName: begin, object: nil, queue: .main) { began($0.object) }
            nc.addObserver(forName: change, object: nil, queue: .main) { changed($0.object) }
            nc.addObserver(forName: end, object: nil, queue: .main) { ended($0.object) }
        }
    }

    private static func length(_ o: Any?) -> Int? {
        if let f = o as? UITextField { return f.text?.utf16.count ?? 0 }
        if let v = o as? UITextView { return v.text?.utf16.count ?? 0 }
        return nil
    }

    static func name(_ o: Any?) -> String {
        let view = o as? UIView
        if let id = view?.accessibilityIdentifier, !id.isEmpty { return String(id.prefix(Event.maxField)) }
        if let p = (o as? UITextField)?.placeholder, !p.isEmpty { return String(p.prefix(Event.maxField)) }
        if let tag = view?.tag, tag != 0 { return "field_\(tag)" }
        return "unnamed_field"
    }

    private static func began(_ o: Any?) {
        guard Core.shared.recording.get, let o = o as AnyObject?, let len = length(o) else { return }
        fields[ObjectIdentifier(o)] = Counts(length: len)
        Core.shared.event("field_focus", t: Clock.ms(), data: ["field": .string(name(o))])
    }

    private static func changed(_ o: Any?) {
        guard Core.shared.recording.get, let o = o as AnyObject?, let len = length(o) else { return }
        var c = fields[ObjectIdentifier(o)] ?? Counts(length: len)
        c.edits += 1
        if c.length > 0 && len == 0 { c.clears += 1 }
        c.length = len
        fields[ObjectIdentifier(o)] = c
    }

    private static func ended(_ o: Any?) {
        guard let o = o as AnyObject?, let c = fields.removeValue(forKey: ObjectIdentifier(o)) else { return }
        guard Core.shared.recording.get, c.edits > 0 else { return }
        let n = name(o)
        Qanary.field(n, edits: c.edits, clears: c.clears)
        if (length(o) ?? 0) == 0 { Qanary.fieldAbandoned(n) }
    }
}
#endif

/// A frozen main thread: pinged every second from a background thread; no answer for 5 s while the app is in front
/// is reported once per freeze as `error {kind: "anr"}` on the current screen.
final class Watchdog {
    static let shared = Watchdog()
    static let threshold: TimeInterval = 5

    private let lock = NSLock()
    private var running = false
    private var generation = 0
    private var lastPong = ProcessInfo.processInfo.systemUptime
    private var waiting = false

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        running = true
        generation += 1
        let gen = generation
        lastPong = ProcessInfo.processInfo.systemUptime
        waiting = false
        let thread = Thread { [weak self] in self?.loop(gen) }
        thread.name = "com.qanaries.sdk.watchdog"
        thread.stackSize = 64 * 1024
        thread.start()
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
    }

    private func alive(_ gen: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return running && generation == gen }

    private func loop(_ gen: Int) {
        var reported = false
        while alive(gen) {
            let before = ProcessInfo.processInfo.systemUptime
            lock.lock()
            let ping = !waiting
            if ping { waiting = true }
            lock.unlock()
            if ping {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); self.lastPong = ProcessInfo.processInfo.systemUptime; self.waiting = false; self.lock.unlock()
                }
            }
            Thread.sleep(forTimeInterval: 1)
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            if now - before > 3 { lastPong = now }   // this thread was suspended (app in the background), not frozen
            let stillWaiting = waiting
            let blocked = stillWaiting ? now - lastPong : 0
            lock.unlock()
            if blocked >= Watchdog.threshold {
                if !reported && Core.shared.inForeground.get {
                    reported = true
                    Core.shared.event("error", t: Clock.ms(), data: ["kind": "anr", "signature": "main-thread-blocked", "blockedMs": .int(Int(blocked * 1000))])
                }
            } else if !stillWaiting {
                reported = false   // the main thread answered: the next freeze is a new one
            }
        }
    }
}
