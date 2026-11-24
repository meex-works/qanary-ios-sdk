import Darwin
import Foundation

/// Crashes, reported as `error {kind: "crash"}` on the next launch.
///  - Uncaught Objective-C exceptions: the exception's name and the app's own top frame (never its reason, which can
///    carry user data).
///  - Fatal signals (Swift runtime traps, bad memory access, abort): the signal's name. A signal handler may only do
///    async-signal-safe things, so it writes a fixed record with write(2) to a file opened in advance, then hands the
///    signal on to whatever handler was there before (or the system's).
/// Both also note the screen that was in front. Armed only while a session records.
enum CrashCapture {
    struct Record: Equatable {
        let source: String     // "signal" | "exception"
        let signature: String
        let screen: String?
    }

    static let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]
    static let screenCapacity = 128

    // Read by the handlers: plain memory, all initialized in arm() before any handler is installed.
    fileprivate static var fd: Int32 = -1
    fileprivate static var written: Int32 = 0
    fileprivate static let screen: UnsafeMutablePointer<CChar> = {
        let p = UnsafeMutablePointer<CChar>.allocate(capacity: screenCapacity)
        p.initialize(repeating: 0, count: screenCapacity)
        return p
    }()
    fileprivate static let previous: UnsafeMutablePointer<sigaction> = {
        let p = UnsafeMutablePointer<sigaction>.allocate(capacity: Int(NSIG))
        p.initialize(repeating: sigaction(), count: Int(NSIG))
        return p
    }()
    fileprivate static var previousExceptionHandler: (@convention(c) (NSException) -> Void)?
    private static var installed = false
    private static let lock = NSLock()

    /// The record the last launch left, if it crashed while recording. The file is removed either way.
    static func takePending(_ file: URL) -> Record? {
        defer { try? FileManager.default.removeItem(at: file) }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return parse(text)
    }

    static func parse(_ text: String) -> Record? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3, lines[0] == "v1", !lines[2].isEmpty else { return nil }
        let screen = lines.count > 3 && !lines[3].isEmpty ? lines[3] : nil
        return Record(source: lines[1], signature: String(lines[2].prefix(200)), screen: screen)
    }

    static func arm(_ file: URL, screen name: String?) {
        lock.lock(); defer { lock.unlock() }
        _ = screen; _ = previous
        if fd < 0 { fd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600) }
        written = 0
        copyScreen(name ?? "")
        guard !installed else { return }
        installed = true
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(qanaryExceptionHandler)
        for s in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = qanarySignalHandler
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            sigaction(s, &action, previous.advanced(by: Int(s)))
        }
    }

    /// The session ended: nothing more is written. The handlers stay installed and simply pass signals on.
    static func disarm() {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }

    static func setScreen(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        copyScreen(name)
    }

    private static func copyScreen(_ name: String) {
        // One line, no newlines (the record is line-based).
        let clean = name.replacingOccurrences(of: "\n", with: " ")
        _ = clean.withCString { strncpy(screen, $0, screenCapacity - 1) }
        screen[screenCapacity - 1] = 0
    }

    /// Exception name + the first frame in the app's own executable.
    static func signature(_ e: NSException) -> String {
        let exe = Bundle.main.executableURL?.lastPathComponent ?? ProcessInfo.processInfo.processName
        return String("\(e.name.rawValue)@\(appFrame(e.callStackSymbols, executable: exe) ?? "?")".prefix(200))
    }

    /// The symbol of the first frame in the app's own image, from lines like
    /// `4   MyApp   0x0000000102a3c5e4 $s5MyApp4mainyyF + 120`. Debug builds keep the app's code in
    /// `MyApp.debug.dylib`, so the image only has to start with the executable's name.
    static func appFrame(_ symbols: [String], executable exe: String) -> String? {
        symbols.lazy.compactMap { line -> String? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4, parts[1] == exe || parts[1].hasPrefix(exe + ".") else { return nil }
            return demangle(parts[3...].prefix { $0 != "+" }.joined(separator: " "))
        }.first
    }

    private typealias Demangler = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?

    /// A Swift symbol made readable ("closure #1 in CheckoutView.body.getter") by the Swift runtime's own demangler;
    /// anything else, or a runtime without it, stays as it is.
    static func demangle(_ symbol: String) -> String {
        guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s"),
              let fn = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return symbol }   // RTLD_DEFAULT
        let demangler = unsafeBitCast(fn, to: Demangler.self)
        return symbol.withCString { p in
            guard let out = demangler(p, strlen(p), nil, nil, 0) else { return symbol }
            defer { free(out) }
            return String(cString: out)
        }
    }

    fileprivate static func recordException(_ e: NSException) {
        guard fd >= 0, written == 0 else { return }
        written = 1
        var screenName = ""
        screenName = String(cString: screen)
        let text = "v1\nexception\n\(signature(e).replacingOccurrences(of: "\n", with: " "))\n\(screenName)\n"
        lseek(fd, 0, SEEK_SET)
        ftruncate(fd, 0)
        text.withCString { _ = write(fd, $0, strlen($0)) }
        fsync(fd)
    }
}

private func qanaryExceptionHandler(_ e: NSException) {
    CrashCapture.recordException(e)
    CrashCapture.previousExceptionHandler?(e)
}

/// Async-signal-safe: fixed strings, write(2), no allocation, no locks.
private func qanarySignalHandler(_ sig: Int32) {
    let fd = CrashCapture.fd
    if fd >= 0 && CrashCapture.written == 0 {
        CrashCapture.written = 1
        lseek(fd, 0, SEEK_SET)
        put(fd, "v1\nsignal\n")
        put(fd, signalName(sig))
        put(fd, "\n")
        var n = 0
        while n < CrashCapture.screenCapacity - 1 && CrashCapture.screen[n] != 0 { n += 1 }
        _ = write(fd, CrashCapture.screen, n)
        put(fd, "\n")
        fsync(fd)
    }
    // Hand the signal on: restore what was there before and let it run. A fault re-occurs as soon as this returns;
    // abort() has to be raised again.
    sigaction(sig, CrashCapture.previous.advanced(by: Int(sig)), nil)
    if sig == SIGABRT { raise(sig) }
}

private func put(_ fd: Int32, _ s: StaticString) {
    _ = write(fd, s.utf8Start, s.utf8CodeUnitCount)
}

private func signalName(_ sig: Int32) -> StaticString {
    switch sig {
    case SIGABRT: return "SIGABRT"
    case SIGSEGV: return "SIGSEGV"
    case SIGBUS: return "SIGBUS"
    case SIGILL: return "SIGILL"
    case SIGFPE: return "SIGFPE"
    case SIGTRAP: return "SIGTRAP"
    default: return "SIGNAL"
    }
}
