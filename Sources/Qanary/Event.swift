import Foundation

/// One SDK event, in the wire format the Qanary API checks (schema/sdk-event.schema.json):
/// `{seq, t, type, screen?, data?}`. `t` is milliseconds since this launch started; `seq` only ever goes up within a session.
struct Event: Codable, Equatable {
    let seq: Int
    let t: Int
    let type: String
    var screen: String? = nil
    var data: [String: Value]? = nil

    /// The values an event's `data` may hold. Field events carry counts only, never text the person typed.
    enum Value: Codable, Equatable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let i = try? c.decode(Int.self) { self = .int(i) }
            else if let d = try? c.decode(Double.self) { self = .double(d) }
            else { self = .string(try c.decode(String.self)) }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .int(let i): try c.encode(i)
            case .double(let d): try c.encode(d)
            case .bool(let b): try c.encode(b)
            }
        }
    }

    /// Every allowed event type (the API refuses anything else).
    static let types: Set<String> = [
        "session_start", "session_end", "heartbeat", "foreground", "background",
        "screen_view", "rage_tap", "field_focus", "field_edit", "field_abandon",
        "error", "slow_frames", "task_marker", "shake_report",
    ]
    /// Keys a field event may never carry (the API refuses them too).
    static let forbiddenFieldKeys: Set<String> = ["value", "text", "input", "content", "password"]

    static let maxScreen = 120
    static let maxField = 60
}

extension Event.Value: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
}
