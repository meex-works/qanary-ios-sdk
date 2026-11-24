import Foundation

/// The link the Qanary app (or a developer verifying a build) opens: `<app scheme>://qanary?session=<token>`.
/// Tokens start `qs_` (a tester's session) or `qc_` (the developer's own one-day check).
enum SessionLink {
    static let host = "qanary"
    static let prefixes = ["qs_", "qc_"]

    /// The session token in `url`, or nil when it isn't a Qanary link with a well-formed token.
    static func token(in url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // `myapp://qanary?session=…` (host form), also `myapp://qanary/?session=…` and `myapp:qanary?session=…`.
        let host = parts.host ?? parts.path.split(separator: "/").first.map(String.init) ?? ""
        guard host.lowercased() == SessionLink.host else { return nil }
        guard let raw = parts.queryItems?.first(where: { $0.name == "session" })?.value else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return isToken(token) ? token : nil
    }

    /// `qs_` or `qc_` and then base64url, 16 to 128 characters in all (the API's own bounds).
    static func isToken(_ s: String) -> Bool {
        guard s.count >= 16, s.count <= 128, prefixes.contains(where: { s.hasPrefix($0) }) else { return false }
        return s.dropFirst(3).allSatisfy { c in c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_") }
    }

    /// A check token makes the build report to the developer's verify page, never to a paid test.
    static func isCheck(_ token: String) -> Bool { token.hasPrefix("qc_") }
}
