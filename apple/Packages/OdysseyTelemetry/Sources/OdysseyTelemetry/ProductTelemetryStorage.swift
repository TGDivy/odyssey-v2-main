import Foundation

public enum ProductTelemetryCollectionMode: String, Codable, CaseIterable, Sendable {
    case off
    case localOnly = "local_only"
}

public enum ProductTelemetryPreferencesError: Error, Equatable, Sendable {
    case invalidSchemaVersion
    case duplicateQuestion
    case invalidRetention
    case invalidClock
}

public struct ProductTelemetryPreferences: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let disabled = try! ProductTelemetryPreferences(
        collectionMode: .off,
        enabledQuestions: ProductTelemetryQuestionID.allCases,
        retentionDays: 7
    )

    public let schemaVersion: Int
    public let collectionMode: ProductTelemetryCollectionMode
    public let enabledQuestions: [ProductTelemetryQuestionID]
    public let retentionDays: Int

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        collectionMode: ProductTelemetryCollectionMode,
        enabledQuestions: [ProductTelemetryQuestionID],
        retentionDays: Int
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ProductTelemetryPreferencesError.invalidSchemaVersion
        }
        guard Set(enabledQuestions).count == enabledQuestions.count else {
            throw ProductTelemetryPreferencesError.duplicateQuestion
        }
        guard (1 ... 30).contains(retentionDays) else {
            throw ProductTelemetryPreferencesError.invalidRetention
        }
        self.schemaVersion = schemaVersion
        self.collectionMode = collectionMode
        self.enabledQuestions = enabledQuestions.sorted { $0.rawValue < $1.rawValue }
        self.retentionDays = retentionDays
    }

    public func enables(_ questionID: ProductTelemetryQuestionID) -> Bool {
        collectionMode != .off && enabledQuestions.contains(questionID)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            collectionMode: container.decode(
                ProductTelemetryCollectionMode.self,
                forKey: .collectionMode
            ),
            enabledQuestions: container.decode(
                [ProductTelemetryQuestionID].self,
                forKey: .enabledQuestions
            ),
            retentionDays: container.decode(Int.self, forKey: .retentionDays)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case collectionMode = "collection_mode"
        case enabledQuestions = "enabled_questions"
        case retentionDays = "retention_days"
    }
}

public struct ProductTelemetrySummary: Hashable, Sendable {
    public let preferences: ProductTelemetryPreferences
    public let retainedEventCount: Int
    public let oldestEventAt: Date?
    public let newestEventAt: Date?
    public let nextExpiryAt: Date?
    public let generatedAt: Date

    public init(
        preferences: ProductTelemetryPreferences,
        retainedEventCount: Int,
        oldestEventAt: Date?,
        newestEventAt: Date?,
        nextExpiryAt: Date?,
        generatedAt: Date
    ) throws {
        guard retainedEventCount >= 0,
              generatedAt.timeIntervalSinceReferenceDate.isFinite,
              (retainedEventCount == 0)
                == (oldestEventAt == nil && newestEventAt == nil && nextExpiryAt == nil),
              oldestEventAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
              newestEventAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
              nextExpiryAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
              oldestEventAt.map({ oldest in newestEventAt.map({ oldest <= $0 }) ?? false }) ?? true
        else {
            throw ProductTelemetryPreferencesError.invalidClock
        }
        self.preferences = preferences
        self.retainedEventCount = retainedEventCount
        self.oldestEventAt = oldestEventAt
        self.newestEventAt = newestEventAt
        self.nextExpiryAt = nextExpiryAt
        self.generatedAt = generatedAt
    }
}

public protocol ProductTelemetryStoring: Sendable {
    func productTelemetryPreferences() throws -> ProductTelemetryPreferences
    func putProductTelemetryPreferences(
        _ preferences: ProductTelemetryPreferences,
        updatedAt: Date
    ) throws
    @discardableResult
    func appendProductTelemetryEvent(_ event: ProductTelemetryEvent) throws -> Bool
    func productTelemetryEvents(
        from: Date,
        to: Date,
        limit: Int
    ) throws -> [ProductTelemetryEvent]
    func productTelemetrySummary(at generatedAt: Date) throws -> ProductTelemetrySummary
    @discardableResult
    func pruneProductTelemetry(at date: Date) throws -> Int
    @discardableResult
    func deleteAllProductTelemetry() throws -> Int
}

public enum ProductTelemetryCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateString(date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
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
}
