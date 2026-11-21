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

/// The keys of a JSON object that this version of Layer doesn't know, with their values
/// as they were read. A newer Layer may have added them: writing them back with the rest
/// means that saving a design here doesn't take away what that version put in it.
struct UnknownKeys: Equatable, Sendable {
    var values: [String: JSONValue] = [:]

    init() {}

    /// Reads the keys of the object `decoder` is reading that `Known` doesn't list.
    init<Known: CodingKey>(from decoder: any Decoder, besides _: Known.Type) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        for key in container.allKeys where Known(stringValue: key.stringValue) == nil {
            values[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
    }

    subscript(key: String) -> JSONValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    /// Every string in them, however deeply held: what they may name of the design's files.
    var strings: Set<String> {
        values.values.reduce(into: []) { $0.formUnion($1.strings) }
    }

    /// Adds the keys to the object `encoder` is writing.
    func encode(to encoder: any Encoder) throws {
        guard !values.isEmpty else { return }
        var container = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in values {
            try container.encode(value, forKey: AnyKey(key))
        }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ stringValue: String) { self.stringValue = stringValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// Something saved as a JSON object that keeps the keys it was read with but didn't know.
protocol KeepsUnknownKeys: Encodable {
    var unknownKeys: UnknownKeys { get }
}

/// A value as it is saved: the keys it was read with but didn't know, then its own. Its
/// own come second, so that one it now has a value for replaces one it couldn't read.
struct WithUnknownKeys<Value: KeepsUnknownKeys>: Encodable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }

    func encode(to encoder: any Encoder) throws {
        try value.unknownKeys.encode(to: encoder)
        try value.encode(to: encoder)
    }
}
