import Foundation

public enum NowWidgetSnapshotError: Error, Equatable, Sendable {
    case invalidSchema
    case invalidClock
    case invalidTimeZone
    case invalidText
}

public struct NowWidgetSnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumLifetime: TimeInterval = 24 * 60 * 60

    public let schemaVersion: Int
    public let generatedAt: Date
    public let expiresAt: Date
    public let timeZoneID: String
    public let state: NowState
    public let summary: String
    public let tomorrowSummary: String?
    public let nextTransitionAt: Date?
    public let privacySensitive: Bool

    public init(
        generatedAt: Date,
        expiresAt: Date,
        timeZoneID: String,
        state: NowState,
        summary: String,
        tomorrowSummary: String? = nil,
        nextTransitionAt: Date? = nil,
        privacySensitive: Bool = true
    ) throws {
        guard generatedAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt.timeIntervalSinceReferenceDate.isFinite,
              nextTransitionAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              expiresAt >= generatedAt,
              expiresAt.timeIntervalSince(generatedAt) <= Self.maximumLifetime
        else {
            throw NowWidgetSnapshotError.invalidClock
        }
        guard TimeZone(identifier: timeZoneID) != nil else {
            throw NowWidgetSnapshotError.invalidTimeZone
        }
        guard Self.validText(summary, maximum: 240),
              Self.validOptionalText(tomorrowSummary, maximum: 240)
        else {
            throw NowWidgetSnapshotError.invalidText
        }
        schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
        self.timeZoneID = timeZoneID
        self.state = state
        self.summary = summary
        self.tomorrowSummary = tomorrowSummary
        self.nextTransitionAt = nextTransitionAt
        self.privacySensitive = privacySensitive
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .schemaVersion)
            == Self.currentSchemaVersion
        else {
            throw NowWidgetSnapshotError.invalidSchema
        }
        try self.init(
            generatedAt: values.decode(Date.self, forKey: .generatedAt),
            expiresAt: values.decode(Date.self, forKey: .expiresAt),
            timeZoneID: values.decode(String.self, forKey: .timeZoneID),
            state: values.decode(NowState.self, forKey: .state),
            summary: values.decode(String.self, forKey: .summary),
            tomorrowSummary: values.decodeIfPresent(
                String.self,
                forKey: .tomorrowSummary
            ),
            nextTransitionAt: values.decodeIfPresent(
                Date.self,
                forKey: .nextTransitionAt
            ),
            privacySensitive: values.decode(Bool.self, forKey: .privacySensitive)
        )
    }

    public func isFresh(at date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
            && date >= generatedAt.addingTimeInterval(-60)
            && date <= expiresAt
    }

    private static func validText(_ value: String, maximum: Int) -> Bool {
        (1 ... maximum).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validOptionalText(_ value: String?, maximum: Int) -> Bool {
        guard let value else { return true }
        return validText(value, maximum: maximum)
    }
}
