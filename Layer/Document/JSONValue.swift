import Foundation

/// Any JSON value, kept as it was read. A design holds the parts of itself that this
/// version of Layer doesn't understand this way, and writes them back unchanged.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Every string in the value, however deeply it is held. What a design doesn't
    /// understand may still name its files this way: a picture's identifier, a drawing's.
    var strings: Set<String> {
        switch self {
        case .null, .bool, .number: []
        case .string(let value): [value]
        case .array(let values): values.reduce(into: []) { $0.formUnion($1.strings) }
        case .object(let values): values.values.reduce(into: []) { $0.formUnion($1.strings) }
        }
    }
}
