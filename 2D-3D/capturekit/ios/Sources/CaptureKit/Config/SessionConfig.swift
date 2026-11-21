import Foundation

/// One value of the flat session config handed to the core (`ck_session_create` config_json).
/// Pure Swift port of the Kotlin `Map<String, Any>` the Android shell builds (ADR 0037).
public enum ConfigValue: Equatable {
    case int(Int)
    case double(Double)
    case string(String)
}

extension ConfigValue: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
}

/// Flat key/value session config (keys such as `guide.understanding`, `record_imu`, `calib.*`, `consent_version`).
public typealias SessionConfig = [String: ConfigValue]

public enum SessionConfigJSON {
    /// Flat JSON object with sorted keys (deterministic). Numbers are written with `%.17g` so doubles round-trip.
    public static func encode(_ config: SessionConfig) -> String {
        let parts = config.keys.sorted().map { key -> String in
            let v: String
            switch config[key]! {
            case .int(let i): v = String(i)
            case .double(let d): v = d.isFinite ? String(format: "%.17g", d) : "0"
            case .string(let s): v = quote(s)
            }
            return "\(quote(key)):\(v)"
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}
