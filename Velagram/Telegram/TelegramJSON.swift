import Foundation

indirect enum TelegramJSON: Codable, Sendable, Equatable {
    case object([String: TelegramJSON]), array([TelegramJSON]), string(String), integer(Int64), double(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([TelegramJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: TelegramJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> TelegramJSON {
        guard case .object(let values) = self else { return .null }; return values[key] ?? .null
    }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var int64: Int64? {
        if case .integer(let v) = self { return v }
        if case .string(let v) = self { return Int64(v) }
        return nil
    }
    var int: Int { Int(int64 ?? 0) }
    var bool: Bool { if case .bool(let v) = self { return v }; return false }
    var array: [TelegramJSON] { if case .array(let v) = self { return v }; return [] }
    var type: String { self["@type"].string ?? "" }
    func setting(_ key: String, _ value: TelegramJSON) -> TelegramJSON {
        guard case .object(var values) = self else { return self }; values[key] = value; return .object(values)
    }
    static func request(_ type: String, _ fields: [String: TelegramJSON] = [:]) -> TelegramJSON {
        .object(fields.merging(["@type": .string(type)]) { _, new in new })
    }
}

struct TelegramError: LocalizedError, Sendable, Equatable {
    let code: Int
    let message: String
    var errorDescription: String? {
        switch message {
        case "PHONE_NUMBER_INVALID": "Enter a valid phone number including its country code."
        case "PHONE_CODE_INVALID": "The login code is incorrect. Try again."
        case "PHONE_CODE_EXPIRED": "The login code expired. Request a new one."
        case "PASSWORD_HASH_INVALID": "The two-step verification password is incorrect."
        default: message.hasPrefix("FLOOD_WAIT") ? "Telegram asked you to wait before trying again. \(message)" : message
        }
    }
}

protocol TelegramTransport: Sendable {
    var updates: AsyncStream<TelegramJSON> { get }
    func request(_ query: TelegramJSON, timeout: TimeInterval) async throws -> TelegramJSON
}

extension TelegramTransport {
    func call(_ type: String, _ fields: [String: TelegramJSON] = [:], timeout: TimeInterval = 40) async throws -> TelegramJSON {
        try await request(.request(type, fields), timeout: timeout)
    }
}
