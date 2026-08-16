import Foundation

public enum JSONValue: Codable, Hashable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public enum SyncJSONCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateString(date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { codingPath in
            let source = codingPath.last?.stringValue ?? ""
            return SyncCodingKey(stringValue: swiftPropertyName(for: source))!
        }
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = parseDate(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO-8601 timestamp with a timezone."
                )
            }
            return date
        }
        return decoder
    }

    public static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    public static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func swiftPropertyName(for key: String) -> String {
        let positionalKey = key.dropFirst()
        if key.first == "_",
           !positionalKey.isEmpty,
           positionalKey.allSatisfy(\.isNumber)
        {
            return key
        }
        let components = key.split(separator: "_", omittingEmptySubsequences: false)
        guard components.count > 1 else {
            return key
        }
        return components.enumerated().map { index, component in
            let value = String(component)
            if index == 0 {
                return value
            }
            if value == "id" {
                return "ID"
            }
            if value == "url" {
                return "URL"
            }
            if value == "utc" {
                return "UTC"
            }
            if value == "sha256" {
                return "SHA256"
            }
            return value.prefix(1).uppercased() + value.dropFirst()
        }.joined()
    }
}

private struct SyncCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

public struct APIErrorBody: Codable, Hashable, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let correlationID: String
    public let details: [String: JSONValue]

    public init(
        code: String,
        message: String,
        retryable: Bool,
        correlationID: String,
        details: [String: JSONValue] = [:]
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.correlationID = correlationID
        self.details = details
    }
}

public struct APIErrorEnvelope: Codable, Hashable, Sendable {
    public let error: APIErrorBody

    public init(error: APIErrorBody) {
        self.error = error
    }
}
