import Foundation
import OdysseyDomain
import OdysseyIntegrations

public enum CalendarMirrorError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidText
    case invalidClock
    case invalidWindow
    case invalidTimeZone
    case invalidInterval
    case invalidSource
    case invalidBatch
    case unexpectedSyntheticWindow
}

public enum CalendarEventStatus: String, Codable, Hashable, Sendable {
    case none
    case confirmed
    case tentative
    case canceled
}

public enum CalendarEventAvailability: String, Codable, Hashable, Sendable {
    case unsupported
    case busy
    case free
    case tentative
    case unavailable
}

public enum CalendarSourceKind: String, Codable, Hashable, Sendable {
    case local
    case exchange
    case calDAV = "caldav"
    case mobileMe = "mobile_me"
    case subscribed
    case birthdays
    case unknown
}

public enum CalendarTimeZoneSource: String, Codable, Hashable, Sendable {
    case event
    case queryDefault = "query_default"
}

public struct CalendarQueryWindow: Codable, Hashable, Sendable {
    public static let maximumDuration: TimeInterval = 400 * 24 * 60 * 60

    public let startDate: Date
    public let endDate: Date
    public let timeZoneID: String

    public init(
        startDate: Date,
        endDate: Date,
        timeZoneID: String
    ) throws {
        guard startDate.timeIntervalSinceReferenceDate.isFinite,
              endDate.timeIntervalSinceReferenceDate.isFinite,
              endDate > startDate,
              endDate.timeIntervalSince(startDate) <= Self.maximumDuration
        else {
            throw CalendarMirrorError.invalidWindow
        }
        guard TimeZone(identifier: timeZoneID) != nil else {
            throw CalendarMirrorError.invalidTimeZone
        }
        self.startDate = startDate
        self.endDate = endDate
        self.timeZoneID = timeZoneID
    }

    private enum CodingKeys: String, CodingKey {
        case startDate
        case endDate
        case timeZoneID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            startDate: values.decode(Date.self, forKey: .startDate),
            endDate: values.decode(Date.self, forKey: .endDate),
            timeZoneID: values.decode(String.self, forKey: .timeZoneID)
        )
    }
}

public struct CalendarEventIdentity: Codable, Hashable, Sendable {
    public let eventIdentifier: String
    public let calendarItemExternalIdentifier: String?

    public init(
        eventIdentifier: String,
        calendarItemExternalIdentifier: String? = nil
    ) throws {
        guard CalendarMirrorValidation.validIdentifier(
            eventIdentifier,
            maximumBytes: 140
        ), CalendarMirrorValidation.validOptionalText(
            calendarItemExternalIdentifier,
            maximum: 512
        ) else {
            throw CalendarMirrorError.invalidIdentifier
        }
        self.eventIdentifier = eventIdentifier
        self.calendarItemExternalIdentifier = calendarItemExternalIdentifier
    }

    public var storageIdentifier: String {
        let encoded = Data(eventIdentifier.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "event_\(encoded)"
    }

    private enum CodingKeys: String, CodingKey {
        case eventIdentifier
        case calendarItemExternalIdentifier
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            eventIdentifier: values.decode(String.self, forKey: .eventIdentifier),
            calendarItemExternalIdentifier: values.decodeIfPresent(
                String.self,
                forKey: .calendarItemExternalIdentifier
            )
        )
    }
}

public struct CalendarSourceMetadata: Codable, Hashable, Sendable {
    public let calendarIdentifier: String
    public let calendarTitle: String
    public let sourceIdentifier: String
    public let sourceTitle: String
    public let sourceKind: CalendarSourceKind
    public let allowsContentModifications: Bool

    public init(
        calendarIdentifier: String,
        calendarTitle: String,
        sourceIdentifier: String,
        sourceTitle: String,
        sourceKind: CalendarSourceKind,
        allowsContentModifications: Bool
    ) throws {
        guard CalendarMirrorValidation.validText(calendarIdentifier, maximum: 512),
              CalendarMirrorValidation.validText(calendarTitle, maximum: 500),
              CalendarMirrorValidation.validText(sourceIdentifier, maximum: 512),
              CalendarMirrorValidation.validText(sourceTitle, maximum: 500)
        else {
            throw CalendarMirrorError.invalidSource
        }
        self.calendarIdentifier = calendarIdentifier
        self.calendarTitle = calendarTitle
        self.sourceIdentifier = sourceIdentifier
        self.sourceTitle = sourceTitle
        self.sourceKind = sourceKind
        self.allowsContentModifications = allowsContentModifications
    }

    private enum CodingKeys: String, CodingKey {
        case calendarIdentifier
        case calendarTitle
        case sourceIdentifier
        case sourceTitle
        case sourceKind
        case allowsContentModifications
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            calendarIdentifier: values.decode(String.self, forKey: .calendarIdentifier),
            calendarTitle: values.decode(String.self, forKey: .calendarTitle),
            sourceIdentifier: values.decode(String.self, forKey: .sourceIdentifier),
            sourceTitle: values.decode(String.self, forKey: .sourceTitle),
            sourceKind: values.decode(CalendarSourceKind.self, forKey: .sourceKind),
            allowsContentModifications: values.decode(
                Bool.self,
                forKey: .allowsContentModifications
            )
        )
    }
}

public struct CalendarTimeZoneContext: Codable, Hashable, Sendable {
    public let timeZoneID: String
    public let source: CalendarTimeZoneSource
    public let startUTCOffsetSeconds: Int
    public let endUTCOffsetSeconds: Int

    public init(
        timeZoneID: String,
        source: CalendarTimeZoneSource,
        startUTCOffsetSeconds: Int,
        endUTCOffsetSeconds: Int
    ) throws {
        guard TimeZone(identifier: timeZoneID) != nil else {
            throw CalendarMirrorError.invalidTimeZone
        }
        guard (-64_800 ... 64_800).contains(startUTCOffsetSeconds),
              (-64_800 ... 64_800).contains(endUTCOffsetSeconds)
        else {
            throw CalendarMirrorError.invalidTimeZone
        }
        self.timeZoneID = timeZoneID
        self.source = source
        self.startUTCOffsetSeconds = startUTCOffsetSeconds
        self.endUTCOffsetSeconds = endUTCOffsetSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case timeZoneID
        case source
        case startUTCOffsetSeconds
        case endUTCOffsetSeconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            timeZoneID: values.decode(String.self, forKey: .timeZoneID),
            source: values.decode(CalendarTimeZoneSource.self, forKey: .source),
            startUTCOffsetSeconds: values.decode(
                Int.self,
                forKey: .startUTCOffsetSeconds
            ),
            endUTCOffsetSeconds: values.decode(
                Int.self,
                forKey: .endUTCOffsetSeconds
            )
        )
    }
}

public struct CalendarMirrorItem: Codable, Hashable, Sendable {
    public let identity: CalendarEventIdentity
    public let title: String?
    public let interval: TemporalInterval
    public let source: CalendarSourceMetadata
    public let sourceVersion: Date?
    public let status: CalendarEventStatus
    public let availability: CalendarEventAvailability
    public let timeZone: CalendarTimeZoneContext
    public let hasRecurrenceRules: Bool

    public init(
        identity: CalendarEventIdentity,
        title: String?,
        interval: TemporalInterval,
        source: CalendarSourceMetadata,
        sourceVersion: Date?,
        status: CalendarEventStatus,
        availability: CalendarEventAvailability,
        timeZone: CalendarTimeZoneContext,
        hasRecurrenceRules: Bool
    ) throws {
        guard CalendarMirrorValidation.validOptionalText(title, maximum: 500) else {
            throw CalendarMirrorError.invalidText
        }
        guard sourceVersion?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw CalendarMirrorError.invalidClock
        }
        guard interval.timeZoneID == timeZone.timeZoneID,
              Self.validInterval(interval)
        else {
            throw CalendarMirrorError.invalidInterval
        }
        self.identity = identity
        self.title = title
        self.interval = interval
        self.source = source
        self.sourceVersion = sourceVersion
        self.status = status
        self.availability = availability
        self.timeZone = timeZone
        self.hasRecurrenceRules = hasRecurrenceRules
    }

    public var isCanceled: Bool {
        status == .canceled
    }

    private static func validInterval(_ interval: TemporalInterval) -> Bool {
        switch (interval.start, interval.end, interval.allDaySemantics) {
        case (.instant, .instant, false):
            true
        case (.localDate, .localDate, true):
            true
        default:
            false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case identity
        case title
        case interval
        case source
        case sourceVersion
        case status
        case availability
        case timeZone
        case hasRecurrenceRules
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identity: values.decode(CalendarEventIdentity.self, forKey: .identity),
            title: values.decodeIfPresent(String.self, forKey: .title),
            interval: values.decode(TemporalInterval.self, forKey: .interval),
            source: values.decode(CalendarSourceMetadata.self, forKey: .source),
            sourceVersion: values.decodeIfPresent(Date.self, forKey: .sourceVersion),
            status: values.decode(CalendarEventStatus.self, forKey: .status),
            availability: values.decode(
                CalendarEventAvailability.self,
                forKey: .availability
            ),
            timeZone: values.decode(CalendarTimeZoneContext.self, forKey: .timeZone),
            hasRecurrenceRules: values.decode(Bool.self, forKey: .hasRecurrenceRules)
        )
    }
}

public enum CalendarMirrorOutcome: String, Codable, Hashable, Sendable {
    case imported
    case permissionDenied = "permission_denied"
    case restricted
    case unavailable
}

public struct CalendarMirrorPage: Hashable, Sendable {
    public let window: CalendarQueryWindow
    public let queriedAt: Date
    public let items: [CalendarMirrorItem]
    public let outcome: CalendarMirrorOutcome
    public let rejectedRecordCount: Int

    public init(
        window: CalendarQueryWindow,
        queriedAt: Date,
        items: [CalendarMirrorItem],
        outcome: CalendarMirrorOutcome,
        rejectedRecordCount: Int = 0
    ) throws {
        guard queriedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw CalendarMirrorError.invalidClock
        }
        guard (0 ... 1_000_000).contains(rejectedRecordCount) else {
            throw CalendarMirrorError.invalidBatch
        }
        if outcome == .permissionDenied || outcome == .restricted || outcome == .unavailable {
            guard items.isEmpty else {
                throw CalendarMirrorError.invalidBatch
            }
        }
        self.window = window
        self.queriedAt = queriedAt
        self.items = items
        self.outcome = outcome
        self.rejectedRecordCount = rejectedRecordCount
    }
}

public struct CalendarMirrorCapability: Hashable, Sendable {
    public let availability: IntegrationCapabilityAvailability
    public let supportsFullAccessRead: Bool

    public init(
        availability: IntegrationCapabilityAvailability,
        supportsFullAccessRead: Bool
    ) {
        self.availability = availability
        self.supportsFullAccessRead = supportsFullAccessRead
    }
}

public protocol CalendarContextProviding: Sendable {
    func capability() async -> CalendarMirrorCapability
    func authorizationState() async -> IntegrationPermissionState
    func requestReadAuthorization() async throws -> IntegrationPermissionState
    func events(in window: CalendarQueryWindow) async throws -> CalendarMirrorPage
}

private enum CalendarMirrorValidation {
    static func validIdentifier(_ value: String, maximumBytes: Int) -> Bool {
        validText(value, maximum: 512)
            && value.utf8.count <= maximumBytes
    }

    static func validOptionalText(_ value: String?, maximum: Int) -> Bool {
        value.map { validText($0, maximum: maximum) } ?? true
    }

    static func validText(_ value: String, maximum: Int) -> Bool {
        (1 ... maximum).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }
}
